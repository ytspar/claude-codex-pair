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

    func createSession(cwd: String, id: String? = nil) {
        let sessionId = id ?? "pair-\(Int(Date().timeIntervalSince1970) % 100000)"
        PairLog.info("Creating session \(sessionId) in \(cwd)")
        let session = PairSession(id: sessionId, cwd: cwd)
        sessions.append(session)
        activeSessionId = sessionId
    }

    func removeSession(_ id: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
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

    func stopAll() { sessions.removeAll() }

    /// Save current session directories so they can be restored after rebuild.
    func persistSessionDirs() {
        let dirs = sessions.map { $0.cwd }
        guard !dirs.isEmpty else { return }
        let data: [String: Any] = [
            "cwds": dirs,
            "activeIndex": sessions.firstIndex(where: { $0.id == activeSessionId }) ?? 0
        ]
        if let json = try? JSONSerialization.data(withJSONObject: data) {
            try? json.write(to: URL(fileURLWithPath: Self.sessionFile))
        }
        PairLog.info("Persisted \(dirs.count) session dirs for restore")
    }

    /// Restore sessions from a previous run. Returns true if sessions were restored.
    @discardableResult
    func restoreSessions() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.sessionFile)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cwds = dict["cwds"] as? [String],
              !cwds.isEmpty else { return false }
        let activeIndex = dict["activeIndex"] as? Int ?? 0

        // Clean up the restore file so we don't re-restore on next launch
        try? FileManager.default.removeItem(atPath: Self.sessionFile)

        for cwd in cwds {
            guard FileManager.default.fileExists(atPath: cwd) else { continue }
            createSession(cwd: cwd)
        }

        // Restore active tab
        if activeIndex < sessions.count {
            activeSessionId = sessions[activeIndex].id
        }

        PairLog.info("Restored \(sessions.count) sessions from previous run")
        return true
    }

    func sendInput(sessionId: String, text: String) -> Bool {
        guard let session = findSession(sessionId) else { return false }
        // Send text as-is — caller includes \n or \r if they want Enter
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
    var lastInputSource: InputSource = .user
    /// Timestamp of last machine-injected input
    var lastMachineInputTime: Date = .distantPast

    init(id: String, cwd: String) {
        self.id = id
        self.cwd = cwd
        self.currentDirectory = cwd
    }

    func start(in view: PairTerminalView) {
        self.terminalView = view
        let env = ShellIntegration.shared.environment(sessionId: id, cwd: cwd)
        let envArray = env.map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: "/usr/bin/env", args: ["claude"],
                          environment: envArray, execName: "claude", currentDirectory: cwd)
    }

    private static let maxInjectionLength = 4000

    func injectInput(_ text: String) {
        lastInputSource = .machine
        lastMachineInputTime = Date()
        // Sanitize: strip control characters (except newline), truncate length
        var sanitized = String(text.prefix(Self.maxInjectionLength))
        sanitized = sanitized.unicodeScalars.filter { $0 == "\n" || $0 == "\r" || ($0.value >= 0x20 && $0.value < 0x7F) || $0.value > 0x7F }.map(String.init).joined()
        // Replace \n with \r for terminal submission (Enter = carriage return)
        let termText = sanitized.replacingOccurrences(of: "\n", with: "\r")
        terminalView?.sendPreservingScroll(txt: termText)
    }

    /// Paste text into the terminal without submitting (no trailing Enter).
    /// Uses bracketed paste mode so multi-line text doesn't trigger early submission.
    func pasteInput(_ text: String) {
        lastInputSource = .user
        // Bracketed paste: terminal treats content as pasted text, not typed keystrokes.
        // This prevents newlines from being interpreted as Enter presses.
        let escaped = "\u{1B}[200~\(text)\u{1B}[201~"
        terminalView?.sendPreservingScroll(txt: escaped)
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
    func selectOption(_ optionNumber: Int) {
        // Option 1 is usually the default (❯ is on it), so:
        // Option 1 = just press Enter
        // Option 2 = arrow down once + Enter
        // Option 3 = arrow down twice + Enter
        let arrowPresses = max(0, optionNumber - 1)
        sendArrowDown(arrowPresses)
        // Brief delay for the UI to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendEnter()
        }
    }

    /// Read the visible terminal screen as plain text.
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
