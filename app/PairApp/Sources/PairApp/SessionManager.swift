import Foundation
import SwiftTerm

class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var sessions: [PairSession] = []
    @Published var showProjectPicker = false
    @Published var activeSessionId: String? {
        didSet { PairLog.info("Active session: \(oldValue ?? "nil") → \(activeSessionId ?? "nil")") }
    }

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

    func sendInput(sessionId: String, text: String) -> Bool {
        guard let session = findSession(sessionId) else { return false }
        session.injectInput(text + "\n")
        return true
    }
}

class PairSession: Identifiable, ObservableObject {
    let id: String
    let cwd: String
    weak var terminalView: LocalProcessTerminalView?
    var currentDirectory: String

    init(id: String, cwd: String) {
        self.id = id
        self.cwd = cwd
        self.currentDirectory = cwd
    }

    func start(in view: LocalProcessTerminalView) {
        self.terminalView = view
        let env = ShellIntegration.shared.environment(sessionId: id, cwd: cwd)
        let envArray = env.map { "\($0.key)=\($0.value)" }
        view.startProcess(executable: "/usr/bin/env", args: ["claude"],
                          environment: envArray, execName: "claude", currentDirectory: cwd)
    }

    func injectInput(_ text: String) {
        // Replace \n with \r for terminal submission (Enter = carriage return)
        let termText = text.replacingOccurrences(of: "\n", with: "\r")
        terminalView?.send(txt: termText)
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
