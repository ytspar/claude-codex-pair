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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        PairLog.info("ClaudeMonitor started (polling every 1s)")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll() {
        guard let session = SessionManager.shared.activeSession,
              let surface = session.ghosttyView?.surface else {
            if isClaudeActive {
                DispatchQueue.main.async {
                    self.isClaudeActive = false
                    self.status = SessionManager.shared.sessions.isEmpty ? "idle" : "watching"
                }
            }
            return
        }

        // Read current screen content
        let screenText = readScreen(surface: surface)
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

    private func readScreen(surface: ghostty_surface_t) -> String {
        var text = ghostty_text_s()
        let sel = ghostty_selection_s()
        var result = ""

        if ghostty_surface_read_text(surface, sel, &text) {
            if let ptr = text.text, text.text_len > 0 {
                result = String(cString: ptr)
            }
            ghostty_surface_free_text(surface, &text)
        }

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

    private func callCodex(screenText: String, cwd: String) -> String? {
        let lastLines = screenText.split(separator: "\n").suffix(30).joined(separator: "\n")

        let prompt = """
        You are reviewing a Claude Code session. Claude has paused. Here is the recent terminal output:

        \(lastLines)

        If Claude asked a question, answer it. Choose the most thorough option.
        If Claude finished work, say APPROVE if done, or give specific feedback.
        Be concise. Your response will be typed into Claude's terminal as user input.
        """

        let codexPaths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node"
        var allPaths = codexPaths
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted().reversed() {
                allPaths.append("\(nvmDir)/\(v)/bin/codex")
            }
        }

        guard let codexPath = allPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            PairLog.error("Codex not found")
            return nil
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["exec", "-s", "read-only", prompt]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            PairLog.error("Codex exec failed: \(error)")
            return nil
        }
    }
}
