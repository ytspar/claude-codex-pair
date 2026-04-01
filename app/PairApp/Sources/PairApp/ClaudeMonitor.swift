import Foundation

/// Per-session monitor state — each tab gets its own polling state, timeline, and review cycle.
class SessionMonitorState {
    let sessionId: String
    var lastScreenHash: Int = 0
    var stableCount = 0
    var changeCount = 0
    var hadInteraction = false
    var reviewInProgress = false
    var lastWasApprove = false
    var reviewStartTime: Date?
    var consecutiveErrors = 0
    var lastResponseHash: Int = 0
    var repeatCount = 0
    var lastScreenText = ""
    var emptyScreenCount = 0
    var startTime = Date()
    var pendingFeedback: String?
    var pendingFeedbackStableCount = 0
    var status: String = "idle"
    var timeline: [ClaudeMonitor.TimelineEntry] = []
    var cycleCount: Int = 0
    var lastCodexResponse: String = ""
    /// Consecutive SELECT actions on the same prompt — circuit breaker.
    var consecutiveSelects = 0
    /// Timestamp when the current "watching" period started (screen changes without review).
    var watchingSince: Date?

    /// Rolling history of screen snapshots at review time — used to detect Claude looping.
    var recentScreenSnapshots: [String] = []  // last N screen tails
    private let maxSnapshots = 5

    /// Track how many times Claude's screen looks similar across reviews.
    var similarScreenCount = 0

    func recordScreenSnapshot(_ screenText: String) {
        let tail = screenText.split(separator: "\n").suffix(15).joined(separator: "\n")
        recentScreenSnapshots.append(tail)
        if recentScreenSnapshots.count > maxSnapshots {
            recentScreenSnapshots.removeFirst()
        }
    }

    /// Check if Claude is looping — similar screen content across multiple review cycles.
    func detectLoop() -> Bool {
        guard recentScreenSnapshots.count >= 3 else { return false }
        let latest = recentScreenSnapshots.last!
        let latestWords = Set(latest.split(separator: " ").map(String.init))
        guard !latestWords.isEmpty else { return false }

        var similarCount = 0
        for snapshot in recentScreenSnapshots.dropLast() {
            let words = Set(snapshot.split(separator: " ").map(String.init))
            let overlap = Double(latestWords.intersection(words).count) / Double(max(latestWords.count, 1))
            if overlap > 0.6 { similarCount += 1 }
        }
        return similarCount >= 2
    }

    init(sessionId: String) { self.sessionId = sessionId }
}

/// Monitors Claude by polling the SwiftTerm screen buffer every second.
/// Each session gets independent monitoring state and timeline.
class ClaudeMonitor: ObservableObject {
    static let shared = ClaudeMonitor()

    // Published properties proxy to the active session's state
    @Published var status: String = "idle"
    @Published var timeline: [TimelineEntry] = []
    @Published var lastCodexResponse: String = ""
    @Published var cycleCount: Int = 0

    struct TimelineEntry: Identifiable {
        let id = UUID()
        let time: Date
        let event: String
        let detail: String
        let sessionId: String
        var durationMs: Int?
        var screenSnippet: String?
        var codexPrompt: String?
        var codexResponse: String?
        var diffSummary: String?
    }

    private let pollQueue = DispatchQueue(label: "claude-monitor", qos: .userInitiated)
    private var dispatchTimer: DispatchSourceTimer?
    private var pollCount = 0

    // Per-session state
    private var sessionStates: [String: SessionMonitorState] = [:]

    // Constants
    private let stableThreshold = 3
    private let changeThreshold = 5
    private let postActionChangeThreshold = 3
    private let maxConsecutiveErrors = 5
    private let maxRepeatCount = 3
    private let codexTimeoutSec: Double = 30
    private let maxEmptyScreens = 10
    private let startupGraceSec: Double = 8
    private let pendingFeedbackStableThreshold = 2
    private let maxRetries = 2
    private let retryDelaySec: Double = 1.5
    /// If Claude has been working (screen changing) for this long without pausing,
    /// force a review check-in. Prevents indefinite "watching" on long-running tasks.
    private let maxWatchingSec: Double = 120

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.dispatchTimer = timer
        PairLog.info("ClaudeMonitor started")
    }

    func stop() { dispatchTimer?.cancel(); dispatchTimer = nil }

    /// Get or create monitor state for a session.
    private func state(for sessionId: String) -> SessionMonitorState {
        if let s = sessionStates[sessionId] { return s }
        let s = SessionMonitorState(sessionId: sessionId)
        sessionStates[sessionId] = s
        return s
    }

    /// Remove state for a closed session.
    func removeSession(_ sessionId: String) {
        sessionStates.removeValue(forKey: sessionId)
    }

    /// Call when the active tab changes to refresh the Codex panel.
    func activeSessionChanged() {
        DispatchQueue.main.async { self.syncPublished() }
    }

    /// Sync published properties from the active session's state.
    private func syncPublished() {
        guard let activeId = SessionManager.shared.activeSessionId,
              let s = sessionStates[activeId] else {
            status = "idle"
            timeline = []
            cycleCount = 0
            lastCodexResponse = ""
            return
        }
        status = s.status
        timeline = s.timeline
        cycleCount = s.cycleCount
        lastCodexResponse = s.lastCodexResponse
    }

    private func addTimeline(_ st: SessionMonitorState, _ event: String, _ detail: String, durationMs: Int? = nil, screenSnippet: String? = nil, codexPrompt: String? = nil, codexResponse: String? = nil, diffSummary: String? = nil) {
        let entry = TimelineEntry(time: Date(), event: event, detail: detail, sessionId: st.sessionId, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: codexPrompt, codexResponse: codexResponse, diffSummary: diffSummary)
        DispatchQueue.main.async {
            st.timeline.insert(entry, at: 0)
            if st.timeline.count > 100 { st.timeline = Array(st.timeline.prefix(100)) }
            self.syncPublished()
        }
    }

    private func poll() {
        pollCount += 1
        var sessions: [PairSession] = []
        DispatchQueue.main.sync {
            sessions = SessionManager.shared.sessions
        }

        guard !sessions.isEmpty else {
            if status != "idle" { DispatchQueue.main.async { self.syncPublished() } }
            return
        }

        // Poll ALL sessions, not just the active one
        for session in sessions {
            pollSession(session)
        }
    }

    private func pollSession(_ session: PairSession) {
        let st = state(for: session.id)

        // Read screen on main thread (SwiftTerm is not thread-safe)
        var screenText = ""
        DispatchQueue.main.sync {
            screenText = session.readScreen()
        }

        // Guard against empty screen reads
        if screenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            st.emptyScreenCount += 1
            if st.emptyScreenCount == maxEmptyScreens {
                PairLog.error("[\(session.id)] Screen read returned empty \(maxEmptyScreens) times")
                DispatchQueue.main.async {
                    st.status = "error"
                    self.addTimeline(st, "ERROR", "Terminal screen empty — process may have exited")
                }
            }
            return
        }
        st.emptyScreenCount = 0
        st.lastScreenText = screenText

        let hash = screenText.hashValue

        if pollCount % 10 == 1 {
            PairLog.info("[\(session.id)] Poll screen=\(screenText.count)chars hash=\(hash == st.lastScreenHash ? "same" : "changed") changes=\(st.changeCount) stable=\(st.stableCount)")
        }

        if hash != st.lastScreenHash {
            st.lastScreenHash = hash
            st.stableCount = 0
            st.pendingFeedbackStableCount = 0
            st.changeCount += 1
            st.lastWasApprove = false
            if st.watchingSince == nil { st.watchingSince = Date() }
            if st.status != "watching" && st.status != "reviewing" {
                DispatchQueue.main.async {
                    st.status = "watching"
                    self.syncPublished()
                }
            }

            // Force a review if Claude has been working too long without pausing
            if let since = st.watchingSince,
               -since.timeIntervalSinceNow >= maxWatchingSec,
               !st.reviewInProgress && st.changeCount >= changeThreshold {
                PairLog.info("[\(session.id)] Claude working for \(Int(-since.timeIntervalSinceNow))s without pause, forcing review")
                let screenSnippet = String(screenText.split(separator: "\n").suffix(8).joined(separator: "\n"))
                st.recordScreenSnapshot(screenText)
                let isLooping = st.detectLoop()
                let changes = st.changeCount
                st.changeCount = 0
                st.watchingSince = Date()  // reset for next interval
                st.reviewStartTime = Date()
                DispatchQueue.main.async {
                    st.cycleCount += 1
                    self.addTimeline(st, "REVIEWING", "Forced check-in after \(Int(-since.timeIntervalSinceNow))s of continuous work (\(changes) changes)", screenSnippet: screenSnippet)
                }
                triggerCodexReview(screenText: screenText, session: session, st: st, claudeLooping: isLooping)
                return
            }
        } else {
            st.stableCount += 1
            st.watchingSince = nil  // screen stable — reset watch timer

            // Inject pending Codex feedback after Claude settles
            if let feedback = st.pendingFeedback, !st.reviewInProgress {
                st.pendingFeedbackStableCount += 1
                if st.pendingFeedbackStableCount >= pendingFeedbackStableThreshold {
                    PairLog.info("[\(session.id)] Injecting queued Codex feedback (\(feedback.count) chars)")
                    st.pendingFeedback = nil
                    st.pendingFeedbackStableCount = 0
                    DispatchQueue.main.async {
                        self.addTimeline(st, "FEEDBACK", "Queued Codex context: \(feedback)")
                        session.injectInput(feedback + "\n")
                        st.hadInteraction = true
                        st.stableCount = 0
                        st.changeCount = 0
                    }
                    return
                }
            }

            // If Claude is at its input prompt (❯), normally skip review.
            // But if the screen shows signs of being stuck, trigger a review
            // so Codex can nudge Claude back on track.
            if isAtClaudePrompt(screenText) {
                if isStuck(screenText) && st.stableCount >= stableThreshold && !st.reviewInProgress && !st.lastWasApprove {
                    PairLog.info("[\(session.id)] Claude appears stuck at prompt, triggering review")
                    let screenSnippet = String(screenText.split(separator: "\n").suffix(8).joined(separator: "\n"))
                    let changes = st.changeCount
                    st.changeCount = 0
                    st.reviewStartTime = Date()
                    DispatchQueue.main.async {
                        st.cycleCount += 1
                        self.addTimeline(st, "STUCK", "Claude stuck at prompt after \(changes) changes", screenSnippet: screenSnippet)
                    }
                    triggerCodexReview(screenText: screenText, session: session, st: st, claudeLooping: true)
                } else if st.stableCount == stableThreshold && st.changeCount > 0 {
                    PairLog.info("[\(session.id)] Skipping review: Claude is at prompt (changes=\(st.changeCount))")
                    st.changeCount = 0
                }
                return
            }

            // Skip reviews during startup grace period
            if -st.startTime.timeIntervalSinceNow < startupGraceSec {
                return
            }

            // Skip review if Claude is explicitly waiting for background work
            if isStillWorking(screenText) {
                if st.stableCount == stableThreshold && st.changeCount > 0 {
                    PairLog.info("[\(session.id)] Skipping review: Claude still has work in progress (changes=\(st.changeCount))")
                    st.changeCount = 0
                }
                return
            }

            // Require enough screen changes before reviewing
            let requiredChanges = st.hadInteraction ? postActionChangeThreshold : changeThreshold
            if st.stableCount == stableThreshold && st.changeCount >= requiredChanges && !st.reviewInProgress && !st.lastWasApprove {
                let screenSnippet = String(screenText.split(separator: "\n").suffix(8).joined(separator: "\n"))
                st.recordScreenSnapshot(screenText)
                let isLooping = st.detectLoop()
                PairLog.info("[\(session.id)] Claude idle \(stableThreshold)s after \(st.changeCount) changes, reviewing (loop=\(isLooping))")
                let changes = st.changeCount
                st.changeCount = 0
                st.reviewStartTime = Date()
                DispatchQueue.main.async {
                    st.cycleCount += 1
                    let event = isLooping ? "LOOP_DETECTED" : "REVIEWING"
                    let detail = isLooping
                        ? "Claude appears to be looping — similar screen across \(st.recentScreenSnapshots.count) reviews"
                        : "Claude idle after \(changes) screen changes (cycle \(st.cycleCount))"
                    self.addTimeline(st, event, detail, screenSnippet: screenSnippet)
                }
                triggerCodexReview(screenText: screenText, session: session, st: st, claudeLooping: isLooping)
            }
        }
    }

    // MARK: - Codex review

    private struct CodexResult {
        let response: String?
        let prompt: String
        let diffSummary: String?
    }

    private func triggerCodexReview(screenText: String, session: PairSession, st: SessionMonitorState, retryCount: Int = 0, claudeLooping: Bool = false) {
        st.reviewInProgress = true
        DispatchQueue.main.async {
            st.status = "reviewing"
            self.syncPublished()
        }

        pollQueue.async { [weak self] in
            guard let self = self else { return }
            let result = self.callCodex(screenText: screenText, cwd: session.cwd, claudeLooping: claudeLooping)
            let screenSnippet = String(screenText.split(separator: "\n").suffix(8).joined(separator: "\n"))

            let response = result.response

            // Retry on empty response
            if (response == nil || response?.isEmpty == true), retryCount < self.maxRetries {
                let attempt = retryCount + 1
                PairLog.info("[\(session.id)] Codex returned empty, retrying (\(attempt)/\(self.maxRetries))")
                DispatchQueue.main.async {
                    self.addTimeline(st, "RETRY", "Empty response, retrying (\(attempt)/\(self.maxRetries))")
                }
                self.pollQueue.asyncAfter(deadline: .now() + self.retryDelaySec) {
                    self.triggerCodexReview(screenText: screenText, session: session, st: st, retryCount: attempt, claudeLooping: claudeLooping)
                }
                return
            }

            DispatchQueue.main.async {
                st.reviewInProgress = false
                let durationMs = st.reviewStartTime.map { Int(-$0.timeIntervalSinceNow * 1000) }
                let prompt = result.prompt
                let diffSummary = result.diffSummary

                // Handle empty/error responses (after retries exhausted)
                guard let response = response, !response.isEmpty else {
                    st.consecutiveErrors += 1
                    st.status = "watching"
                    self.addTimeline(st, "CODEX_EMPTY", "No response after \(retryCount + 1) attempts (error \(st.consecutiveErrors)/\(self.maxConsecutiveErrors))", durationMs: durationMs, codexPrompt: prompt, diffSummary: diffSummary)
                    if st.consecutiveErrors >= self.maxConsecutiveErrors {
                        PairLog.error("[\(session.id)] Codex failed \(st.consecutiveErrors) times — pausing monitor")
                        self.addTimeline(st, "ERROR", "Codex failed \(st.consecutiveErrors) times — pausing reviews. Restart to retry.")
                        st.status = "error"
                    }
                    self.syncPublished()
                    return
                }

                // Reset error counter on success
                st.consecutiveErrors = 0

                // Loop detection
                let responseHash = response.hashValue
                if responseHash == st.lastResponseHash {
                    st.repeatCount += 1
                    if st.repeatCount >= self.maxRepeatCount {
                        PairLog.error("[\(session.id)] Codex gave same response \(st.repeatCount) times — possible loop")
                        self.addTimeline(st, "LOOP_DETECTED", "Same response repeated \(st.repeatCount) times: \(response.prefix(100))", durationMs: durationMs, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                        st.lastWasApprove = true
                        st.repeatCount = 0
                        st.status = "error"
                        self.syncPublished()
                        return
                    }
                } else {
                    st.repeatCount = 0
                }
                st.lastResponseHash = responseHash

                let isSelection = Self.isSelectionPrompt(screenText)
                PairLog.info("[\(session.id)] Codex (\(durationMs ?? 0)ms): \(response.prefix(150)) [selection=\(isSelection)]")
                st.lastCodexResponse = response

                if response.uppercased().contains("APPROVE") {
                    self.addTimeline(st, "APPROVED", response, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)

                    // Mark current active task as completed
                    if let activeTask = TaskQueue.shared.activeTask {
                        TaskQueue.shared.markCompleted(id: activeTask.id)
                        PairLog.info("[\(session.id)] Task completed: \(activeTask.title)")
                    }

                    // Check for next queued task
                    if let nextTask = TaskQueue.shared.nextPending() {
                        TaskQueue.shared.markActive(id: nextTask.id)
                        self.addTimeline(st, "TASK_STARTED", nextTask.title)
                        PairLog.info("[\(session.id)] Starting queued task: \(nextTask.title)")

                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            session.injectInput(nextTask.prompt + "\n")
                            st.status = "watching"
                            st.stableCount = 0
                            st.changeCount = 0
                            st.hadInteraction = true
                            st.lastWasApprove = false
                            self.syncPublished()
                        }
                    } else {
                        st.lastWasApprove = true
                        st.hadInteraction = false
                        st.status = "approved"
                    }
                } else {
                    st.status = "feedback"

                    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isNumericResponse = Int(trimmed) != nil

                    let userTypedDuringReview: Bool = {
                        guard let start = st.reviewStartTime else { return false }
                        return session.lastInputSource == .user &&
                               session.lastMachineInputTime < start
                    }()

                    if Self.isAcceptEditsPrompt(screenText) {
                        // "accept edits on (shift+tab to cycle)" — press Enter to accept
                        st.consecutiveSelects += 1
                        if st.consecutiveSelects > 3 {
                            // Enter didn't work — try Escape to dismiss
                            PairLog.error("[\(session.id)] Accept-edits prompt stuck, sending Escape")
                            self.addTimeline(st, "SELECT", "Escape (accept-edits stuck after \(st.consecutiveSelects) tries)")
                            st.consecutiveSelects = 0
                            session.sendEscape()
                        } else {
                            PairLog.info("[\(session.id)] Accept-edits prompt detected, pressing Enter (\(st.consecutiveSelects))")
                            self.addTimeline(st, "SELECT", "Accepting edits (Enter)", durationMs: durationMs, screenSnippet: screenSnippet)
                            st.hadInteraction = true
                            session.sendEnter()
                        }
                    } else if isSelection && isNumericResponse, let option = Int(trimmed) {
                        st.consecutiveSelects += 1
                        if st.consecutiveSelects > 5 {
                            // Arrow selection isn't working — try Escape
                            PairLog.error("[\(session.id)] Selection prompt stuck, sending Escape")
                            self.addTimeline(st, "SELECT", "Escape (selection stuck after \(st.consecutiveSelects) tries)")
                            st.consecutiveSelects = 0
                            session.sendEscape()
                        } else {
                            PairLog.info("[\(session.id)] Selection prompt, using selectOption(\(option))")
                            self.addTimeline(st, "SELECT", "Selecting option \(option) via arrow keys", durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                            st.hadInteraction = true
                            session.selectOption(option)
                        }
                    } else if userTypedDuringReview {
                        st.consecutiveSelects = 0
                        PairLog.info("[\(session.id)] User typed during review — queueing Codex feedback")
                        st.pendingFeedback = response
                        st.pendingFeedbackStableCount = 0
                        self.addTimeline(st, "FEEDBACK", "Queued (user also responded): \(response)", durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                        st.hadInteraction = true
                    } else {
                        st.consecutiveSelects = 0
                        self.addTimeline(st, "FEEDBACK", response, durationMs: durationMs, screenSnippet: screenSnippet, codexPrompt: prompt, codexResponse: response, diffSummary: diffSummary)
                        st.hadInteraction = true
                        session.injectInput(response + "\n")
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        st.status = "watching"
                        st.stableCount = 0
                        self.syncPublished()
                    }
                }
                self.syncPublished()
            }
        }
    }

    // MARK: - Screen detection helpers

    private func isStillWorking(_ screenText: String) -> Bool {
        let tail = screenText.split(separator: "\n").suffix(15).joined(separator: "\n").lowercased()
        let patterns = [
            "agent still running", "still working", "waiting for",
            "let me wait", "let it finish", "wait for it to complete",
            "in progress", "tasks (", "churned for", "running agent",
        ]
        let hasOpenTask = tail.contains("open)") || tail.contains("□") || tail.contains("⠋") || tail.contains("⠙") || tail.contains("⠸")
        let hasWaitLanguage = patterns.contains { tail.contains($0) }
        return hasWaitLanguage && (hasOpenTask || tail.contains("still") || tail.contains("wait"))
    }

    /// Detect if Claude appears stuck — interrupted, errored, or idle after minimal work.
    private func isStuck(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let tail = lines.suffix(20).joined(separator: "\n").lowercased()

        // Interrupted mid-work
        if tail.contains("interrupted") { return true }
        // Error indicators
        if tail.contains("error:") || tail.contains("failed to") || tail.contains("apiconnectionerror") { return true }
        // Stalled thinking indicator
        if tail.contains("(thinking)") || tail.contains("creating…") { return true }
        // "What should Claude do instead?" — Claude was interrupted and is waiting
        if tail.contains("what should claude do") { return true }
        // Rate limited or connection issues
        if tail.contains("rate limit") || tail.contains("overloaded") || tail.contains("try again") { return true }

        return false
    }

    private func isAtClaudePrompt(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let lastNonEmpty = lines.last(where: { !$0.isEmpty }) else { return false }
        let isPrompt = lastNonEmpty.hasPrefix("❯") ||
                       lastNonEmpty.hasSuffix(">") ||
                       lastNonEmpty.hasSuffix("> ") ||
                       lastNonEmpty.contains("❯")
        return isPrompt && !Self.isSelectionPrompt(screenText)
    }

    /// Detect "accept edits on (shift+tab to cycle)" — needs Enter, not arrow keys.
    static func isAcceptEditsPrompt(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("accept edits on") || lower.contains("shift+tab to cycle") || lower.contains("shift-tab to cycle")
    }

    static func isSelectionPrompt(_ screenText: String) -> Bool {
        // "accept edits on" is NOT an arrow-key selection prompt
        if isAcceptEditsPrompt(screenText) { return false }

        let lines = screenText.split(separator: "\n").map(String.init)
        let hasArrowMarker = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "❯") ?? trimmed.range(of: "›") {
                let after = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
                // Ignore bare prompt line (❯ with just cursor/whitespace)
                return !after.isEmpty && after.count > 1
            }
            return false
        }
        let numberedLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("1.") || trimmed.hasPrefix("2.") || trimmed.hasPrefix("3.")
        }
        let hasPermissionKeywords = lines.contains { line in
            let lower = line.lowercased()
            return (lower.contains("yes") && lower.contains("allow")) ||
                   lower.contains("do you want to") ||
                   lower.contains("permission")
        }
        return hasArrowMarker || numberedLines.count >= 2 || hasPermissionKeywords
    }

    // MARK: - Codex CLI

    private func callCodex(screenText: String, cwd: String, claudeLooping: Bool = false) -> CodexResult {
        let lastLines = screenText.split(separator: "\n").suffix(40).joined(separator: "\n")
        let isSelection = Self.isSelectionPrompt(screenText)
        let diffSummary = Self.gitDiffSummary(cwd: cwd)

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
        } else {
            let loopWarning = claudeLooping ? """

            ⚠️ LOOP DETECTED: Claude's screen output looks very similar across the last \
            several review cycles. Claude appears to be stuck repeating the same approach \
            without making progress. This often happens when Claude:
            - Keeps trying the same fix that doesn't work
            - Ignores user suggestions visible on screen
            - Doesn't read error messages carefully

            You MUST intervene decisively:
            1. Look for user messages on screen that Claude may be ignoring — quote them back.
            2. Tell Claude to STOP its current approach and try something fundamentally different.
            3. If there are error messages, tell Claude to read them carefully and change strategy.
            4. Suggest a concrete alternative approach (e.g., "do a web search", "read the docs", \
            "try a different library", "check the error message").
            Do NOT just say "keep going" or approve — that will perpetuate the loop.

            """ : ""
            prompt = """
            You are acting as the human operator for Claude Code. Claude has paused. \
            Here is the terminal output:

            \(lastLines)
            \(loopWarning)
            If Claude asked a question, answer it directly. Pick the most thorough option. \
            If Claude finished work, reply with just: APPROVE \
            Only output the text to type into Claude.
            """
        }

        guard let codexPath = findCodex() else {
            PairLog.error("Codex not found")
            return CodexResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["exec", "--json", "-s", "read-only", prompt]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    PairLog.error("Codex timed out after \(Int(self.codexTimeoutSec))s — killing")
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + codexTimeoutSec, execute: timeoutItem)
            process.waitUntilExit()
            timeoutItem.cancel()
            let raw = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errOut = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if !errOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PairLog.error("Codex stderr: \(errOut.prefix(500))")
            }
            if process.terminationStatus != 0 {
                PairLog.error("Codex exited with code \(process.terminationStatus), stdout=\(raw.count) bytes")
            }
            var text = ""
            var deltaText = ""
            for line in raw.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let eventType = j["type"] as? String else { continue }
                if eventType == "item.completed",
                   let item = j["item"] as? [String: Any],
                   let t = item["text"] as? String {
                    text = t
                } else if eventType == "item.delta",
                          let delta = j["delta"] as? [String: Any],
                          let t = delta["text"] as? String {
                    deltaText += t
                }
            }
            if text.isEmpty && !deltaText.isEmpty {
                text = deltaText
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexResult(response: trimmed.isEmpty ? nil : trimmed, prompt: prompt, diffSummary: diffSummary)
        } catch {
            PairLog.error("Codex failed: \(error)")
            return CodexResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }
    }

    private static func gitDiffSummary(cwd: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--stat", "--no-color"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            return nil
        }
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
}
