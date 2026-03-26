import Foundation

/// Renders a left/right split: Claude PTY on the left, Codex panel on the right.
///
/// Uses ANSI escape codes:
/// - Left margin/right margin (DECSLRM) to confine Claude's output to the left pane
/// - Direct cursor positioning to render the Codex panel on the right
class Dashboard {
    private let codexPanelWidth = 40
    private var termRows: Int = 50
    private var termCols: Int = 120
    private var lastStatus: CodexStatus = CodexStatus()
    private let lock = NSLock()

    struct CodexStatus {
        var sessionId: String = ""
        var cycle: Int = 0
        var status: String = "idle"
        var decision: String = ""
        var feedback: String = ""
        var response: String = ""
        var task: String = ""
    }

    /// Claude gets the left portion of the terminal.
    var claudeCols: Int { max(40, termCols - codexPanelWidth - 1) }

    /// Full terminal height for Claude.
    var claudeRows: Int { termRows }

    func setup() {
        updateTermSize()
        // Enable origin mode + left/right margins (DECLRMM)
        write("\u{1B}[?69h")
        // Set left/right margins: Claude gets columns 1..claudeCols
        write("\u{1B}[\(1);\(claudeCols)s")
        // Move cursor to top-left of Claude pane
        write("\u{1B}[1;1H")
        // Draw initial Codex panel
        renderCodexPanel()
    }

    func updateTermSize() {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
            termRows = Int(ws.ws_row)
            termCols = Int(ws.ws_col)
        }
    }

    /// Write Claude's PTY output — confined to the left pane by DECSLRM margins.
    func writePtyOutput(_ data: Data) {
        lock.lock()
        FileHandle.standardOutput.write(data)
        lock.unlock()
    }

    func updateFromStateFile() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let stateDir = "\(home)/.claude-codex-pair/state"

        guard let files = try? FileManager.default.contentsOfDirectory(atPath: stateDir) else { return }

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
            lastStatus.response = state["lastResponse"] as? String ?? ""
            lastStatus.feedback = lastStatus.response
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .filter { !["APPROVE", "FEEDBACK", "CONTEXT"].contains($0.trimmingCharacters(in: .whitespaces)) }
                .joined(separator: "\n")
        }

        renderCodexPanel()
    }

    /// Render the Codex panel on the right side of the terminal.
    func renderCodexPanel() {
        lock.lock()
        defer { lock.unlock() }

        let s = lastStatus
        let panelCol = claudeCols + 2  // Start column for the right panel
        let pw = codexPanelWidth - 1   // Usable width

        // Save cursor and disable margins temporarily so we can write to the right side
        write("\u{1B}7")           // Save cursor
        write("\u{1B}[?69l")       // Disable DECLRMM temporarily

        var row = 1

        // Separator line (vertical bar)
        for r in 1...termRows {
            moveTo(row: r, col: claudeCols + 1)
            write("\u{1B}[2m│\u{1B}[0m")
        }

        // Header
        moveTo(row: row, col: panelCol)
        clearPanelLine(row: row, col: panelCol, width: pw)
        write("\u{1B}[1;36m Codex Review \u{1B}[0m")
        row += 1

        // Separator
        moveTo(row: row, col: panelCol)
        clearPanelLine(row: row, col: panelCol, width: pw)
        write("\u{1B}[2m" + String(repeating: "─", count: pw) + "\u{1B}[0m")
        row += 1

        // Status
        moveTo(row: row, col: panelCol)
        clearPanelLine(row: row, col: panelCol, width: pw)
        let sc = colorForStatus(s.status)
        write(" \(sc)● \(s.status)\u{1B}[0m  cycle \(s.cycle)")
        row += 1

        // Decision
        if !s.decision.isEmpty {
            moveTo(row: row, col: panelCol)
            clearPanelLine(row: row, col: panelCol, width: pw)
            let dc = colorForDecision(s.decision)
            write(" \(dc)\(s.decision)\u{1B}[0m")
            row += 1
        }

        // Task
        row += 1 // blank line
        if !s.task.isEmpty {
            moveTo(row: row, col: panelCol)
            clearPanelLine(row: row, col: panelCol, width: pw)
            write("\u{1B}[2m Task:\u{1B}[0m")
            row += 1
            for line in wordWrap(s.task, width: pw - 2).prefix(3) {
                moveTo(row: row, col: panelCol)
                clearPanelLine(row: row, col: panelCol, width: pw)
                write(" \(line)")
                row += 1
            }
        }

        // Feedback
        if !s.feedback.isEmpty {
            row += 1
            moveTo(row: row, col: panelCol)
            clearPanelLine(row: row, col: panelCol, width: pw)
            write("\u{1B}[2m Feedback:\u{1B}[0m")
            row += 1
            let feedbackLines = s.feedback.split(separator: "\n").flatMap { line in
                wordWrap(String(line), width: pw - 2)
            }
            let maxFeedback = termRows - row - 2
            for line in feedbackLines.prefix(max(1, maxFeedback)) {
                moveTo(row: row, col: panelCol)
                clearPanelLine(row: row, col: panelCol, width: pw)
                write(" \(line)")
                row += 1
            }
            if feedbackLines.count > maxFeedback {
                moveTo(row: row, col: panelCol)
                clearPanelLine(row: row, col: panelCol, width: pw)
                write("\u{1B}[2m ... +\(feedbackLines.count - maxFeedback) lines\u{1B}[0m")
                row += 1
            }
        }

        // Clear remaining rows in the panel
        while row <= termRows {
            clearPanelLine(row: row, col: panelCol, width: pw)
            row += 1
        }

        // Bottom help line
        moveTo(row: termRows, col: panelCol)
        clearPanelLine(row: termRows, col: panelCol, width: pw)
        write("\u{1B}[2m IPC: pair-terminal.sock\u{1B}[0m")

        // Re-enable margins and restore cursor
        write("\u{1B}[?69h")
        write("\u{1B}[\(1);\(claudeCols)s")
        write("\u{1B}8")           // Restore cursor
    }

    func teardown() {
        write("\u{1B}[?69l")    // Disable DECLRMM
        write("\u{1B}[r")       // Reset scroll region
        write("\u{1B}[\(termRows);1H\n")
    }

    // MARK: - Helpers

    private func write(_ s: String) {
        if let data = s.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private func moveTo(row: Int, col: Int) {
        write("\u{1B}[\(row);\(col)H")
    }

    private func clearPanelLine(row: Int, col: Int, width: Int) {
        moveTo(row: row, col: col)
        write(String(repeating: " ", count: width))
        moveTo(row: row, col: col)
    }

    private func wordWrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [text] }
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    private func colorForStatus(_ status: String) -> String {
        switch status {
        case "reviewing": return "\u{1B}[33m"
        case "approved": return "\u{1B}[32m"
        case "feedback": return "\u{1B}[35m"
        case "error": return "\u{1B}[31m"
        default: return "\u{1B}[2m"
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
