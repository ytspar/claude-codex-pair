import Foundation
import SwiftTerm

class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var sessions: [PairSession] = []
    @Published var showProjectPicker = false
    @Published var showLogViewer = false
    @Published var activeSessionId: String? {
        didSet {
            PairLog.info("Active session: \(oldValue ?? "nil") → \(activeSessionId ?? "nil")")
            // Switch task queue to the active session's project
            let cwd = activeSession?.cwd
            TaskQueue.shared.setProject(cwd)
        }
    }

    private static let sessionFile: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-codex-pair/sessions.json"
    }()

    var activeSession: PairSession? {
        if let id = activeSessionId { return sessions.first { $0.id == id } }
        return sessions.first
    }

    func createSession(cwd: String, id: String? = nil, mode: PairSession.PairMode = .claudeLeads) {
        let sessionId = id ?? "pair-\(Int(Date().timeIntervalSince1970) % 100000)"
        PairLog.info("Creating session \(sessionId) in \(cwd) (mode: \(mode.rawValue))")
        let session = PairSession(id: sessionId, cwd: cwd)
        session.mode = mode
        sessions.append(session)
        activeSessionId = sessionId
    }

    func removeSession(_ id: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].stop()
            sessions.remove(at: idx)
            ClaudeMonitor.shared.removeSession(id)
            if activeSessionId == id { activeSessionId = sessions.first?.id }
        }
    }

    func findSession(_ query: String) -> PairSession? {
        if let s = sessions.first(where: { $0.id == query }) { return s }
        if let s = sessions.first(where: { $0.id.hasPrefix(query) }) { return s }
        let lower = query.lowercased()
        return sessions.first { ($0.cwd.split(separator: "/").last?.lowercased() ?? "").contains(lower) }
    }

    func stopAll() {
        sessions.forEach { $0.stop() }
        sessions.removeAll()
    }

    /// Save current session directories and modes so they can be restored after rebuild.
    func persistSessionDirs() {
        let entries = sessions.map { ["cwd": $0.cwd, "mode": $0.mode.rawValue] }
        guard !entries.isEmpty else { return }
        let data: [String: Any] = [
            "sessions": entries,
            "activeIndex": sessions.firstIndex(where: { $0.id == activeSessionId }) ?? 0
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data) {
            try? json.write(to: URL(fileURLWithPath: Self.sessionFile))
        }
        PairLog.info("Persisted \(entries.count) session(s) for restore")
    }

    /// Restore sessions from a previous run. Returns true if sessions were restored.
    @discardableResult
    func restoreSessions() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.sessionFile)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }

        // Support new format (sessions array with mode) and legacy (cwds array)
        let entries: [(cwd: String, mode: PairSession.PairMode)]
        if let sessionsArray = dict["sessions"] as? [[String: String]] {
            entries = sessionsArray.compactMap { entry in
                guard let cwd = entry["cwd"] else { return nil }
                let mode = PairSession.PairMode(rawValue: entry["mode"] ?? "claudeLeads") ?? .claudeLeads
                return (cwd, mode)
            }
        } else if let cwds = dict["cwds"] as? [String] {
            entries = cwds.map { ($0, .claudeLeads) }
        } else {
            return false
        }
        guard !entries.isEmpty else { return false }
        let activeIndex = dict["activeIndex"] as? Int ?? 0

        // Clean up the restore file so we don't re-restore on next launch
        try? FileManager.default.removeItem(atPath: Self.sessionFile)

        for entry in entries {
            guard FileManager.default.fileExists(atPath: entry.cwd) else { continue }
            createSession(cwd: entry.cwd, mode: entry.mode)
        }

        // Restore active tab
        if activeIndex < sessions.count {
            activeSessionId = sessions[activeIndex].id
        }

        PairLog.info("Restored \(sessions.count) session(s) from previous run")
        return !sessions.isEmpty
    }

    func sendInput(sessionId: String, text: String) -> Bool {
        guard let session = findSession(sessionId) else { return false }
        // Send text as-is — caller includes \n or \r if they want Enter
        session.recordOperatorPrompt(text, source: "IPC")
        session.injectInput(text)
        return true
    }
}

class PairSession: Identifiable, ObservableObject {
    let id: String
    let cwd: String
    weak var terminalView: PairTerminalView?
    var currentDirectory: String

    /// Tracks whether the last input was from the user (keyboard) or machine (Codex/IPC).
    /// The monitor uses this to avoid reviewing while the user is composing a prompt.
    enum InputSource { case user, machine }
    var lastInputSource: InputSource = .machine
    /// Timestamp of last machine-injected input
    var lastMachineInputTime: Date = .distantPast
    /// Timestamp of last user keystroke
    var lastUserInputTime: Date = .distantPast
    /// Recent operator prompts, used as goal context when the visible terminal
    /// no longer contains the original request.
    private var recentOperatorPrompts: [String] = []

    init(id: String, cwd: String) {
        self.id = id
        self.cwd = cwd
        self.currentDirectory = cwd
    }

    enum PairMode: String { case claudeLeads, codexLeads }
    var mode: PairMode = .claudeLeads

    func start(in view: PairTerminalView) {
        self.terminalView = view
        let env = ShellIntegration.shared.environment(sessionId: id, cwd: cwd)
        let envArray = env.map { "\($0.key)=\($0.value)" }
        switch mode {
        case .claudeLeads:
            view.startProcess(executable: "/usr/bin/env", args: ["claude"],
                              environment: envArray, execName: "claude", currentDirectory: cwd)
        case .codexLeads:
            let codexPath = CodexIntegration.findCodex() ?? "codex"
            view.startProcess(executable: codexPath, args: ["--full-auto"],
                              environment: envArray, execName: "codex", currentDirectory: cwd)
        }
    }

    func stop() {
        terminalView?.terminate()
        terminalView = nil
    }

    private static let maxInjectionLength = 4000

    func injectInput(_ text: String) {
        lastInputSource = .machine
        lastMachineInputTime = Date()
        // Sanitize: strip control characters (except newline), truncate length
        var sanitized = String(text.prefix(Self.maxInjectionLength))
        sanitized = sanitized.unicodeScalars.filter { $0 == "\n" || $0 == "\r" || ($0.value >= 0x20 && $0.value < 0x7F) || ($0.value > 0x9F) }.map(String.init).joined()

        // For multi-line text, use bracketed paste so newlines are treated as
        // literal text, not Enter presses. Then send a single \r to submit.
        if sanitized.contains("\n") || sanitized.contains("\r") {
            // Strip trailing newlines — we'll add our own \r to submit
            let body = sanitized
                .trimmingCharacters(in: .newlines)
            let escaped = "\u{1B}[200~\(body)\u{1B}[201~"
            terminalView?.sendPreservingScroll(txt: escaped)
            // Brief delay then submit
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.terminalView?.sendPreservingScroll(txt: "\r")
            }
        } else {
            // Single-line: just send with \r to submit
            terminalView?.sendPreservingScroll(txt: sanitized + "\r")
        }
    }

    /// Type text character by character, simulating real keyboard input.
    /// Needed for Ink-based TUIs (like Codex) that read raw keystrokes
    /// instead of buffered lines. Each character is sent as an individual
    /// pty write with a small delay between them.
    func typeInput(_ text: String, delayMs: Int = 10, completion: (() -> Void)? = nil) {
        lastInputSource = .machine
        lastMachineInputTime = Date()
        let chars = Array(text)
        guard !chars.isEmpty else { completion?(); return }

        func sendNext(index: Int) {
            guard index < chars.count else { completion?(); return }
            let ch = String(chars[index])
            // Send \r for newlines (Enter key)
            let toSend = (ch == "\n") ? "\r" : ch
            terminalView?.sendPreservingScroll(txt: toSend)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayMs) / 1000.0) {
                sendNext(index: index + 1)
            }
        }
        sendNext(index: 0)
    }

    /// Paste text into the terminal without submitting (no trailing Enter).
    /// Uses bracketed paste mode so multi-line text doesn't trigger early submission.
    func pasteInput(_ text: String) {
        lastInputSource = .user
        lastUserInputTime = Date()
        recordOperatorPrompt(text, source: "scratchpad")
        // Bracketed paste: terminal treats content as pasted text, not typed keystrokes.
        // This prevents newlines from being interpreted as Enter presses.
        let escaped = "\u{1B}[200~\(text)\u{1B}[201~"
        terminalView?.sendPreservingScroll(txt: escaped)
    }

    func recordOperatorPrompt(_ text: String, source: String) {
        let cleaned = Self.cleanPromptText(text)
        guard cleaned.count >= 3 else { return }
        recentOperatorPrompts.append("[\(source)] \(cleaned)")
        if recentOperatorPrompts.count > 5 {
            recentOperatorPrompts.removeFirst(recentOperatorPrompts.count - 5)
        }
    }

    func goalContext() -> String {
        var lines: [String] = []
        if let active = TaskQueue.shared.activeTask, active.status == .active {
            lines.append("Active queued task: \(active.prompt)")
        }
        let recent = recentOperatorPrompts.suffix(3)
        if !recent.isEmpty {
            lines.append("Recent operator prompts:")
            lines.append(contentsOf: recent)
        }
        return lines.joined(separator: "\n")
    }

    private static func cleanPromptText(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "\u{1B}[200~", with: "")
            .replacingOccurrences(of: "\u{1B}[201~", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
        cleaned = cleaned.unicodeScalars
            .filter { $0 == "\n" || ($0.value >= 0x20 && $0.value < 0x7F) || ($0.value > 0x9F) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 1200 ? String(cleaned.prefix(1200)) + "... (prompt truncated)" : cleaned
    }

    /// Send arrow key escape sequences for interactive selection prompts.
    /// Claude Code uses TUI widgets where you arrow down to select, then Enter.
    func sendArrowDown(_ count: Int = 1) {
        for _ in 0..<count {
            terminalView?.sendPreservingScroll(txt: "\u{1b}[B")  // ESC [ B = arrow down
        }
    }

    func sendArrowUp(_ count: Int = 1) {
        for _ in 0..<count {
            terminalView?.sendPreservingScroll(txt: "\u{1b}[A")  // ESC [ A = arrow up
        }
    }

    func sendEnter() {
        terminalView?.sendPreservingScroll(txt: "\r")
    }

    func sendEscape() {
        terminalView?.sendPreservingScroll(txt: "\u{1b}")
    }

    /// Select a numbered option in Claude's interactive prompts.
    /// Detects the current selection (❯ marker) and arrows to the target.
    func selectOption(_ optionNumber: Int, screenText: String? = nil) {
        let screen = screenText ?? readScreen()
        let optionCount = Self.selectionOptionCount(in: screen)
        let target = max(1, min(optionNumber, optionCount ?? optionNumber))
        let current = Self.currentSelectionIndex(in: screen) ?? 1
        let delta = target - current
        if delta > 0 {
            sendArrowDown(delta)
        } else if delta < 0 {
            sendArrowUp(-delta)
        } else {
            sendArrowDown(0)
        }
        // Brief delay for the UI to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendEnter()
        }
    }

    static func currentSelectionIndex(in screenText: String) -> Int? {
        var inferredIndex = 0
        for raw in screenText.split(separator: "\n").suffix(30).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isSelectionFooter(trimmed), !trimmed.hasPrefix("─") else { continue }

            let hasMarker = trimmed.hasPrefix("❯") || trimmed.hasPrefix("›")
            let markerStripped = hasMarker ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) : trimmed
            let explicitNumber = leadingOptionNumber(markerStripped)
            let isCandidate = hasMarker || explicitNumber != nil || looksLikeOptionText(markerStripped)
            guard isCandidate else { continue }

            if hasMarker, let explicitNumber { return explicitNumber }
            inferredIndex += 1
            if hasMarker { return inferredIndex }
        }
        return nil
    }

    static func selectionOptionCount(in screenText: String) -> Int? {
        var count = 0
        for raw in screenText.split(separator: "\n").suffix(30).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !isSelectionFooter(trimmed), !trimmed.hasPrefix("─") else { continue }
            let markerStripped = (trimmed.hasPrefix("❯") || trimmed.hasPrefix("›"))
                ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                : trimmed
            if leadingOptionNumber(markerStripped) != nil || trimmed.hasPrefix("❯") || trimmed.hasPrefix("›") {
                count += 1
            } else if count > 0 && looksLikeOptionText(markerStripped) {
                count += 1
            }
        }
        return count > 0 ? count : nil
    }

    private static func leadingOptionNumber(_ text: String) -> Int? {
        let prefix = text.prefix { $0.isNumber }
        guard !prefix.isEmpty else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        return Int(prefix)
    }

    private static func isSelectionFooter(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("enter to select")
            || lower.contains("to navigate")
            || lower.contains("esc to cancel")
            || lower.contains("shift+tab")
            || lower.contains("shift-tab")
    }

    private static func looksLikeOptionText(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard text.count <= 80,
              !text.hasSuffix("?"),
              !lower.contains("do you want"),
              !lower.contains("wants to"),
              !lower.contains("press "),
              !lower.contains("│") else { return false }
        let words = text.split(separator: " ")
        if words.count <= 6 { return true }
        return lower.contains("allow all") || lower.contains("yes") || lower.contains("no")
    }

    /// Dispatch feedback text to the terminal using the appropriate method for the session mode.
    /// Claude mode uses line-buffered injection; Codex mode uses keystroke simulation.
    func sendFeedback(_ text: String) {
        switch mode {
        case .claudeLeads:
            injectInput(text)
        case .codexLeads:
            typeInput(text + "\n")  // Codex (Ink) needs \n typed as Enter
        }
    }

    /// Read the visible terminal screen as plain text.
    /// Whether the terminal is currently in alternate screen buffer mode (used by full-screen TUI apps like Codex/Ink).
    var isAltBuffer: Bool {
        terminalView?.getTerminal().isCurrentBufferAlternate ?? false
    }

    func readScreen() -> String {
        guard let terminal = terminalView?.getTerminal() else { return "" }
        var lines: [String] = []
        for row in 0..<terminal.rows {
            var line = ""
            for col in 0..<terminal.cols {
                // getCharData returns the full cell data including the character
                if let charData = terminal.getCharData(col: col, row: row) {
                    let ch = terminal.getCharacter(for: charData)
                    if ch != "\0" {
                        line.append(ch)
                    } else {
                        line.append(" ")
                    }
                } else {
                    line.append(" ")
                }
            }
            lines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
