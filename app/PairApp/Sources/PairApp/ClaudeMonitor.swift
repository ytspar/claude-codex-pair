import Foundation

/// A single item waiting to be injected into Claude's prompt.
struct InjectionItem {
    enum Source: String { case codexFeedback, taskQueue }
    let text: String
    let source: Source
    let enqueuedAt: Date = Date()
}

/// Monitor phase — single source of truth for the review state machine.
/// Replaces the previous `reviewInProgress: Bool` + `status: String` pair
/// that could get out of sync across dispatch queues.
enum MonitorPhase: String {
    case idle, watching, reviewing, feedback, approved, error
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
    private let maxSnapshots = 5

    // Autoresearch-inspired state
    private var _consecutiveUnhelpful = 0
    private var _backoffMultiplier: Double = 1.0
    private var _progressAtReviewStart: CodexLedger.ProgressSignal?
    private var _reviewCycleStartTime: Date?

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
    var sessionRemoved: Bool {
        get { lock.withLock { _sessionRemoved } }
        set { lock.withLock { _sessionRemoved = newValue } }
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
    func enqueue(_ text: String, source: InjectionItem.Source) {
        lock.withLock {
            // For feedback, replace any existing queued feedback (only latest matters)
            if source == .codexFeedback {
                _injectionQueue.removeAll { $0.source == .codexFeedback }
            }
            _injectionQueue.append(InjectionItem(text: text, source: source))
        }
    }

    /// Pop the next item to inject. Task queue items take priority.
    func dequeueNext() -> InjectionItem? {
        lock.withLock {
            guard !_injectionQueue.isEmpty else { return nil }
            // Expire items older than 120s
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
            guard _recentScreenSnapshots.count >= 3 else { return false }
            let latest = _recentScreenSnapshots.last!
            let latestWords = Set(latest.split(separator: " ").map(String.init))
            guard !latestWords.isEmpty else { return false }

            var similarCount = 0
            for snapshot in _recentScreenSnapshots.dropLast() {
                let words = Set(snapshot.split(separator: " ").map(String.init))
                let overlap = Double(latestWords.intersection(words).count) / Double(max(latestWords.count, 1))
                if overlap > 0.6 { similarCount += 1 }
            }
            return similarCount >= 2
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
    private var sessionStates: [String: SessionMonitorState] = [:]

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
        if let s = sessionStates[sessionId] { return s }
        let s = SessionMonitorState(sessionId: sessionId)
        sessionStates[sessionId] = s
        return s
    }

    /// Clear the injection queue for a session (used by test harness via IPC).
    func clearQueue(for sessionId: String) {
        if let st = sessionStates[sessionId] {
            st.clearInjectionQueue()
        }
    }

    /// Transition session phase and sync published properties to the UI.
    /// Safe to call from any queue — dispatches to main if needed.
    private func transitionAndSync(_ st: SessionMonitorState, to phase: MonitorPhase,
                                    resetCounters: Bool = false, reason: String = "") {
        st.transition(to: phase, resetCounters: resetCounters, reason: reason)
        if Thread.isMainThread {
            syncPublished()
        } else {
            DispatchQueue.main.async { self.syncPublished() }
        }
    }

    func removeSession(_ sessionId: String) {
        if let st = sessionStates[sessionId] {
            st.sessionRemoved = true
            st.transition(to: .idle, reason: "session removed")
            st.clearInjectionQueue()
        }
        sessionStates.removeValue(forKey: sessionId)
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
        guard !st.sessionRemoved else { return false }
        let atPrompt = isAtClaudePrompt(screenText) || isInterruptedPrompt(screenText)
        let promptEmpty = isPromptEmpty(screenText)

        // CARDINAL RULE: Only inject when the prompt is empty. Period.
        // If there's any text at the prompt — from user, from a failed injection,
        // from anything — do not touch it. No timeouts, no heuristics.
        guard atPrompt && promptEmpty else { return false }

        // If task queue is running, complete the active task and stage the next one.
        // This handles the case where Claude finished work and is sitting at the prompt.
        if TaskQueue.shared.isRunning && !st.hasQueuedInjections {
            if let stale = TaskQueue.shared.activeTask {
                PairLog.info("[\(session.id)] Active task at prompt, marking completed: \(stale.title)")
                TaskQueue.shared.markCompleted(id: stale.id)
            }
            if let nextTask = TaskQueue.shared.nextPending() {
                TaskQueue.shared.markActive(id: nextTask.id)
                st.enqueue(nextTask.prompt, source: .taskQueue)
                PairLog.info("[\(session.id)] Task queued for injection: \(nextTask.title)")
            }
        }

        guard let item = st.dequeueNext() else { return false }

        PairLog.action(session.id, action: "INJECT", detail: "\(item.source.rawValue) \(item.text.count) chars: \(item.text.prefix(120))")
        PairLog.screen(session.id, screenText, context: "pre-inject")
        st.transition(to: .watching, resetCounters: true, reason: "injection delivered")
        DispatchQueue.main.async {
            session.injectInput(item.text + "\n")
            self.addTimeline(st, item.source == .taskQueue ? "TASK_STARTED" : "FEEDBACK",
                             item.source == .taskQueue ? "Dequeued: \(item.text.prefix(60))" : "Codex: \(item.text.prefix(80))")
            self.syncPublished()
        }
        return true
    }

    private func syncPublished() {
        guard let activeId = SessionManager.shared.activeSessionId,
              let s = sessionStates[activeId] else {
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
        guard !isPromptEmpty(screen) else { return false }
        if -session.lastMachineInputTime.timeIntervalSinceNow > 30 { return false }
        return isAtClaudePrompt(screen)
    }

    private func addTimeline(_ st: SessionMonitorState, _ event: String, _ detail: String, source: TimelineSource = .monitor, durationMs: Int? = nil, screenSnippet: String? = nil, codexPrompt: String? = nil, codexResponse: String? = nil, diffSummary: String? = nil) {
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
            let userIsTyping = session.lastInputSource == .user && -session.lastMachineInputTime.timeIntervalSinceNow < 15

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

    private struct CodexResult {
        let response: String?
        let prompt: String
        let diffSummary: String?
    }

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

            let result = self.callCodex(screenText: screenText, cwd: session.cwd, claudeLooping: claudeLooping, repeatCount: st.repeatCount)
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

            let isSelection = Self.isSelectionPrompt(screenText)
            PairLog.info("[\(session.id)] Codex (\(durationMs ?? 0)ms): \(response.prefix(150)) [selection=\(isSelection), backoff=\(String(format: "%.1f", st.backoffMultiplier))x]")
            st.lastCodexResponse = response

            // Record decision with progress signal
            let ledger = CodexLedger(projectDir: session.cwd)
            let decision = response.uppercased().contains("APPROVE") ? "APPROVE" : (isSelection ? "SELECT" : "FEEDBACK")
            let screenTail = String(screenText.split(separator: "\n").suffix(10).joined(separator: "\n"))
            ledger.recordDecision(cycle: st.cycleCount, decision: decision, response: response,
                screenTail: screenTail, diffSummary: result.diffSummary,
                wasLooping: claudeLooping, durationMs: durationMs ?? 0,
                progressBefore: st.progressAtReviewStart)

            Self.extractLearnings(from: response, ledger: ledger)

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

    private func handleFeedback(response: String, screenText: String, session: PairSession, st: SessionMonitorState, isSelection: Bool, durationMs: Int?, screenSnippet: String, prompt: String, diffSummary: String?) {
        // Phase is already .feedback from caller's transition

        // CARDINAL RULE: Re-read the screen RIGHT NOW. If the prompt is not empty,
        // someone (user or prior injection) has text there. Do not touch it.
        let currentScreen = session.readScreen()
        if !isPromptEmpty(currentScreen) && !isSelection {
            PairLog.info("[\(session.id)] Prompt not empty — discarding Codex feedback to protect user input")
            addTimeline(st, "SKIPPED", "Prompt not empty — protected user input", source: .monitor, durationMs: durationMs, codexPrompt: prompt, codexResponse: response)
            return
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNumericResponse = Int(trimmed) != nil
        let userTypedDuringReview: Bool = {
            guard let start = st.reviewStartTime else { return false }
            return session.lastInputSource == .user && session.lastMachineInputTime < start
        }()
        let userOwnsInput = session.lastInputSource == .user
        let isAcceptEdits = Self.isAcceptEditsPrompt(screenText)
        let codexWantsApprove = response.uppercased().contains("APPROVE") || isNumericResponse

        if userOwnsInput {
            st.consecutiveSelects = 0
            PairLog.info("[\(session.id)] User is typing — discarding Codex response, user owns this input")
            addTimeline(st, "SKIPPED", "User is typing — Codex deferred: \(response)", source: .user, durationMs: durationMs, codexPrompt: prompt, codexResponse: response)
        } else if isAcceptEdits && codexWantsApprove {
            st.consecutiveSelects += 1
            if st.consecutiveSelects > 3 {
                PairLog.error("[\(session.id)] Accept-edits prompt stuck, sending Escape")
                addTimeline(st, "SELECT", "Escape (accept-edits stuck after \(st.consecutiveSelects) tries)")
                st.consecutiveSelects = 0; session.sendEscape()
            } else {
                PairLog.info("[\(session.id)] Accept-edits prompt detected, pressing Enter (\(st.consecutiveSelects))")
                addTimeline(st, "SELECT", "Accepting edits (Enter)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet)
                st.hadInteraction = true; session.sendEnter()
            }
        } else if isSelection && isNumericResponse, let option = Int(trimmed) {
            st.consecutiveSelects += 1
            if st.consecutiveSelects > 5 {
                PairLog.error("[\(session.id)] Selection prompt stuck, sending Escape")
                addTimeline(st, "SELECT", "Escape (selection stuck after \(st.consecutiveSelects) tries)")
                st.consecutiveSelects = 0; session.sendEscape()
            } else {
                PairLog.info("[\(session.id)] Selection prompt, typing \(option) + Enter")
                addTimeline(st, "SELECT", "Selecting option \(option)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                st.hadInteraction = true
                // Type the number directly — arrow keys don't work reliably with Claude Code's TUI
                session.injectInput("\(option)\r")
            }
        } else if isSelection && !isNumericResponse {
            // Category mismatch: detected as selection prompt but Codex didn't return a number.
            // Record for self-improvement, then try to handle gracefully.
            let ledger = CodexLedger(projectDir: session.cwd)
            ledger.recordUnmatchedPrompt(screenTail: screenSnippet, expectedCategory: "selection", codexResponse: trimmed)
            PairLog.info("[\(session.id)] Selection prompt got non-numeric response '\(trimmed.prefix(50))' — recorded for pattern improvement")
            addTimeline(st, "UNMATCHED", "Selection expected number, got: \(trimmed.prefix(80))", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            // Try pressing Enter as fallback (selects default/first option)
            st.hadInteraction = true; session.sendEnter()
        } else if userTypedDuringReview {
            st.consecutiveSelects = 0
            PairLog.info("[\(session.id)] User typed during review — queueing Codex feedback")
            let cleaned = Self.stripLearnings(response)
            if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
            addTimeline(st, "FEEDBACK", "Queued (user also responded): \(response)", source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            st.hadInteraction = true
        } else {
            st.consecutiveSelects = 0
            addTimeline(st, "FEEDBACK", response, source: .codex, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
            st.hadInteraction = true
            let cleaned = Self.stripLearnings(response)
            if !cleaned.isEmpty { st.enqueue(cleaned, source: .codexFeedback) }
        }
        // After feedback, wait for the screen to actually change before reviewing again.
        // The 1s cooldown was too aggressive — Codex would re-trigger on the same prompt.
        // Require at least 5s AND a screen change before the next review.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.transitionAndSync(st, to: .watching, reason: "post-feedback cooldown")
            st.stableCount = 0
            st.changeCount = 0  // Force waiting for new screen changes
        }
    }

    // MARK: - User feedback (thumbs up/down)

    /// Rate an intervention as helpful or unhelpful. Overrides the git-based outcome.
    func rateIntervention(entryId: UUID, rating: String) {
        // Update session counters based on user rating
        if rating == "improved" {
            sessionImproved += 1
            // User says it helped — reduce backoff
            if let activeId = SessionManager.shared.activeSessionId,
               let st = sessionStates[activeId] {
                st.consecutiveUnhelpful = max(0, st.consecutiveUnhelpful - 1)
                if st.consecutiveUnhelpful < 3 { st.backoffMultiplier = 1.0 }
                syncPublished()
            }
        } else if rating == "regressed" {
            sessionRegressed += 1
            // User says it hurt — increase backoff
            if let activeId = SessionManager.shared.activeSessionId,
               let st = sessionStates[activeId] {
                st.consecutiveUnhelpful += 1
                updateBackoff(st)
                syncPublished()
            }
        }
        // Find the timeline entry and log the rating
        if let activeId = SessionManager.shared.activeSessionId,
           let st = sessionStates[activeId],
           let entry = st.timeline.first(where: { $0.id == entryId }) {
            PairLog.info("[\(activeId)] User rated intervention '\(entry.event)' as \(rating)")
            // Record to ledger for strategy learning
            if let cwd = SessionManager.shared.sessions.first(where: { $0.id == activeId })?.cwd {
                let ledger = CodexLedger(projectDir: cwd)
                ledger.appendLearning("User rated '\(entry.detail.prefix(60))' as \(rating)")
            }
        }
    }

    // MARK: - Backoff management

    private func updateBackoff(_ st: SessionMonitorState) {
        // Backoff disabled: the system should always keep moving forward.
        // Claude conversations often don't produce git commits (questions,
        // discussions, planning) — that's normal, not a reason to slow down.
        // The backoff counter is still tracked for UI/logging but multiplier stays at 1.
        st.backoffMultiplier = 1.0
    }

    // MARK: - Screen detection helpers (immutable eval layer)

    private func isStillWorking(_ screenText: String) -> Bool {
        let tail = screenText.split(separator: "\n").suffix(15).joined(separator: "\n").lowercased()
        let patterns = ["agent still running", "still working", "waiting for", "let me wait", "let it finish", "wait for it to complete", "in progress", "tasks (", "churned for", "running agent"]
        let hasOpenTask = tail.contains("open)") || tail.contains("□") || tail.contains("⠋") || tail.contains("⠙") || tail.contains("⠸")
        let hasWaitLanguage = patterns.contains { tail.contains($0) }
        return hasWaitLanguage && (hasOpenTask || tail.contains("still") || tail.contains("wait"))
    }

    private func isModalView(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("esc to close") || lower.contains("←/esc to close")
    }

    private func isStuck(_ screenText: String) -> Bool {
        let tail = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.suffix(20).joined(separator: "\n").lowercased()
        return tail.contains("interrupted") || tail.contains("error:") || tail.contains("failed to") || tail.contains("apiconnectionerror") || tail.contains("what should claude do") || tail.contains("rate limit") || tail.contains("overloaded") || tail.contains("try again")
    }

    private func isPromptEmpty(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if lines.contains(where: { $0.contains("[Pasted text") }) { return false }
        guard let lastNonEmpty = lines.last(where: { !$0.isEmpty }) else { return true }
        // Strip cursor/block characters for clean comparison
        let stripped = String(lastNonEmpty.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x2580 || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
        if let range = stripped.range(of: "❯") {
            return stripped[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        }
        if stripped.hasSuffix(">") || stripped == ">" || stripped.hasSuffix("> ") { return true }
        // Also check original in case ❯ is in the raw text
        if let range = lastNonEmpty.range(of: "❯") {
            return lastNonEmpty[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        }
        if lastNonEmpty.hasSuffix(">") || lastNonEmpty.hasSuffix("> ") { return true }
        return true
    }

    private func isAtClaudePrompt(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Scan the last several lines — Claude Code renders separator bars (─────)
        // below the ❯ prompt line, so the last non-empty line is often a rule, not the prompt.
        let tail = lines.suffix(6)
        let isClaudePrompt = tail.contains { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("❯") || s == "❯"
        }

        // Bare angle bracket (>) check — also scan tail lines
        let isBareAngle = !isClaudePrompt && tail.contains { line in
            let s = String(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x2580 || $0 == " " })
                .trimmingCharacters(in: .whitespaces)
            return s == ">" || s.hasSuffix("> ")
        }
        if isBareAngle {
            let lower = screenText.lowercased()
            if !(lower.contains("claude") || lower.contains("tool use") || lower.contains("compact") || lower.contains("autocompact") || lower.contains("cost:") || lower.contains("tokens") || lower.contains("opus") || lower.contains("sonnet")) { return false }
        }
        return (isClaudePrompt || isBareAngle) && !Self.isSelectionPrompt(screenText)
    }

    private func isInterruptedPrompt(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("interrupted") && lower.contains("what should claude do")
    }

    static func isAcceptEditsPrompt(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("accept edits on") || lower.contains("shift+tab to cycle") || lower.contains("shift-tab to cycle") || lower.contains("do you want to make this edit")
    }

    static func isSelectionPrompt(_ screenText: String) -> Bool {
        if isAcceptEditsPrompt(screenText) { return false }
        let lines = screenText.split(separator: "\n").map(String.init)
        let hasArrowMarker = lines.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "❯") ?? t.range(of: "›") {
                let after = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
                return !after.isEmpty && after.count > 1
            }
            return false
        }
        let numberedLines = lines.filter { let t = $0.trimmingCharacters(in: .whitespaces); return t.hasPrefix("1.") || t.hasPrefix("2.") || t.hasPrefix("3.") }
        let hasPermissionKeywords = lines.contains { let l = $0.lowercased(); return (l.contains("yes") && l.contains("allow")) || l.contains("do you want to") || l.contains("permission") }
        return hasArrowMarker || numberedLines.count >= 2 || hasPermissionKeywords
    }

    static func isInteractivePrompt(_ screenText: String) -> Bool {
        if isSelectionPrompt(screenText) || isAcceptEditsPrompt(screenText) { return true }
        let lines = screenText.split(separator: "\n").map(String.init)
        let tailLower = lines.suffix(20).joined(separator: "\n").lowercased()
        if tailLower.contains("esc to cancel") && !tailLower.contains("esc to close") { return true }
        if tailLower.contains("(y/n)") || tailLower.contains("[y/n]") || tailLower.contains("(yes/no)") || tailLower.contains("[yes/no]") { return true }
        if tailLower.contains("do you want to") { return true }
        if tailLower.contains("trust this") || tailLower.contains("allow this mcp") || (tailLower.contains("mcp server") && tailLower.contains("allow")) { return true }
        if tailLower.contains("press enter") || tailLower.contains("press any key") { return true }
        if tailLower.contains("are you sure") || tailLower.contains("proceed?") || tailLower.contains("continue?") { return true }
        if tailLower.contains("would you like") || tailLower.contains("run command") || tailLower.contains("allow command") { return true }
        if tailLower.contains("do you want to make this") { return true }
        if let lastNonEmpty = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let t = lastNonEmpty.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("?") {
                let lower = screenText.lowercased()
                if lower.contains("claude") || lower.contains("tool use") || lower.contains("compact") || lower.contains("cost:") || lower.contains("tokens") { return true }
            }
        }
        // Check if Claude's output (above the prompt) ends with a question.
        // Claude often finishes work and asks "Want me to X?" or "Should I Y?"
        // The prompt line (❯) is empty but Claude is waiting for a user answer.
        if Self.isClaudeAskingQuestion(lines) {
            return true
        }
        return false
    }

    /// Detect when Claude's output (above the ❯ prompt) ends with a question
    /// directed at the user. Scans the last few lines before the prompt for "?".
    /// This catches cases like "Want me to dig deeper?" or "Should I fix this?"
    /// where Claude is waiting for user input but the prompt line itself is empty.
    static func isClaudeAskingQuestion(_ lines: [String]) -> Bool {
        // Find the prompt line (❯ or bare >) and look at lines above it
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let promptIdx = trimmed.lastIndex(where: { $0.hasPrefix("❯") || $0 == ">" || $0.hasSuffix("> ") }) else {
            return false
        }

        // Look at the last few non-empty lines before the prompt
        let above = trimmed[..<promptIdx].suffix(5).filter { !$0.isEmpty }
        guard let lastAbove = above.last else { return false }

        // If the last meaningful line before the prompt ends with "?", Claude is asking
        return lastAbove.hasSuffix("?")
    }

    // MARK: - Codex prompt construction (strategy layer)

    private func callCodex(screenText: String, cwd: String, claudeLooping: Bool = false, repeatCount: Int = 0) -> CodexResult {
        PairLog.info(">>> callCodex entered (cwd=\(cwd), screen=\(screenText.count) chars)")
        let lastLines = screenText.split(separator: "\n").suffix(40).joined(separator: "\n")
        let isSelection = Self.isSelectionPrompt(screenText)
        let diffSummary = Self.gitDiffSummary(cwd: cwd)
        let diffDetail = Self.gitDiffDetail(cwd: cwd)
        let ledger = CodexLedger(projectDir: cwd)

        let projectContext = ledger.readContext()
        let recentHistory = ledger.recentHistoryWithOutcomes()
        let strategy = ledger.readStrategy()

        var contextBlock = ""
        if let strat = strategy { contextBlock += "\n--- PROJECT STRATEGY ---\n\(String(strat.suffix(500)))\n" }
        if let ctx = projectContext { contextBlock += "\n--- PROJECT CONTEXT ---\n\(String(ctx.suffix(800)))\n" }
        if let history = recentHistory {
            contextBlock += "\n--- YOUR RECENT DECISIONS (with outcomes) ---\n\(history)\n"
            contextBlock += "Use this history to avoid repeating interventions that regressed or were neutral.\nDouble down on patterns that led to improvement.\n"
        }

        let isPrompt = !isSelection && Self.isInteractivePrompt(screenText)
        let prompt: String

        if isSelection {
            prompt = """
            You are acting as the human operator for Claude Code. Claude is showing \
            an interactive selection prompt. Here is the terminal output:

            \(lastLines)

            This is a selection prompt where options are chosen by number. \
            Pick the most permissive/thorough option. Usually: \
            - For permission prompts, choose "Yes, allow all" (usually option 2). \
            - For file creation/edit prompts, choose "Yes" (usually option 1). \
            - For trust prompts, choose the most permissive option. \
            Reply with ONLY the option number (e.g., "2"). Nothing else.
            """
        } else if isPrompt {
            prompt = """
            You are acting as the human operator for Claude Code. Claude is asking \
            for your input or confirmation. Here is the terminal output:

            \(lastLines)
            \(contextBlock)
            You ARE the user. Respond exactly as a knowledgeable developer would: \
            - For Y/n or yes/no prompts: reply "y" or "yes" to proceed (or "n" if the action looks wrong). \
            - For "Press Enter to continue": reply with just an empty line. \
            - For questions about what to do: answer directly and concisely. \
            - For trust/permission prompts: grant permission (the user trusts their tools). \
            - For "Are you sure?" / "Proceed?": confirm with "y" or "yes". \
            - For any other question: use your best judgment as the developer would. \
            Only output the exact text to type. No explanations. No quotes.
            """
        } else {
            var loopWarning = ""
            if claudeLooping {
                loopWarning += "\n⚠️ POSSIBLE LOOP: Claude's screen looks similar across recent cycles. If stuck, tell Claude to STOP and try something fundamentally different. Suggest a concrete alternative.\n"
            }
            if repeatCount >= 2 {
                loopWarning += "\nNOTE: Your last \(repeatCount + 1) responses were identical. Check if the situation is actually progressing.\n"
            }
            let diffBlock = (diffDetail.map { !$0.isEmpty } ?? false) ? "\n--- GIT DIFF ---\n\(diffDetail!)\n" : ""

            // Build commit nudge when there's significant uncommitted work
            var commitBlock = ""
            if let uncommitted = ledger.hasUncommittedWork(), uncommitted.files >= 3 {
                commitBlock = """

                --- UNCOMMITTED WORK ---
                \(uncommitted.description) (\(uncommitted.files) files total)
                When Claude reaches a good checkpoint (feature works, tests pass, or logical unit complete), \
                tell it to commit its changes: "Good progress. Commit what you have so far with a descriptive \
                message, making sure all new and modified files are staged." \
                This keeps the git history clean and makes it easy to roll back if needed.

                """
            } else if let lastCommit = ledger.lastCommitSummary() {
                commitBlock = "\n--- LAST COMMIT ---\n\(lastCommit)\n"
            }

            prompt = """
            You are acting as the human operator for Claude Code. Claude has paused. \
            Here is the terminal output:

            \(lastLines)
            \(contextBlock)\(diffBlock)\(commitBlock)\(loopWarning)
            If Claude asked a question, answer it directly. Pick the most thorough option. \
            If Claude finished work, reply with just: APPROVE \
            Only output the text to type into Claude. \
            IMPORTANT: If Claude has made meaningful changes (new files, significant edits) \
            but hasn't committed yet, tell it to commit before continuing. Say something like: \
            "Commit your changes so far before moving on. Stage all relevant files including any new ones." \
            This ensures progress is saved incrementally. \
            If you notice a pattern worth remembering, add a note prefixed with "LEARN:" at the end.
            """
        }

        guard let codexPath = findCodex() else {
            PairLog.error("Codex not found")
            return CodexResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }

        // codex is a Node.js script (#!/usr/bin/env node) — Swift's Process can't
        // exec .js files directly. Run through node explicitly.
        let nodePath = findNode()
        let resolvedCodex = resolveSymlink(codexPath)

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        if let node = nodePath {
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [resolvedCodex, "exec", "--json", "-s", "read-only", prompt]
            PairLog.info("Codex: node \(resolvedCodex) [prompt \(prompt.count) chars]")
        } else {
            PairLog.error("Node.js not found — cannot run Codex")
            return CodexResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = stderr
        var env = ProcessInfo.processInfo.environment
        let nodeDir = (nodePath! as NSString).deletingLastPathComponent
        env["PATH"] = "\(nodeDir):\(env["PATH"] ?? "/usr/bin")"
        process.environment = env

        do {
            PairLog.info("Codex spawning: \(codexPath) exec --json -s read-only [prompt \(prompt.count) chars]")
            try process.run()
            PairLog.info("Codex PID \(process.processIdentifier) started")
            // Read pipes on background threads BEFORE waitUntilExit to avoid pipe deadlock.
            // If the process fills the pipe buffer (~64KB), it blocks waiting for reads,
            // while waitUntilExit blocks waiting for the process — classic deadlock.
            var rawData = Data()
            var errData = Data()
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global().async {
                rawData = stdout.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global().async {
                errData = stderr.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    PairLog.error("Codex timed out after \(Int(self.codexTimeoutSec))s - killing")
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + codexTimeoutSec, execute: timeoutItem)
            process.waitUntilExit()
            timeoutItem.cancel()
            let readResult = readGroup.wait(timeout: .now() + codexTimeoutSec + 5)
            if readResult == .timedOut {
                PairLog.error("Codex pipe read timed out — possible deadlock avoided")
            }
            let raw = String(data: rawData, encoding: .utf8) ?? ""
            let errOut = String(data: errData, encoding: .utf8) ?? ""
            if !errOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { PairLog.error("Codex stderr: \(errOut.prefix(500))") }
            if process.terminationStatus != 0 { PairLog.error("Codex exited with code \(process.terminationStatus), stdout=\(raw.count) bytes") }

            var text = ""
            var deltaText = ""
            for line in raw.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let eventType = j["type"] as? String else { continue }
                if eventType == "item.completed", let item = j["item"] as? [String: Any], let t = item["text"] as? String { text = t }
                else if eventType == "item.delta", let delta = j["delta"] as? [String: Any], let t = delta["text"] as? String { deltaText += t }
            }
            if text.isEmpty && !deltaText.isEmpty { text = deltaText }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexResult(response: trimmed.isEmpty ? nil : trimmed, prompt: prompt, diffSummary: diffSummary)
        } catch {
            PairLog.error("Codex failed: \(error)")
            return CodexResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }
    }

    private static func extractLearnings(from response: String, ledger: CodexLedger) {
        for line in response.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("LEARN:") {
                let learning = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !learning.isEmpty { PairLog.info("Codex learning: \(learning)"); ledger.appendLearning(learning) }
            }
        }
    }

    private static func stripLearnings(_ response: String) -> String {
        response.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("LEARN:") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func gitDiffSummary(cwd: String) -> String? {
        CodexLedger.runGit(["diff", "--stat", "--no-color"], cwd: cwd)
    }

    private static func gitDiffDetail(cwd: String) -> String? {
        guard let full = CodexLedger.runGit(["diff", "--no-color", "-U2"], cwd: cwd) else { return nil }
        return full.count > 2000 ? String(full.prefix(2000)) + "\n... (diff truncated)" : full
    }

    private func findCodex() -> String? {
        let paths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node"
        var all = paths
        if let vs = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in vs.sorted().reversed() { all.append("\(nvmDir)/\(v)/bin/codex") }
        }
        return all.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Find node binary — needed to run codex (which is a .js script).
    private func findNode() -> String? {
        let paths = ["/usr/local/bin/node", "/opt/homebrew/bin/node"]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node"
        var all = paths
        if let vs = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in vs.sorted().reversed() { all.append("\(nvmDir)/\(v)/bin/node") }
        }
        return all.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Resolve symlinks to get the actual file path (codex → codex.js).
    private func resolveSymlink(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.resolvingSymlinksInPath().path
    }
}
