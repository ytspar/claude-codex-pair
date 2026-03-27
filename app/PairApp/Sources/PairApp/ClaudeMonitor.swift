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

    func start() {
        // Must schedule on main RunLoop for Timer to fire
        DispatchQueue.main.async { [weak self] in
            self?.pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.poll()
            }
            RunLoop.main.add(self!.pollTimer!, forMode: .common)
            PairLog.info("ClaudeMonitor started (polling every 1s)")
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private var pollCount = 0
    private func poll() {
        pollCount += 1
        if pollCount % 10 == 1 {
            PairLog.info("Poll #\(pollCount), sessions=\(SessionManager.shared.sessions.count), active=\(isClaudeActive)")
        }
        guard let session = SessionManager.shared.activeSession,
              session.ghosttyView?.surface != nil else {
            if isClaudeActive {
                DispatchQueue.main.async {
                    self.isClaudeActive = false
                    self.status = SessionManager.shared.sessions.isEmpty ? "idle" : "watching"
                }
            }
            return
        }

        // Read screen on main thread (NSView access)
        let screenText = readScreen(surface: session.ghosttyView!.surface!)
        let currentHash = screenText.hashValue

        if currentHash != lastScreenHash {
            // Screen changed — Claude is active
            lastScreenHash = currentHash
            stableCount = 0
            if !isClaudeActive {
                DispatchQueue.main.async {
                    self.isClaudeActive = true
                    self.status = "watching"
                }
            }
        } else {
            // Screen unchanged
            stableCount += 1

            if stableCount == stableThreshold && isClaudeActive && !reviewInProgress {
                // Claude stopped producing output — trigger review
                DispatchQueue.main.async {
                    self.isClaudeActive = false
                    self.status = "reviewing"
                }
                PairLog.info("Claude idle for \(stableThreshold)s, triggering Codex review")
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
                self?.status = "feedback"

                // Type response into Claude
                session.injectInput(response)

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
        process.arguments = ["exec", "-s", "read-only", prompt]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // codex exec outputs the response text directly on stdout
            // stderr has the metadata (session info, token count, etc.)
            // Just return stdout, cleaned up
            let cleaned = raw
                .split(separator: "\n")
                .filter { line in
                    let l = line.trimmingCharacters(in: .whitespaces)
                    // Skip empty lines and codex metadata
                    return !l.isEmpty
                        && !l.hasPrefix("OpenAI Codex")
                        && !l.hasPrefix("workdir:")
                        && !l.hasPrefix("model:")
                        && !l.hasPrefix("provider:")
                        && !l.hasPrefix("approval:")
                        && !l.hasPrefix("sandbox:")
                        && !l.hasPrefix("reasoning")
                        && !l.hasPrefix("session id:")
                        && !l.hasPrefix("tokens used")
                        && !l.hasPrefix("--------")
                        && !l.hasPrefix("user")
                        && !l.hasPrefix("mcp startup:")
                        && !l.hasPrefix("codex")
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return cleaned.isEmpty ? nil : cleaned
        } catch {
            PairLog.error("Codex exec failed: \(error)")
            return nil
        }
    }
}
