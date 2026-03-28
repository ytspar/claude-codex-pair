import Foundation
import GhosttyKit

/// Monitors Claude's terminal by polling screen content every second.
/// When the screen stops changing for a few seconds, triggers Codex review.
class ClaudeMonitor: ObservableObject {
    static let shared = ClaudeMonitor()

    @Published var isClaudeActive = false
    @Published var status: String = "idle"  // idle, watching, reviewing

    private var pollTimer: Timer?
    private var lastScreenHash: Int = 0
    private var stableCount = 0          // how many polls the screen hasn't changed
    private let stableThreshold = 5      // 5 polls (5 seconds) of no change = idle
    private var reviewInProgress = false
    private var lastWasApprove = false
    private var lastReviewedHash = 0
    private var changeCount = 0  // How many screen changes since last stable

    private let pollQueue = DispatchQueue(label: "claude-monitor", qos: .userInitiated)
    private var dispatchTimer: DispatchSourceTimer?

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.dispatchTimer = timer
        PairLog.info("ClaudeMonitor started (polling every 1s)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private var pollCount = 0
    private func poll() {
        pollCount += 1
        let sessionCount = SessionManager.shared.sessions.count

        if pollCount % 10 == 1 {
            let hasSurface = SessionManager.shared.activeSession?.ghosttyView?.surface != nil
            PairLog.info("Poll #\(pollCount), sessions=\(sessionCount), surface=\(hasSurface), active=\(isClaudeActive), status=\(status)")
        }

        // No sessions = idle
        guard let session = SessionManager.shared.activeSession else {
            if status != "idle" {
                DispatchQueue.main.async {
                    self.isClaudeActive = false
                    self.status = "idle"
                }
            }
            return
        }

        // Session exists but surface not ready yet = watching (waiting for init)
        guard let surface = session.ghosttyView?.surface else {
            if status != "watching" && sessionCount > 0 {
                DispatchQueue.main.async {
                    self.status = "watching"
                }
            }
            return
        }

        // Read screen
        let screenText = readScreen(surface: surface)
        let currentHash = screenText.hashValue

        if currentHash != lastScreenHash {
            // Screen changed — Claude is active
            lastScreenHash = currentHash
            stableCount = 0
            changeCount += 1
            lastWasApprove = false
            if !isClaudeActive {
                DispatchQueue.main.async {
                    self.isClaudeActive = true
                    self.status = "watching"
                }
            }
        } else {
            // Screen unchanged
            stableCount += 1

            // Only trigger review if:
            // 1. Screen was actively changing (changeCount >= 3 = Claude was working, not just a keystroke)
            // 2. Now stable for threshold seconds
            // 3. Not already reviewed or approved
            if stableCount == stableThreshold && changeCount >= 3 && !reviewInProgress && !lastWasApprove {
                // Claude stopped producing output — trigger review
                DispatchQueue.main.async {
                    self.isClaudeActive = false
                    self.status = "reviewing"
                }
                PairLog.info("Claude idle for \(stableThreshold)s after \(changeCount) changes, triggering Codex review")
                changeCount = 0
                triggerCodexReview(screenText: screenText, session: session)
            }
        }
    }

    /// Read screen by using macOS accessibility to get the terminal text.
    /// ghostty_surface_read_text needs complex selection setup, so we use
    /// the NSView's accessibility value instead.
    private func readScreen(surface: ghostty_surface_t) -> String {
        // Try accessibility API on the Ghostty NSView
        var result = ""
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            if let session = SessionManager.shared.activeSession,
               let view = session.ghosttyView {
                // Use the accessibility API to get terminal text
                if let axValue = view.accessibilityValue() as? String {
                    result = axValue
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private func triggerCodexReview(screenText: String, session: PairSession) {
        reviewInProgress = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response = self?.callCodex(screenText: screenText, cwd: session.cwd)

            DispatchQueue.main.async {
                self?.reviewInProgress = false

                guard let response = response, !response.isEmpty else {
                    PairLog.info("Codex returned empty")
                    self?.status = "watching"
                    return
                }

                PairLog.info("Codex: \(response.prefix(150))")

                if response.uppercased().contains("APPROVE") {
                    self?.lastWasApprove = true
                    self?.status = "approved"
                    // Don't type APPROVE into Claude
                } else {
                    self?.status = "feedback"
                    // Type feedback into Claude
                    session.injectInput(response)
                }

                // Reset so we watch for the next cycle
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.status = "watching"
                    self?.stableCount = 0
                    self?.lastScreenHash = 0
                }
            }
        }
    }

    private func findCodex() -> String? {
        let paths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node"
        var allPaths = paths
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted().reversed() {
                allPaths.append("\(nvmDir)/\(v)/bin/codex")
            }
        }
        return allPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    private func callCodex(screenText: String, cwd: String) -> String? {
        let lastLines = screenText.split(separator: "\n").suffix(40).joined(separator: "\n")

        let prompt = """
        You are acting as the human operator for Claude Code. Claude has paused. \
        Here is the terminal output:

        \(lastLines)

        If Claude asked a question, answer it directly and concisely. \
        If Claude offers options, pick the most thorough one. \
        If Claude finished work, reply with just: APPROVE \
        Only output the text to type into Claude. No explanation, no metadata.
        """

        guard let codexPath = findCodex() else {
            PairLog.error("Codex not found")
            return nil
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
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""

            // --json outputs JSONL events. Extract text from item.completed events.
            var responseText = ""
            for line in raw.split(separator: "\n") {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let type = json["type"] as? String else { continue }

                if type == "item.completed",
                   let item = json["item"] as? [String: Any],
                   let text = item["text"] as? String {
                    responseText = text
                }
            }

            let cleaned = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            PairLog.error("Codex exec failed: \(error)")
            return nil
        }
    }
}
