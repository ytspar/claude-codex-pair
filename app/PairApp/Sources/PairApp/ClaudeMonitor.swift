import Foundation

/// A single item waiting to be injected into Claude's prompt.
struct InjectionItem {
    enum Source: String { case codexFeedback, taskQueue }
    let text: String
    let source: Source
    let enqueuedAt: Date = Date()
    /// For task queue items, the task ID so we can reset it on expiry.
    let taskId: UUID?

    init(text: String, source: Source, taskId: UUID? = nil) {
        self.text = text
        self.source = source
        self.taskId = taskId
    }
}

/// Monitor phase — single source of truth for the review state machine.
/// Replaces the previous `reviewInProgress: Bool` + `status: String` pair
/// that could get out of sync across dispatch queues.
enum MonitorPhase: String {
    case idle, watching, reviewing, feedback, approved, error
}

/// A single conversation turn between Claude and Codex, for building contextual memory.
struct ConversationTurn {
    let turn: Int
    let claudeAction: String    // "ran swift test", "asked which file"
    let codexDecision: String   // "APPROVE", "ANSWER: yes", "WAIT"
    let outcome: String?        // "tests passed", "file edited"
    let timestamp: Date
}

/// Per-session monitor state — each tab gets its own polling state, timeline, and review cycle.
/// All mutable properties must be accessed through the lock to prevent data races
/// between the pollQueue and main thread.
///
/// Phase transitions go through `transition(to:)` which atomically updates
/// all coupled state, eliminating the stuck-state bugs from independent field sets.
class SessionMonitorState {
    let sessionId: String
    private let lock = NSLock()

    // Poll-thread state (protected by lock)
    private var _lastScreenHash: Int = 0
    private var _stableCount = 0
    private var _changeCount = 0
    private var _hadInteraction = false
    private var _phase: MonitorPhase = .idle
    private var _lastWasApprove = false
    private var _reviewStartTime: Date?
    private var _consecutiveErrors = 0
    private var _lastResponseHash: Int = 0
    private var _repeatCount = 0
    private var _lastScreenText = ""
    private var _emptyScreenCount = 0
    private var _startTime = Date()
    private var _timeline: [ClaudeMonitor.TimelineEntry] = []
    private var _cycleCount: Int = 0
    private var _lastCodexResponse: String = ""
    private var _consecutiveSelects = 0
    private var _watchingSince: Date?
    private var _recentScreenSnapshots: [String] = []
    private var _similarScreenCount = 0
    private var _sessionRemoved = false
    private var _paused = false
    private let maxSnapshots = 5
    /// Screen hash when we last reviewed a blocking/permission prompt.
    /// Prevents re-triggering reviews on the same unchanged permission dialog.
    private var _lastBlockingReviewHash: Int = 0

    // Conversation memory
    private var _conversationTurns: [ConversationTurn] = []

    // Autoresearch-inspired state
    private var _consecutiveUnhelpful = 0
    private var _backoffMultiplier: Double = 1.0
    private var _progressAtReviewStart: CodexLedger.ProgressSignal?
    private var _reviewCycleStartTime: Date?

    // Transient error retry tracking
    private var _lastRetryTime: Date?

    // Single injection queue — one path for all prompt injection
    private var _injectionQueue: [InjectionItem] = []

    // MARK: - Phase transitions (single source of truth)

    /// Atomically transition to a new phase, updating all coupled state.
    /// This is the ONLY way to change the monitor phase — no direct field sets.
    func transition(to phase: MonitorPhase, resetCounters: Bool = false, reason: String = "") {
        lock.withLock {
            let from = _phase
            _phase = phase

            switch phase {
            case .reviewing:
                _reviewCycleStartTime = Date()
                _reviewStartTime = Date()

            case .watching:
                _reviewCycleStartTime = nil

            case .approved:
                _reviewCycleStartTime = nil
                _lastWasApprove = true
                _hadInteraction = false

            case .feedback:
                _reviewCycleStartTime = nil

            case .error:
                _reviewCycleStartTime = nil

            case .idle:
                _reviewCycleStartTime = nil
            }

            if resetCounters {
                _stableCount = 0
                _changeCount = 0
                _hadInteraction = false
                _lastWasApprove = false
            }

            if from != phase {
                PairLog.info("[\(sessionId)] Phase: \(from.rawValue) → \(phase.rawValue)"
                             + (reason.isEmpty ? "" : " (\(reason))"))
            }
        }
    }

    // Thread-safe property accessors
    var lastScreenHash: Int {
        get { lock.withLock { _lastScreenHash } }
        set { lock.withLock { _lastScreenHash = newValue } }
    }
    var stableCount: Int {
        get { lock.withLock { _stableCount } }
        set { lock.withLock { _stableCount = newValue } }
    }
    var changeCount: Int {
        get { lock.withLock { _changeCount } }
        set { lock.withLock { _changeCount = newValue } }
    }
    var hadInteraction: Bool {
        get { lock.withLock { _hadInteraction } }
        set { lock.withLock { _hadInteraction = newValue } }
    }
    var lastRetryTime: Date? {
        get { lock.withLock { _lastRetryTime } }
        set { lock.withLock { _lastRetryTime = newValue } }
    }
    /// Read-only — phase determines this. Use `transition(to:)` to change.
    var reviewInProgress: Bool {
        lock.withLock { _phase == .reviewing }
    }
    var lastWasApprove: Bool {
        get { lock.withLock { _lastWasApprove } }
        set { lock.withLock { _lastWasApprove = newValue } }
    }
    /// Read-only — set atomically by `transition(to: .reviewing)`.
    var reviewStartTime: Date? {
        lock.withLock { _reviewStartTime }
    }
    var consecutiveErrors: Int {
        get { lock.withLock { _consecutiveErrors } }
        set { lock.withLock { _consecutiveErrors = newValue } }
    }
    var lastResponseHash: Int {
        get { lock.withLock { _lastResponseHash } }
        set { lock.withLock { _lastResponseHash = newValue } }
    }
    var repeatCount: Int {
        get { lock.withLock { _repeatCount } }
        set { lock.withLock { _repeatCount = newValue } }
    }
    var lastScreenText: String {
        get { lock.withLock { _lastScreenText } }
        set { lock.withLock { _lastScreenText = newValue } }
    }
    var emptyScreenCount: Int {
        get { lock.withLock { _emptyScreenCount } }
        set { lock.withLock { _emptyScreenCount = newValue } }
    }
    var startTime: Date {
        get { lock.withLock { _startTime } }
        set { lock.withLock { _startTime = newValue } }
    }
    /// Read-only — the phase's rawValue. Use `transition(to:)` to change.
    var status: String {
        lock.withLock { _phase.rawValue }
    }
    /// Current phase enum value (for switch statements).
    var phase: MonitorPhase {
        lock.withLock { _phase }
    }
    var timeline: [ClaudeMonitor.TimelineEntry] {
        get { lock.withLock { _timeline } }
        set { lock.withLock { _timeline = newValue } }
    }
    var cycleCount: Int {
        get { lock.withLock { _cycleCount } }
        set { lock.withLock { _cycleCount = newValue } }
    }
    var lastCodexResponse: String {
        get { lock.withLock { _lastCodexResponse } }
        set { lock.withLock { _lastCodexResponse = newValue } }
    }
    var consecutiveSelects: Int {
        get { lock.withLock { _consecutiveSelects } }
        set { lock.withLock { _consecutiveSelects = newValue } }
    }
    var watchingSince: Date? {
        get { lock.withLock { _watchingSince } }
        set { lock.withLock { _watchingSince = newValue } }
    }
    var similarScreenCount: Int {
        get { lock.withLock { _similarScreenCount } }
        set { lock.withLock { _similarScreenCount = newValue } }
    }
    var lastBlockingReviewHash: Int {
        get { lock.withLock { _lastBlockingReviewHash } }
        set { lock.withLock { _lastBlockingReviewHash = newValue } }
    }
    var sessionRemoved: Bool {
        get { lock.withLock { _sessionRemoved } }
        set { lock.withLock { _sessionRemoved = newValue } }
    }
    var paused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }
    var consecutiveUnhelpful: Int {
        get { lock.withLock { _consecutiveUnhelpful } }
        set { lock.withLock { _consecutiveUnhelpful = newValue } }
    }
    var backoffMultiplier: Double {
        get { lock.withLock { _backoffMultiplier } }
        set { lock.withLock { _backoffMultiplier = newValue } }
    }
    var progressAtReviewStart: CodexLedger.ProgressSignal? {
        get { lock.withLock { _progressAtReviewStart } }
        set { lock.withLock { _progressAtReviewStart = newValue } }
    }
    /// Read-only — set atomically by `transition(to:)`.
    var reviewCycleStartTime: Date? {
        lock.withLock { _reviewCycleStartTime }
    }

    // MARK: - Injection queue

    /// Enqueue text to be injected when Claude is next at an empty prompt.
    func enqueue(_ text: String, source: InjectionItem.Source, taskId: UUID? = nil) {
        lock.withLock {
            // For feedback, replace any existing queued feedback (only latest matters)
            if source == .codexFeedback {
                _injectionQueue.removeAll { $0.source == .codexFeedback }
            }
            _injectionQueue.append(InjectionItem(text: text, source: source, taskId: taskId))
        }
    }

    /// Pop the next item to inject. Task queue items take priority.
    func dequeueNext() -> InjectionItem? {
        lock.withLock {
            guard !_injectionQueue.isEmpty else { return nil }
            // Expire items older than 120s — reset expired task queue items to pending
            let expired = _injectionQueue.filter { -$0.enqueuedAt.timeIntervalSinceNow > 120 }
            for item in expired where item.source == .taskQueue {
                if let taskId = item.taskId {
                    TaskQueue.shared.retry(id: taskId)
                    PairLog.info("[\(sessionId)] Expired task queue item reset to pending: \(item.text.prefix(60))")
                }
            }
            _injectionQueue.removeAll { -$0.enqueuedAt.timeIntervalSinceNow > 120 }
            guard !_injectionQueue.isEmpty else { return nil }
            // Task queue items first
            if let idx = _injectionQueue.firstIndex(where: { $0.source == .taskQueue }) {
                return _injectionQueue.remove(at: idx)
            }
            return _injectionQueue.removeFirst()
        }
    }

    var hasQueuedInjections: Bool {
        lock.withLock { !_injectionQueue.isEmpty }
    }

    func clearInjectionQueue() {
        lock.withLock { _injectionQueue.removeAll() }
    }

    /// Effective stable threshold after applying exponential backoff.
    var effectiveStableThreshold: Int {
        lock.withLock { max(3, Int(3.0 * _backoffMultiplier)) }
    }

    var snapshotCount: Int { lock.withLock { _recentScreenSnapshots.count } }

    func recordScreenSnapshot(_ screenText: String) {
        lock.withLock {
            let tail = screenText.split(separator: "\n").suffix(15).joined(separator: "\n")
            _recentScreenSnapshots.append(tail)
            if _recentScreenSnapshots.count > maxSnapshots {
                _recentScreenSnapshots.removeFirst()
            }
        }
    }

    func detectLoop() -> Bool {
        lock.withLock {
            guard _recentScreenSnapshots.count >= 4 else { return false }
            let latest = _recentScreenSnapshots.last!
            let latestWords = Set(latest.split(separator: " ").map(String.init))
            guard latestWords.count >= 5 else { return false }

            var similarCount = 0
            for snapshot in _recentScreenSnapshots.dropLast() {
                let words = Set(snapshot.split(separator: " ").map(String.init))
                let overlap = Double(latestWords.intersection(words).count) / Double(max(latestWords.count, 1))
                if overlap > 0.8 { similarCount += 1 }
            }
            return similarCount >= 3
        }
    }

    // MARK: - Conversation memory

    func recordTurn(claudeAction: String, codexDecision: String) {
        lock.withLock {
            let turn = ConversationTurn(
                turn: (_conversationTurns.last?.turn ?? 0) + 1,
                claudeAction: claudeAction,
                codexDecision: codexDecision,
                outcome: nil,
                timestamp: Date()
            )
            _conversationTurns.append(turn)
            if _conversationTurns.count > 10 {
                _conversationTurns.removeFirst(_conversationTurns.count - 10)
            }
        }
    }

    func updateLastOutcome(_ outcome: String) {
        lock.withLock {
            guard !_conversationTurns.isEmpty else { return }
            let last = _conversationTurns[_conversationTurns.count - 1]
            _conversationTurns[_conversationTurns.count - 1] = ConversationTurn(
                turn: last.turn,
                claudeAction: last.claudeAction,
                codexDecision: last.codexDecision,
                outcome: outcome,
                timestamp: last.timestamp
            )
        }
    }

    func conversationSummary() -> String {
        lock.withLock {
            _conversationTurns.map { turn in
                let base = "- Turn \(turn.turn): Claude \(turn.claudeAction) → \(turn.codexDecision)"
                if let outcome = turn.outcome {
                    return base + " → \(outcome)"
                } else {
                    return base + " → [current]"
                }
            }.joined(separator: "\n")
        }
    }

    init(sessionId: String) { self.sessionId = sessionId }
}

// MARK: - ClaudeMonitor

/// Monitors Claude by polling the SwiftTerm screen buffer every second.
///
/// Architecture (autoresearch-inspired):
/// - **Eval layer** (immutable): Screen diffing, stability detection, prompt classification.
/// - **Strategy layer** (mutable): Codex prompt construction, backoff logic, outcome tracking.
/// - **Progress signals**: Git-based scalar metrics that measure intervention effectiveness.
class ClaudeMonitor: ObservableObject {
    static let shared = ClaudeMonitor()

    @Published var status: String = "idle"
    @Published var timeline: [TimelineEntry] = []
    @Published var lastCodexResponse: String = ""
    @Published var cycleCount: Int = 0
    @Published var backoffMultiplier: Double = 1.0
    @Published var consecutiveUnhelpful: Int = 0
    @Published var sessionImproved: Int = 0
    @Published var sessionNeutral: Int = 0
    @Published var sessionRegressed: Int = 0

    enum TimelineSource: String {
        case monitor, user, codex
    }

    struct TimelineEntry: Identifiable {
        let id = UUID()
        let time: Date
        let event: String
        let detail: String
        let sessionId: String
        var source: TimelineSource = .monitor
        var durationMs: Int?
        var screenSnippet: String?
        var codexPrompt: String?
        var codexResponse: String?
        var diffSummary: String?
    }

    private let pollQueue = DispatchQueue(label: "claude-monitor", qos: .userInitiated)
    private let codexQueue = DispatchQueue(label: "claude-monitor-codex", qos: .userInitiated)
    private var dispatchTimer: DispatchSourceTimer?
    private var pollCount = 0
    let sessionStatesLock = NSLock()  // internal for FeedbackHandler extension
    var sessionStates: [String: SessionMonitorState] = [:]  // internal for FeedbackHandler extension

    // Eval layer constants (immutable)
    private let stableThreshold = 3
    private let changeThreshold = 5
    private let postActionChangeThreshold = 3
    private let maxConsecutiveErrors = 5
    private let maxRepeatCount = 3
    private let codexTimeoutSec: Double = 30
    private let maxEmptyScreens = 10
    private let startupGraceSec: Double = 8
    private let maxRetries = 2
    private let retryDelaySec: Double = 1.5
    private let maxWatchingSec: Double = 120
    private let promptStableThreshold = 1

    // Strategy layer constants (tunable)
    private let reviewCycleTimeoutSec: Double = 90
    private let backoffThreshold = 3
    private let maxBackoffMultiplier: Double = 10.0
    private let strategyUpdateInterval = 10

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.dispatchTimer = timer
        PairLog.info("ClaudeMonitor started")
    }

    func stop() { dispatchTimer?.cancel(); dispatchTimer = nil }

    private func state(for sessionId: String) -> SessionMonitorState {
        sessionStatesLock.withLock {
            if let s = sessionStates[sessionId] { return s }
            let s = SessionMonitorState(sessionId: sessionId)
            sessionStates[sessionId] = s
            return s
        }
    }

    /// Clear the injection queue for a session (used by test harness via IPC).
    func clearQueue(for sessionId: String) {
        let st = sessionStatesLock.withLock { sessionStates[sessionId] }
        st?.clearInjectionQueue()
    }

    /// Transition session phase and sync published properties to the UI.
    /// Safe to call from any queue — dispatches to main if needed.
    func transitionAndSync(_ st: SessionMonitorState, to phase: MonitorPhase,  // internal for FeedbackHandler extension
                                    resetCounters: Bool = false, reason: String = "") {
        st.transition(to: phase, resetCounters: resetCounters, reason: reason)
        if Thread.isMainThread {
            syncPublished()
        } else {
            DispatchQueue.main.async { self.syncPublished() }
        }
    }

    func removeSession(_ sessionId: String) {
        let st = sessionStatesLock.withLock { sessionStates[sessionId] }
        if let st {
            st.sessionRemoved = true
            st.transition(to: .idle, reason: "session removed")
            st.clearInjectionQueue()
        }
        sessionStatesLock.withLock { sessionStates.removeValue(forKey: sessionId) }
        if let active = TaskQueue.shared.activeTask {
            PairLog.info("Session \(sessionId) removed — resetting active task to pending: \(active.title)")
            TaskQueue.shared.retry(id: active.id)
        }
    }

    func activeSessionChanged() {
        DispatchQueue.main.async { self.syncPublished() }
    }

    /// Enqueue text for injection. Called from Codex review responses and task queue.
    /// The poll loop's drainInjectionQueue handles actual delivery.
    func enqueueForInjection(sessionId: String, text: String, source: InjectionItem.Source) {
        let st = state(for: sessionId)
        st.enqueue(text, source: source)
        PairLog.info("[\(sessionId)] Enqueued \(source.rawValue): \(text.prefix(80))")
    }

    /// Single drain point — called from pollSession when Claude is at an empty prompt.
    /// Pops one item from the injection queue and sends it to the terminal.
    /// Returns true if something was injected (callers should skip further strategy).
    @discardableResult
    private func drainInjectionQueue(session: PairSession, st: SessionMonitorState, screenText: String) -> Bool {
        guard !st.sessionRemoved, !st.paused else { return false }
        let atPrompt = isAtClaudePrompt(screenText) || isInterruptedPrompt(screenText)
        let promptEmpty = isPromptEmpty(screenText)

        // CARDINAL RULE: Only inject when the prompt is empty. Period.
        // If there's any text at the prompt — from user, from a failed injection,
        // from anything — do not touch it. No timeouts, no heuristics.
        guard atPrompt && promptEmpty else { return false }

        // If task queue is running, complete the active task and stage the next one.
        // Only mark complete if Claude actually did work (hadInteraction or screen changes).
        // This prevents rapid-fire task completion when the prompt is momentarily empty.
        if TaskQueue.shared.isRunning && !st.hasQueuedInjections {
            if let stale = TaskQueue.shared.activeTask, st.hadInteraction {
                PairLog.info("[\(session.id)] Active task at prompt, marking completed: \(stale.title)")
                TaskQueue.shared.markCompleted(id: stale.id)
                st.hadInteraction = false
                if let nextTask = TaskQueue.shared.nextPending() {
                    TaskQueue.shared.markActive(id: nextTask.id)
                    st.enqueue(nextTask.prompt, source: .taskQueue, taskId: nextTask.id)
                    PairLog.info("[\(session.id)] Task queued for injection: \(nextTask.title)")
                }
            }
        }

        guard let item = st.dequeueNext() else { return false }

        PairLog.action(session.id, action: "INJECT", detail: "\(item.source.rawValue) \(item.text.count) chars: \(item.text.prefix(120))")
        PairLog.screen(session.id, screenText, context: "pre-inject")
        st.transition(to: .watching, resetCounters: true, reason: "injection delivered")
        DispatchQueue.main.async {
            session.sendFeedback(item.text + "\n")
            self.addTimeline(st, item.source == .taskQueue ? "TASK_STARTED" : "FEEDBACK",
                             item.source == .taskQueue ? "Dequeued: \(item.text.prefix(60))" : "Codex: \(item.text.prefix(80))")
            self.syncPublished()
        }
        return true
    }

    func syncPublished() {  // internal for FeedbackHandler extension
        guard let activeId = SessionManager.shared.activeSessionId,
              let s = sessionStatesLock.withLock({ sessionStates[activeId] }) else {
            status = "idle"; timeline = []; cycleCount = 0; lastCodexResponse = ""
            backoffMultiplier = 1.0; consecutiveUnhelpful = 0
            return
        }
        status = s.status
        timeline = s.timeline
        cycleCount = s.cycleCount
        lastCodexResponse = s.lastCodexResponse
        backoffMultiplier = s.backoffMultiplier
        consecutiveUnhelpful = s.consecutiveUnhelpful
    }

    private func userIsComposing(_ session: PairSession, screen: String) -> Bool {
        guard session.lastInputSource == .user else { return false }
        guard -session.lastUserInputTime.timeIntervalSinceNow < 15 else { return false }
        guard !isPromptEmpty(screen) else { return false }
        return isAtClaudePrompt(screen)
    }

    func addTimeline(_ st: SessionMonitorState, _ event: String, _ detail: String, source: TimelineSource = .monitor, durationMs: Int? = nil, screenSnippet: String? = nil, codexPrompt: String? = nil, codexResponse: String? = nil, diffSummary: String? = nil) {  // internal for FeedbackHandler extension
        let entry = TimelineEntry(time: Date(), event: event, detail: detail, sessionId: st.sessionId, source: source, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: codexPrompt, codexResponse: codexResponse, diffSummary: diffSummary)
        DispatchQueue.main.async {
            st.timeline.insert(entry, at: 0)
            if st.timeline.count > 100 { st.timeline = Array(st.timeline.prefix(100)) }
            self.syncPublished()
        }
    }

    // MARK: - Eval layer: Pure observation

    enum ScreenState {
        case changed, stableWaiting, stableWorking
    }

    private func classifyScreen(_ screenText: String, hash: Int, st: SessionMonitorState) -> ScreenState {
        if hash != st.lastScreenHash {
            st.lastScreenHash = hash
            st.stableCount = 0
            st.changeCount += 1
            st.lastWasApprove = false
            if st.watchingSince == nil { st.watchingSince = Date() }
            return .changed
        }
        st.stableCount += 1
        st.watchingSince = nil
        if isStillWorking(screenText) { return .stableWorking }
        return .stableWaiting
    }

    private func poll() {
        pollCount += 1
        var sessions: [PairSession] = []
        DispatchQueue.main.sync { sessions = SessionManager.shared.sessions }
        var activeId: String?
        DispatchQueue.main.sync { activeId = SessionManager.shared.activeSessionId }

        guard !sessions.isEmpty else {
            if status != "idle" { DispatchQueue.main.async { self.syncPublished() } }
            return
        }
        guard let activeId, let activeSession = sessions.first(where: { $0.id == activeId }) else { return }

        // Check review cycle timeout
        let st = state(for: activeId)
        if let cycleStart = st.reviewCycleStartTime,
           -cycleStart.timeIntervalSinceNow >= reviewCycleTimeoutSec {
            PairLog.error("[\(activeId)] Review cycle timed out after \(Int(-cycleStart.timeIntervalSinceNow))s — aborting")
            addTimeline(st, "TIMEOUT", "Review cycle exceeded \(Int(reviewCycleTimeoutSec))s — killed and moving on")
            st.consecutiveUnhelpful += 1
            updateBackoff(st)
            transitionAndSync(st, to: .watching, reason: "review cycle timeout")
        }

        pollSession(activeSession)
    }

    private func pollSession(_ session: PairSession) {
        let st = state(for: session.id)
        guard !st.paused else { return }
        var screenText = ""
        DispatchQueue.main.sync { screenText = session.readScreen() }

        if screenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            st.emptyScreenCount += 1
            if st.emptyScreenCount == maxEmptyScreens {
                PairLog.error("[\(session.id)] Screen read returned empty \(maxEmptyScreens) times")
                if let active = TaskQueue.shared.activeTask {
                    TaskQueue.shared.retry(id: active.id)
                    PairLog.info("[\(session.id)] Terminal dead — resetting active task to pending: \(active.title)")
                }
                transitionAndSync(st, to: .error, reason: "terminal screen empty")
                DispatchQueue.main.async {
                    self.addTimeline(st, "ERROR", "Terminal screen empty — process may have exited")
                }
            }
            return
        }
        if st.emptyScreenCount > 0 && st.phase == .error {
            PairLog.info("[\(session.id)] Screen recovered from empty state")
            transitionAndSync(st, to: .watching, reason: "screen recovered from empty")
        }
        st.emptyScreenCount = 0
        st.lastScreenText = screenText

        if isModalView(screenText) && !st.reviewInProgress {
            st.consecutiveSelects += 1
            if st.consecutiveSelects <= 3 {
                PairLog.info("[\(session.id)] Modal view detected, sending Escape to dismiss")
                DispatchQueue.main.async {
                    session.sendEscape()
                    self.addTimeline(st, "SELECT", "Escape (dismissing modal view)")
                }
            }
            return
        }

        let hash = screenText.hashValue
        let logInterval = st.stableCount > 30 ? 300 : 10
        if pollCount % logInterval == 1 {
            PairLog.info("[\(session.id)] Poll screen=\(screenText.count)chars hash=\(hash == st.lastScreenHash ? "same" : "changed") changes=\(st.changeCount) stable=\(st.stableCount) backoff=\(String(format: "%.1f", st.backoffMultiplier))x")
        }

        // --- Single drain point: inject queued text when Claude is ready ---
        // If drain injected something, skip strategy — screen will change on next poll.
        if drainInjectionQueue(session: session, st: st, screenText: screenText) { return }

        // --- Auto-retry transient API errors (500, overloaded, rate limit) ---
        // If Claude hit a transient error and is back at the prompt, just retry.
        // No need to waste a reviewer call for this.
        if ScreenDetection.isTransientError(screenText) && isPromptEmpty(screenText) && st.stableCount >= 2 {
            let lastRetry = st.lastRetryTime ?? .distantPast
            if -lastRetry.timeIntervalSinceNow > 15 {  // Don't retry more than once per 15s
                st.lastRetryTime = Date()
                PairLog.info("[\(session.id)] Transient API error detected — auto-retrying")
                DispatchQueue.main.async {
                    self.addTimeline(st, "RETRY", "Transient API error — auto-retrying", source: .monitor)
                    session.sendEnter()
                }
                return
            }
        }

        let screenState = classifyScreen(screenText, hash: hash, st: st)
        applyStrategy(screenState: screenState, screenText: screenText, session: session, st: st)
    }

    // MARK: - Strategy layer: Decisions

    private func applyStrategy(screenState: ScreenState, screenText: String, session: PairSession, st: SessionMonitorState) {
        switch screenState {
        case .changed:
            let p = st.phase
            if p != .watching && p != .reviewing {
                transitionAndSync(st, to: .watching, reason: "screen changed")
            }
            if let since = st.watchingSince,
               -since.timeIntervalSinceNow >= maxWatchingSec,
               !st.reviewInProgress && st.changeCount >= changeThreshold
               && !(TaskQueue.shared.isRunning && (TaskQueue.shared.hasPending || TaskQueue.shared.activeTask != nil)) {
                PairLog.info("[\(session.id)] Claude working for \(Int(-since.timeIntervalSinceNow))s without pause, forcing review")
                let screenSnippet = String(screenText.split(separator: "\n").suffix(8).joined(separator: "\n"))
                st.recordScreenSnapshot(screenText)
                let isLooping = st.detectLoop()
                let changes = st.changeCount
                st.changeCount = 0
                st.watchingSince = Date()
                beginReviewCycle(st, session: session, screenText: screenText, screenSnippet: screenSnippet, changes: changes, isLooping: isLooping, reason: "Forced check-in after \(Int(-since.timeIntervalSinceNow))s of continuous work")
            }

        case .stableWaiting:
            if -st.startTime.timeIntervalSinceNow < startupGraceSec { return }

            // Interactive/selection prompts are blockers — always review immediately.
            // For everything else, apply normal thresholds.
            let isBlocking = Self.isInteractivePrompt(screenText)
            let effectiveThreshold = isBlocking ? promptStableThreshold : st.effectiveStableThreshold

            // CRITICAL: If the user typed text that's sitting at the prompt, the user
            // owns that input. Never review/inject until the prompt is empty again.
            // For empty-prompt scenarios, still respect a typing cooldown.
            let userOwnsPrompt = session.lastInputSource == .user && !isPromptEmpty(screenText)
            if userOwnsPrompt { return }
            let userIsTyping = session.lastInputSource == .user && -session.lastUserInputTime.timeIntervalSinceNow < 10

            guard st.stableCount >= effectiveThreshold && !st.reviewInProgress && !userIsTyping else { return }

            // At an empty prompt with no queued injections and no changes — nothing to do.
            let atPrompt = isAtClaudePrompt(screenText) || isInterruptedPrompt(screenText)
            let promptEmpty = atPrompt && isPromptEmpty(screenText)
            if promptEmpty && !isBlocking && st.lastWasApprove && st.changeCount == 0 { return }

            // When queue is running, skip review — drainInjectionQueue handles task delivery.
            // Check activeTask too: the current task may be done on screen but not yet
            // completed in the queue (drain handles that on the next poll cycle).
            let queueHasWork = TaskQueue.shared.isRunning
                && (TaskQueue.shared.hasPending || TaskQueue.shared.activeTask != nil || st.hasQueuedInjections)
            if !isBlocking && queueHasWork {
                if st.stableCount == effectiveThreshold {
                    PairLog.info("[\(session.id)] Queue running, skipping review — drain will handle (pending=\(TaskQueue.shared.pendingCount), active=\(TaskQueue.shared.activeTask?.title ?? "none"))")
                    st.changeCount = 0
                }
                return
            }

            // Trigger review — Codex decides what to do with whatever is on screen.
            st.recordScreenSnapshot(screenText)
            let isLooping = st.detectLoop()
            let changes = st.changeCount; st.changeCount = 0
            let reason = isBlocking
                ? "Claude waiting for input (\(changes) changes)"
                : isLooping
                    ? "Claude appears to be looping — similar screen across \(st.snapshotCount) reviews"
                    : "Claude idle after \(changes) screen changes (cycle \(st.cycleCount))"
            PairLog.info("[\(session.id)] Stable \(st.stableCount)s, triggering review (blocking=\(isBlocking), loop=\(isLooping), backoff=\(String(format: "%.1f", st.backoffMultiplier))x)")
            beginReviewCycle(st, session: session, screenText: screenText, screenSnippet: String(screenText.split(separator: "\n").suffix(8).joined(separator: "\n")), changes: changes, isLooping: isLooping, reason: reason)

        case .stableWorking:
            if st.stableCount == st.effectiveStableThreshold && st.changeCount > 0 {
                PairLog.info("[\(session.id)] Skipping review: Claude still has work in progress (changes=\(st.changeCount))")
                st.changeCount = 0
            }
        }
    }

    // MARK: - Review cycle management

    private func beginReviewCycle(_ st: SessionMonitorState, session: PairSession,
                                   screenText: String, screenSnippet: String,
                                   changes: Int, isLooping: Bool, reason: String) {
        let ledger = CodexLedger(projectDir: session.cwd)
        st.progressAtReviewStart = ledger.captureProgress()
        // transition(to: .reviewing) atomically sets reviewCycleStartTime + reviewStartTime
        st.transition(to: .reviewing, reason: reason)
        DispatchQueue.main.async {
            st.cycleCount += 1
            self.addTimeline(st, isLooping ? "LOOP_DETECTED" : "REVIEWING", reason, screenSnippet: screenSnippet)
        }
        triggerCodexReview(screenText: screenText, session: session, st: st, claudeLooping: isLooping)
    }

    // MARK: - Codex review

    private typealias CodexResult = CodexIntegration.CodexResult

    private func triggerCodexReview(screenText: String, session: PairSession, st: SessionMonitorState, retryCount: Int = 0, claudeLooping: Bool = false) {
        // Phase is already .reviewing from beginReviewCycle's transition call
        DispatchQueue.main.async { self.syncPublished() }

        codexQueue.async { [weak self] in
            guard let self, !st.sessionRemoved else {
                st.transition(to: .watching, reason: "session removed during review")
                DispatchQueue.main.async { [weak self] in self?.syncPublished() }
                return
            }

            if let cycleStart = st.reviewCycleStartTime,
               -cycleStart.timeIntervalSinceNow >= self.reviewCycleTimeoutSec {
                PairLog.error("[\(session.id)] Review cycle timed out before Codex call")
                self.transitionAndSync(st, to: .watching, reason: "cycle timeout pre-call")
                DispatchQueue.main.async {
                    self.addTimeline(st, "TIMEOUT", "Review cycle exceeded time budget")
                }
                return
            }

            let parsedScreen = ScreenParser.parse(screenText, mode: session.mode)
            let conversationSummary = st.conversationSummary()
            let result: CodexResult
            if session.mode == .codexLeads {
                let claudeResult = ClaudeReviewIntegration.callClaude(
                    parsedScreen: parsedScreen, screenText: screenText, cwd: session.cwd,
                    conversationSummary: conversationSummary, claudeLooping: claudeLooping,
                    repeatCount: st.repeatCount)
                result = CodexResult(response: claudeResult.response,
                                     prompt: claudeResult.prompt,
                                     diffSummary: claudeResult.diffSummary)
            } else {
                result = self.callCodex(screenText: screenText, cwd: session.cwd, claudeLooping: claudeLooping, repeatCount: st.repeatCount, parsedScreen: parsedScreen, conversationSummary: conversationSummary)
            }
            let screenSnippet = String(screenText.split(separator: "\n").suffix(8).joined(separator: "\n"))
            let response = result.response

            if (response == nil || response?.isEmpty == true), retryCount < self.maxRetries {
                let attempt = retryCount + 1
                PairLog.info("[\(session.id)] Codex returned empty, retrying (\(attempt)/\(self.maxRetries))")
                DispatchQueue.main.async { self.addTimeline(st, "RETRY", "Empty response, retrying (\(attempt)/\(self.maxRetries))") }
                self.codexQueue.asyncAfter(deadline: .now() + self.retryDelaySec) {
                    guard !st.sessionRemoved else { return }
                    self.triggerCodexReview(screenText: screenText, session: session, st: st, retryCount: attempt, claudeLooping: claudeLooping)
                }
                return
            }

            let durationMs = st.reviewStartTime.map { Int(-$0.timeIntervalSinceNow * 1000) }

            guard let response, !response.isEmpty else {
                st.consecutiveErrors += 1
                if st.consecutiveErrors >= self.maxConsecutiveErrors {
                    PairLog.error("[\(session.id)] Codex failed \(st.consecutiveErrors) times — pausing monitor")
                    self.transitionAndSync(st, to: .error, reason: "codex failed \(st.consecutiveErrors) times")
                    DispatchQueue.main.async {
                        self.addTimeline(st, "CODEX_EMPTY", "No response after \(retryCount + 1) attempts (error \(st.consecutiveErrors)/\(self.maxConsecutiveErrors))", durationMs: durationMs, codexPrompt: result.prompt, diffSummary: result.diffSummary)
                        self.addTimeline(st, "ERROR", "Codex failed \(st.consecutiveErrors) times — pausing reviews. Restart to retry.")
                    }
                } else {
                    self.transitionAndSync(st, to: .watching, reason: "codex empty response")
                    DispatchQueue.main.async {
                        self.addTimeline(st, "CODEX_EMPTY", "No response after \(retryCount + 1) attempts (error \(st.consecutiveErrors)/\(self.maxConsecutiveErrors))", durationMs: durationMs, codexPrompt: result.prompt, diffSummary: result.diffSummary)
                    }
                }
                return
            }

            st.consecutiveErrors = 0
            if response == st.lastCodexResponse && !response.isEmpty {
                st.repeatCount += 1
            } else {
                st.repeatCount = 0
            }

            // Skip repeated identical responses — prevents "commit your changes" loops
            if st.repeatCount >= 2 && !Self.isSelectionPrompt(screenText) {
                PairLog.info("[\(session.id)] Codex repeated same response \(st.repeatCount + 1) times — skipping")
                self.transitionAndSync(st, to: .watching, reason: "repeated response (\(st.repeatCount + 1)x)")
                DispatchQueue.main.async {
                    self.addTimeline(st, "SKIPPED", "Repeated response skipped (\(st.repeatCount + 1)x): \(response.prefix(60))")
                }
                return
            }

            let isSelection = parsedScreen.state == .selectionMenu || parsedScreen.state == .permissionPrompt
            PairLog.info("[\(session.id)] Codex (\(durationMs ?? 0)ms): \(response.prefix(150)) [selection=\(isSelection), backoff=\(String(format: "%.1f", st.backoffMultiplier))x]")
            st.lastCodexResponse = response

            // Record decision with progress signal
            let ledger = CodexLedger(projectDir: session.cwd)
            let codexDecision = CodexDecision.parse(response)
            let decisionLabel = codexDecision.rawDescription.components(separatedBy: ":").first ?? "UNKNOWN"
            let screenTail = String(screenText.split(separator: "\n").suffix(10).joined(separator: "\n"))
            ledger.recordDecision(cycle: st.cycleCount, decision: decisionLabel, response: response,
                screenTail: screenTail, diffSummary: result.diffSummary,
                wasLooping: claudeLooping, durationMs: durationMs ?? 0,
                progressBefore: st.progressAtReviewStart)

            Self.extractLearnings(from: response, ledger: ledger)

            // Record conversation turn for memory
            let claudeAction = self.describeClaudeAction(parsedScreen)
            st.recordTurn(claudeAction: claudeAction, codexDecision: codexDecision.rawDescription)

            // Schedule outcome measurement 30s after intervention
            self.codexQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self else { return }
                let progressAfter = ledger.captureProgress()
                let outcome = CodexLedger.computeOutcome(before: st.progressAtReviewStart, after: progressAfter)
                ledger.recordOutcome(outcome: outcome, progressAfter: progressAfter)
                DispatchQueue.main.async {
                    if outcome == "improved" {
                        st.consecutiveUnhelpful = 0; st.backoffMultiplier = 1.0
                        self.sessionImproved += 1
                        PairLog.info("[\(session.id)] Intervention outcome: IMPROVED — backoff reset")
                    } else if outcome == "regressed" {
                        st.consecutiveUnhelpful += 1
                        self.sessionRegressed += 1
                        self.updateBackoff(st)
                        PairLog.info("[\(session.id)] Intervention outcome: REGRESSED — unhelpful streak: \(st.consecutiveUnhelpful), backoff: \(String(format: "%.1f", st.backoffMultiplier))x")
                    } else {
                        st.consecutiveUnhelpful += 1
                        self.sessionNeutral += 1
                        self.updateBackoff(st)
                        PairLog.info("[\(session.id)] Intervention outcome: NEUTRAL — unhelpful streak: \(st.consecutiveUnhelpful), backoff: \(String(format: "%.1f", st.backoffMultiplier))x")
                    }
                    self.syncPublished()
                    if st.cycleCount % self.strategyUpdateInterval == 0 {
                        DispatchQueue.global(qos: .utility).async {
                            ledger.updateStrategy()
                            ledger.queuePendingImprovements()
                            PairLog.info("[\(session.id)] Updated project strategy (cycle \(st.cycleCount))")
                        }
                    }
                }
            }

            if response.uppercased().contains("APPROVE") {
                DispatchQueue.main.async {
                    self.addTimeline(st, "APPROVED", response, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: result.prompt, codexResponse: response, diffSummary: result.diffSummary)
                }
                if let activeTask = TaskQueue.shared.activeTask {
                    TaskQueue.shared.markCompleted(id: activeTask.id)
                    PairLog.info("[\(session.id)] Task completed: \(activeTask.title)")
                }
                // drainInjectionQueue will pick up the next task on the next poll cycle
                if TaskQueue.shared.hasPending {
                    self.transitionAndSync(st, to: .watching, resetCounters: true, reason: "approved, more tasks pending")
                } else {
                    self.transitionAndSync(st, to: .approved, reason: "approved, queue empty")
                }
            } else {
                // Transition to feedback before handling — handleFeedback may transition again
                st.transition(to: .feedback, reason: "codex feedback")
                DispatchQueue.main.async {
                    self.handleFeedback(response: response, screenText: screenText, session: session, st: st, isSelection: isSelection, durationMs: durationMs, screenSnippet: screenSnippet, prompt: result.prompt, diffSummary: result.diffSummary)
                    self.syncPublished()
                }
            }
        }
    }

    // MARK: - Parsed screen helpers

    private func describeClaudeAction(_ screen: ParsedScreen) -> String {
        switch screen.state {
        case .working: return "working" + (screen.lastToolUsed.map { " (\($0))" } ?? "")
        case .askingQuestion: return "asked: \(screen.question?.prefix(50) ?? "?")"
        case .selectionMenu: return "showing selection menu"
        case .permissionPrompt: return "requesting permission: \(screen.permissionDetail?.prefix(50) ?? "?")"
        case .showingError: return "error: \(screen.errorMessage?.prefix(50) ?? "unknown")"
        case .acceptEdits: return "showing accept-edits prompt"
        case .idle: return "idle at prompt"
        case .waitingForInput: return "waiting for input"
        }
    }

    // MARK: - Mode-aware screen detection helpers

    /// Resolves the active session's PairMode for detection dispatch.
    private var activeSessionMode: PairSession.PairMode {
        guard let id = SessionManager.shared.activeSessionId,
              let session = SessionManager.shared.findSession(id) else { return .claudeLeads }
        return session.mode
    }

    private func isStillWorking(_ screenText: String) -> Bool {
        if activeSessionMode == .codexLeads {
            return CodexScreenDetection.isStillWorking(screenText)
        }
        return ScreenDetection.isStillWorking(screenText)
    }

    private func isModalView(_ screenText: String) -> Bool {
        if activeSessionMode == .codexLeads {
            return CodexScreenDetection.isModalView(screenText)
        }
        return ScreenDetection.isModalView(screenText)
    }

    private func isStuck(_ screenText: String) -> Bool {
        if activeSessionMode == .codexLeads {
            return CodexScreenDetection.isStuck(screenText)
        }
        return ScreenDetection.isStuck(screenText)
    }

    func isPromptEmpty(_ screenText: String) -> Bool {  // internal for FeedbackHandler extension
        if activeSessionMode == .codexLeads {
            return CodexScreenDetection.isPromptEmpty(screenText)
        }
        return ScreenDetection.isPromptEmpty(screenText)
    }

    private func isAtPrompt(_ screenText: String) -> Bool {
        if activeSessionMode == .codexLeads {
            return CodexScreenDetection.isAtCodexPrompt(screenText)
        }
        return ScreenDetection.isAtClaudePrompt(screenText)
    }

    /// Legacy name — forwards to mode-aware `isAtPrompt`.
    private func isAtClaudePrompt(_ screenText: String) -> Bool {
        isAtPrompt(screenText)
    }

    private func isInterruptedPrompt(_ screenText: String) -> Bool {
        if activeSessionMode == .codexLeads {
            return CodexScreenDetection.isInterruptedPrompt(screenText)
        }
        return ScreenDetection.isInterruptedPrompt(screenText)
    }

    static func isAcceptEditsPrompt(_ screenText: String) -> Bool {
        let mode = SessionManager.shared.activeSession?.mode ?? .claudeLeads
        if mode == .codexLeads {
            return CodexScreenDetection.isAcceptEditsPrompt(screenText)
        }
        return ScreenDetection.isAcceptEditsPrompt(screenText)
    }

    static func isSelectionPrompt(_ screenText: String) -> Bool {
        let mode = SessionManager.shared.activeSession?.mode ?? .claudeLeads
        if mode == .codexLeads {
            return CodexScreenDetection.isSelectionPrompt(screenText)
        }
        return ScreenDetection.isSelectionPrompt(screenText)
    }

    static func isInteractivePrompt(_ screenText: String) -> Bool {
        let mode = SessionManager.shared.activeSession?.mode ?? .claudeLeads
        if mode == .codexLeads {
            return CodexScreenDetection.isInteractivePrompt(screenText)
        }
        return ScreenDetection.isInteractivePrompt(screenText)
    }

    static func isClaudeAskingQuestion(_ lines: [String]) -> Bool {
        let mode = SessionManager.shared.activeSession?.mode ?? .claudeLeads
        if mode == .codexLeads {
            return CodexScreenDetection.isCodexAskingQuestion(lines)
        }
        return ScreenDetection.isClaudeAskingQuestion(lines)
    }

    // MARK: - Codex integration (thin wrappers — logic lives in CodexIntegration.swift)

    private func callCodex(screenText: String, cwd: String, claudeLooping: Bool = false, repeatCount: Int = 0, parsedScreen: ParsedScreen? = nil, conversationSummary: String = "") -> CodexResult {
        CodexIntegration.callCodex(screenText: screenText, cwd: cwd, claudeLooping: claudeLooping, repeatCount: repeatCount, codexTimeoutSec: codexTimeoutSec, parsedScreen: parsedScreen, conversationSummary: conversationSummary)
    }

    private static func extractLearnings(from response: String, ledger: CodexLedger) {
        CodexIntegration.extractLearnings(from: response, ledger: ledger)
    }

    static func stripLearnings(_ response: String) -> String {  // internal for FeedbackHandler extension
        CodexIntegration.stripLearnings(response)
    }

    private static func gitDiffSummary(cwd: String) -> String? {
        CodexIntegration.gitDiffSummary(cwd: cwd)
    }

    private static func gitDiffDetail(cwd: String) -> String? {
        CodexIntegration.gitDiffDetail(cwd: cwd)
    }

    private func findCodex() -> String? {
        CodexIntegration.findCodex()
    }

    private func findNode() -> String? {
        CodexIntegration.findNode()
    }

    private func resolveSymlink(_ path: String) -> String {
        CodexIntegration.resolveSymlink(path)
    }
}
