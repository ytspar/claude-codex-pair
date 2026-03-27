import Foundation
import GhosttyKit

/// Monitors Claude's terminal output to detect when it pauses.
/// When Claude stops (shows prompt, finishes response), triggers Codex review.
///
/// This replaces the hook-based approach — PairApp watches the terminal
/// directly since it owns the PTY.
class ClaudeMonitor: ObservableObject {
    static let shared = ClaudeMonitor()

    @Published var isClaudeActive = false
    @Published var lastActivity: Date = Date()

    private var activityTimer: Timer?
    private var idleThreshold: TimeInterval = 3.0  // seconds of no output = idle

    func start() {
        // Poll every second to check for activity
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkActivity()
        }
        PairLog.info("ClaudeMonitor started")
    }

    func stop() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    /// Called when terminal output is received (from Ghostty surface callback).
    func recordActivity() {
        let wasActive = isClaudeActive
        DispatchQueue.main.async { [weak self] in
            self?.lastActivity = Date()
            if !wasActive {
                self?.isClaudeActive = true
                PairLog.info("Claude became active")
            }
        }
    }

    private var reviewInProgress = false

    private func checkActivity() {
        let idle = Date().timeIntervalSince(lastActivity)

        if isClaudeActive && idle > idleThreshold {
            DispatchQueue.main.async {
                self.isClaudeActive = false
            }
            PairLog.info("Claude went idle after \(String(format: "%.1f", idle))s")

            // Trigger Codex review when Claude stops
            if !reviewInProgress {
                triggerCodexReview()
            }
        }
    }

    /// Call Codex to review Claude's work or answer its question.
    private func triggerCodexReview() {
        guard let session = SessionManager.shared.activeSession else { return }

        reviewInProgress = true
        PairLog.info("Triggering Codex review for session \(session.id)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Read the terminal screen to see what Claude said
            var screenText = ""
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                if let surface = session.ghosttyView?.surface {
                    var text = ghostty_text_s()
                    let sel = ghostty_selection_s()
                    if ghostty_surface_read_text(surface, sel, &text) {
                        if let ptr = text.text, text.text_len > 0 {
                            screenText = String(cString: ptr)
                        }
                        ghostty_surface_free_text(surface, &text)
                    }
                }
                semaphore.signal()
            }
            semaphore.wait()

            guard !screenText.isEmpty else {
                self?.reviewInProgress = false
                return
            }

            // Call Codex via the CLI
            let result = self?.callCodex(screenText: screenText, cwd: session.cwd)

            DispatchQueue.main.async {
                self?.reviewInProgress = false

                guard let result = result, !result.isEmpty else {
                    PairLog.info("Codex returned empty result")
                    return
                }

                PairLog.info("Codex responded: \(result.prefix(100))")

                // Send Codex's response to Claude
                session.injectInput(result)
            }
        }
    }

    /// Call codex exec with the screen content.
    private func callCodex(screenText: String, cwd: String) -> String? {
        let prompt = """
        You are reviewing a Claude Code terminal session. Claude has paused. Here is what's on screen:

        \(screenText.suffix(3000))

        If Claude asked a question, answer it directly. Choose the most thorough option.
        If Claude finished work, reply APPROVE if done, or give specific feedback.
        Keep your response concise — it will be typed into Claude's terminal.
        """

        let process = Process()
        let pipe = Pipe()

        let codexPaths = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node"
        var allPaths = codexPaths
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted().reversed() {
                allPaths.append("\(nvmDir)/\(v)/bin/codex")
            }
        }

        guard let codexPath = allPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            PairLog.error("Codex CLI not found")
            return nil
        }

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
