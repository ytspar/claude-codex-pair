import Foundation

/// Renders a split-pane dashboard: Claude PTY output on top, Codex status bar on bottom.
/// Uses ANSI escape codes to create scroll regions and fixed status lines.
class Dashboard {
    private let statusLines = 5  // Height of the Codex status area at the bottom
    private var termRows: Int = 50
    private var termCols: Int = 120
    private var lastStatus: CodexStatus = CodexStatus()

    struct CodexStatus {
        var sessionId: String = ""
        var cycle: Int = 0
        var status: String = "idle"
        var decision: String = ""
        var feedback: String = ""
        var task: String = ""
    }

    /// Set up the terminal: create a scroll region for Claude output,
    /// leaving the bottom lines for the Codex dashboard.
    func setup() {
        updateTermSize()

        // Set scroll region to top portion (leaves bottom lines fixed)
        let claudeRows = termRows - statusLines
        write("\u{1B}[1;\(claudeRows)r")  // Set scroll region: rows 1 to claudeRows
        write("\u{1B}[1;1H")               // Move cursor to top-left
        renderStatusBar()
    }

    /// Update terminal dimensions.
    func updateTermSize() {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            termRows = Int(ws.ws_row)
            termCols = Int(ws.ws_col)
        }
    }

    /// Get the number of rows available for the Claude PTY.
    var claudeRows: Int {
        return max(10, termRows - statusLines)
    }

    /// Write Claude's PTY output — it goes into the scroll region automatically
    /// because the scroll region is set to the top portion.
    func writePtyOutput(_ data: Data) {
        // Save cursor, ensure we're in the scroll region, restore
        // Actually, PTY output goes to stdout which is already in the scroll region
        FileHandle.standardOutput.write(data)
    }

    /// Update the Codex status from the state file.
    func updateFromStateFile() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stateDir = "\(home)/.claude-codex-pair/state"

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir) else { return }

        // Find the most recently updated state file
        var latestTime: Date = .distantPast
        var latestState: [String: Any]?

        for file in files where file.hasSuffix(".json") {
            let path = "\(stateDir)/\(file)"
            guard let data = FileManager.default.contents(atPath: path),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let updateStr = dict["lastUpdate"] as? String,
               let date = ISO8601DateFormatter().date(from: updateStr),
               date > latestTime {
                latestTime = date
                latestState = dict
                lastStatus.sessionId = file.replacingOccurrences(of: ".json", with: "")
            }
        }

        if let state = latestState {
            lastStatus.cycle = state["cycle"] as? Int ?? 0
            lastStatus.status = state["status"] as? String ?? "idle"
            lastStatus.decision = state["lastDecision"] as? String ?? ""
            lastStatus.task = state["task"] as? String ?? ""
            let response = state["lastResponse"] as? String ?? ""
            // Extract first meaningful line of feedback
            lastStatus.feedback = response
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .filter { !["APPROVE", "FEEDBACK", "CONTEXT"].contains($0.trimmingCharacters(in: .whitespaces)) }
                .first
                .map(String.init) ?? ""
        }

        renderStatusBar()
    }

    /// Render the fixed Codex status bar at the bottom of the terminal.
    func renderStatusBar() {
        let s = lastStatus
        let claudeH = claudeRows

        // Save cursor position
        write("\u{1B}7")

        // Move to the status area (below scroll region)
        let statusStart = claudeH + 1

        // Draw separator
        write("\u{1B}[\(statusStart);1H")
        let sep = String(repeating: "─", count: termCols)
        write("\u{1B}[2m\(sep)\u{1B}[0m")

        // Status line 1: header
        write("\u{1B}[\(statusStart + 1);1H\u{1B}[K")  // clear line
        let statusColor = colorForStatus(s.status)
        write(" \u{1B}[1;36mCodex\u{1B}[0m  \(statusColor)\(s.status)\u{1B}[0m  cycle \(s.cycle)")
        if !s.decision.isEmpty {
            let decColor = colorForDecision(s.decision)
            write("  \(decColor)\(s.decision)\u{1B}[0m")
        }

        // Status line 2: task
        write("\u{1B}[\(statusStart + 2);1H\u{1B}[K")
        if !s.task.isEmpty {
            let truncTask = String(s.task.prefix(termCols - 8))
            write(" \u{1B}[2mTask:\u{1B}[0m \(truncTask)")
        }

        // Status line 3: latest feedback
        write("\u{1B}[\(statusStart + 3);1H\u{1B}[K")
        if !s.feedback.isEmpty {
            let truncFeedback = String(s.feedback.prefix(termCols - 2))
            write(" \(truncFeedback)")
        }

        // Status line 4: help
        write("\u{1B}[\(statusStart + 4);1H\u{1B}[K")
        write(" \u{1B}[2mCodex reviews when Claude pauses • IPC: pair-terminal.sock\u{1B}[0m")

        // Restore cursor to scroll region
        write("\u{1B}8")
    }

    /// Tear down — restore full scroll region.
    func teardown() {
        write("\u{1B}[r")  // Reset scroll region to full terminal
        write("\u{1B}[\(termRows);1H\n") // Move to bottom
    }

    private func write(_ s: String) {
        if let data = s.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private func colorForStatus(_ status: String) -> String {
        switch status {
        case "reviewing": return "\u{1B}[33m"   // yellow
        case "approved": return "\u{1B}[32m"     // green
        case "feedback": return "\u{1B}[35m"     // magenta
        case "error": return "\u{1B}[31m"        // red
        default: return "\u{1B}[2m"              // dim
        }
    }

    private func colorForDecision(_ d: String) -> String {
        switch d {
        case "APPROVE": return "\u{1B}[32m"
        case "FEEDBACK": return "\u{1B}[33m"
        case "CONTEXT": return "\u{1B}[36m"
        default: return ""
        }
    }
}
