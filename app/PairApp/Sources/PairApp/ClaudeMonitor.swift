import Foundation

/// Monitors Claude by polling the SwiftTerm screen buffer every second.
/// Detects when Claude stops (screen content stabilizes) and triggers Codex.
class ClaudeMonitor: ObservableObject {
    static let shared = ClaudeMonitor()

    @Published var status: String = "idle"
    @Published var timeline: [TimelineEntry] = []
    @Published var lastCodexResponse: String = ""
    @Published var cycleCount: Int = 0

    struct TimelineEntry: Identifiable {
        let id = UUID()
        let time: Date
        let event: String
        let detail: String
    }

    private let pollQueue = DispatchQueue(label: "claude-monitor", qos: .userInitiated)
    private var dispatchTimer: DispatchSourceTimer?
    private var lastScreenHash: Int = 0
    private var stableCount = 0
    private var changeCount = 0
    private let stableThreshold = 5
    private var reviewInProgress = false
    private var lastWasApprove = false
    private var pollCount = 0

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.dispatchTimer = timer
        PairLog.info("ClaudeMonitor started")
    }

    func stop() { dispatchTimer?.cancel(); dispatchTimer = nil }

    private func addTimeline(_ event: String, _ detail: String) {
        let entry = TimelineEntry(time: Date(), event: event, detail: detail)
        DispatchQueue.main.async {
            self.timeline.insert(entry, at: 0)
            if self.timeline.count > 50 { self.timeline = Array(self.timeline.prefix(50)) }
        }
    }

    private func poll() {
        pollCount += 1
        let sessions = SessionManager.shared.sessions.count

        guard sessions > 0, let session = SessionManager.shared.activeSession else {
            if status != "idle" { DispatchQueue.main.async { self.status = "idle" } }
            stableCount = 0; changeCount = 0
            return
        }

        // Read screen on main thread (SwiftTerm is not thread-safe)
        var screenText = ""
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            screenText = session.readScreen()
            sem.signal()
        }
        sem.wait()

        let hash = screenText.hashValue

        if pollCount % 10 == 1 {
            PairLog.info("Poll #\(pollCount) screen=\(screenText.count)chars hash=\(hash == lastScreenHash ? "same" : "changed") changes=\(changeCount) stable=\(stableCount)")
        }

        if hash != lastScreenHash {
            lastScreenHash = hash
            stableCount = 0
            changeCount += 1
            lastWasApprove = false
            if status != "watching" && status != "reviewing" {
                DispatchQueue.main.async { self.status = "watching" }
            }
        } else {
            stableCount += 1
            // Require >= 10 screen changes before reviewing.
            // Welcome screen = ~4 changes. Claude working on a task = 10-50+ changes.
            // This prevents premature review on loading/idle screens.
            if stableCount == stableThreshold && changeCount >= 10 && !reviewInProgress && !lastWasApprove {
                PairLog.info("Claude idle \(stableThreshold)s after \(changeCount) changes, reviewing")
                changeCount = 0
                DispatchQueue.main.async {
                    self.cycleCount += 1
                    self.addTimeline("REVIEWING", "Claude idle, calling Codex (cycle \(self.cycleCount))")
                }
                triggerCodexReview(screenText: screenText, session: session)
            }
        }
    }

    private func triggerCodexReview(screenText: String, session: PairSession) {
        reviewInProgress = true
        DispatchQueue.main.async { self.status = "reviewing" }

        pollQueue.async { [weak self] in
            let response = self?.callCodex(screenText: screenText, cwd: session.cwd)

            DispatchQueue.main.async {
                self?.reviewInProgress = false
                guard let response = response, !response.isEmpty else {
                    self?.status = "watching"
                    return
                }
                PairLog.info("Codex: \(response.prefix(150))")
                self?.lastCodexResponse = response

                if response.uppercased().contains("APPROVE") {
                    self?.lastWasApprove = true
                    self?.status = "approved"
                    self?.addTimeline("APPROVED", "Codex approved Claude's work")
                } else {
                    self?.status = "feedback"
                    self?.addTimeline("FEEDBACK", String(response.prefix(200)))
                    // Send response + Enter so Claude receives it as submitted input
                    session.injectInput(response + "\n")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self?.status = "watching"
                        self?.stableCount = 0
                    }
                }
            }
        }
    }

    private func callCodex(screenText: String, cwd: String) -> String? {
        let lastLines = screenText.split(separator: "\n").suffix(40).joined(separator: "\n")
        let prompt = """
        You are acting as the human operator for Claude Code. Claude has paused. \
        Here is the terminal output:

        \(lastLines)

        If Claude asked a question, answer it directly. Pick the most thorough option. \
        If Claude finished work, reply with just: APPROVE \
        Only output the text to type into Claude.
        """

        guard let codexPath = findCodex() else { PairLog.error("Codex not found"); return nil }

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["exec", "--json", "-s", "read-only", prompt]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            let raw = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            var text = ""
            for line in raw.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      j["type"] as? String == "item.completed",
                      let item = j["item"] as? [String: Any],
                      let t = item["text"] as? String else { continue }
                text = t
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { PairLog.error("Codex failed: \(error)"); return nil }
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
