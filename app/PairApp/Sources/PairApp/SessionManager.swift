import Foundation
import SwiftTerm

/// Manages all Claude terminal sessions.
class SessionManager: ObservableObject {
    static let shared = SessionManager()

    @Published var sessions: [PairSession] = []
    @Published var activeSessionId: String? {
        didSet {
            PairLog.info("Active session changed: \(oldValue ?? "nil") → \(activeSessionId ?? "nil")")
        }
    }

    var activeSession: PairSession? {
        if let id = activeSessionId {
            return sessions.first { $0.id == id }
        }
        return sessions.first
    }

    func createSession(cwd: String, id: String? = nil, command: String = "claude") {
        let sessionId = id ?? "pair-\(Int(Date().timeIntervalSince1970) % 100000)"
        PairLog.info("Creating session \(sessionId) in \(cwd)")
        let session = PairSession(id: sessionId, cwd: cwd, command: command)
        sessions.append(session)
        activeSessionId = sessionId
        PairLog.info("Sessions count: \(sessions.count)")
    }

    func removeSession(_ id: String) {
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions.remove(at: idx)
            // Switch to another session
            if activeSessionId == id {
                activeSessionId = sessions.first?.id
            }
        }
    }

    func findSession(_ query: String) -> PairSession? {
        if let s = sessions.first(where: { $0.id == query }) { return s }
        if let s = sessions.first(where: { $0.id.hasPrefix(query) }) { return s }
        let lower = query.lowercased()
        return sessions.first {
            ($0.cwd.split(separator: "/").last?.lowercased() ?? "").contains(lower)
        }
    }

    func stopAll() {
        sessions.removeAll()
    }

    func sendInput(sessionId: String, text: String) -> Bool {
        guard let session = findSession(sessionId) else { return false }
        session.injectInput(text + "\n")
        return true
    }
}

/// A single Claude + Codex pairing session.
class PairSession: Identifiable, ObservableObject {
    let id: String
    let cwd: String
    let command: String

    weak var terminalView: LocalProcessTerminalView?
    var currentDirectory: String

    init(id: String, cwd: String, command: String) {
        self.currentDirectory = cwd
        self.id = id
        self.cwd = cwd
        self.command = command
    }

    func start(in view: LocalProcessTerminalView) {
        self.terminalView = view

        // Use shell integration for proper env injection (ZDOTDIR trick)
        let env = ShellIntegration.shared.environment(sessionId: id, cwd: cwd)
        let envArray = env.map { "\($0.key)=\($0.value)" }

        view.startProcess(
            executable: "/usr/bin/env",
            args: ["claude"],
            environment: envArray,
            execName: "claude",
            currentDirectory: cwd
        )
    }

    func injectInput(_ text: String) {
        terminalView?.send(txt: text)
    }
}

struct CodexState {
    var cycle: Int = 0
    var status: String = "idle"
    var decision: String = ""
    var task: String = ""
    var feedback: String = ""
    var lastUpdate: Date = .distantPast
}
