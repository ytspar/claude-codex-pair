import Foundation

/// Unix socket IPC server for hook-handler communication.
class IPCServer {
    static let shared = IPCServer()
    static var socketPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-codex-pair/pair-terminal.sock"
    }

    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "pair-app.ipc", qos: .userInitiated)
    private var acceptSource: DispatchSourceRead?
    private(set) var authToken: String = ""

    static var tokenPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-codex-pair/auth-token"
    }

    func start() {
        let path = Self.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)

        // Generate auth token and write with restricted permissions
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        authToken = bytes.map { String(format: "%02x", $0) }.joined()
        let tokenPath = Self.tokenPath
        FileManager.default.createFile(atPath: tokenPath, contents: authToken.data(using: .utf8))
        chmod(tokenPath, 0o600)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    strcpy(dest, ptr)
                }
            }
        }

        // Set restrictive umask before bind so socket is never world-accessible
        let oldMask = umask(0o077)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        guard bindResult == 0 else { close(serverSocket); return }
        guard listen(serverSocket, 5) == 0 else { close(serverSocket); return }

        // Belt-and-suspenders: also chmod in case umask wasn't effective
        chmod(path, 0o600)

        isRunning = true
        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        self.acceptSource = source
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.resume()
    }

    func stop() {
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil
        if serverSocket >= 0 { close(serverSocket); serverSocket = -1 }
        unlink(Self.socketPath)
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverSocket, $0, &clientLen)
            }
        }
        guard clientFd >= 0 else { return }
        queue.async { [weak self] in self?.handleConnection(clientFd) }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            accumulated.append(contentsOf: buffer[0..<n])
            if accumulated.count > 1_048_576 {
                sendResponse(fd, IPCResponse(ok: false, error: "Request too large (>1MB)"))
                return
            }
            if let _ = try? JSONDecoder().decode(IPCRequest.self, from: accumulated) { break }
        }

        guard !accumulated.isEmpty,
              let request = try? JSONDecoder().decode(IPCRequest.self, from: accumulated) else {
            sendResponse(fd, IPCResponse(ok: false, error: "Invalid request"))
            return
        }

        let response = dispatch(request)
        sendResponse(fd, response)
    }

    private func dispatch(_ request: IPCRequest) -> IPCResponse {
        // Validate auth token on all requests
        guard request.token == authToken else {
            return IPCResponse(ok: false, error: "Invalid or missing auth token")
        }

        switch request.action {
        case "send_input":
            guard let surfaceId = request.surface, let text = request.text else {
                return IPCResponse(ok: false, error: "Missing surface or text")
            }
            // Dispatch to main thread for thread-safe access to @Published sessions
            var success = false
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                success = SessionManager.shared.sendInput(sessionId: surfaceId, text: text)
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 10) == .timedOut {
                return IPCResponse(ok: false, error: "Timed out waiting for main thread")
            }
            return IPCResponse(ok: success, error: success ? nil : "Session not found")

        case "type_input":
            // Character-by-character typing for Ink-based TUIs (Codex)
            guard let surfaceId = request.surface, let text = request.text else {
                return IPCResponse(ok: false, error: "Missing surface or text")
            }
            guard let session = SessionManager.shared.findSession(surfaceId) else {
                return IPCResponse(ok: false, error: "Session not found")
            }
            let typeSem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                session.typeInput(text, delayMs: 15) {
                    typeSem.signal()
                }
            }
            // Wait for typing to complete (text.count * 15ms + buffer)
            let typeTimeout = DispatchTime.now() + Double(text.count) * 0.02 + 5.0
            if typeSem.wait(timeout: typeTimeout) == .timedOut {
                return IPCResponse(ok: false, error: "Typing timed out")
            }
            return IPCResponse(ok: true)

        case "list_sessions":
            let sessions = SessionManager.shared.sessions.map { ["id": $0.id, "cwd": $0.cwd] }
            if let data = try? JSONEncoder().encode(sessions), let str = String(data: data, encoding: .utf8) {
                return IPCResponse(ok: true, result: str)
            }
            return IPCResponse(ok: true, result: "[]")

        case "create_session":
            let cwd = request.text ?? FileManager.default.currentDirectoryPath
            // Optional mode: "codexLeads" or "claudeLeads" (default)
            let mode: PairSession.PairMode = request.surface?.hasSuffix(":codex") == true ? .codexLeads : .claudeLeads
            let sessionId = request.surface?.replacingOccurrences(of: ":codex", with: "")
            DispatchQueue.main.async {
                SessionManager.shared.createSession(cwd: cwd, id: sessionId, mode: mode)
            }
            return IPCResponse(ok: true)

        case "read_screen":
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            guard let session = SessionManager.shared.findSession(surfaceId) else {
                return IPCResponse(ok: false, error: "Session not found")
            }
            var screenText = ""
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                screenText = session.readScreen()
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 10) == .timedOut {
                return IPCResponse(ok: false, error: "Timed out waiting for main thread")
            }
            return IPCResponse(ok: true, result: screenText)

        case "debug_screen":
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            guard let session = SessionManager.shared.findSession(surfaceId) else {
                return IPCResponse(ok: false, error: "Session not found")
            }
            var info = ""
            let dbgSem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                let screen = session.readScreen()
                let isAlt = session.isAltBuffer
                if let tv = session.terminalView {
                    let t = tv.getTerminal()
                    info = "alt=\(isAlt) rows=\(t.rows) cols=\(t.cols) len=\(screen.count)\n---\n\(screen)"
                } else {
                    info = "alt=\(isAlt) rows=0 cols=0 len=\(screen.count) (no terminal)\n---\n\(screen)"
                }
                dbgSem.signal()
            }
            if dbgSem.wait(timeout: .now() + 10) == .timedOut {
                return IPCResponse(ok: false, error: "Timed out")
            }
            return IPCResponse(ok: true, result: info)

        case "send_key":
            guard let surfaceId = request.surface, let key = request.text else {
                return IPCResponse(ok: false, error: "Missing surface or key")
            }
            guard let session = SessionManager.shared.findSession(surfaceId) else {
                return IPCResponse(ok: false, error: "Session not found")
            }
            let keySequence = resolveKey(key)
            session.injectInput(keySequence)
            return IPCResponse(ok: true)

        case "notify":
            let sessionId = request.surface ?? ""
            let title = request.text ?? "Notification"
            DispatchQueue.main.async {
                NotificationStore.shared.addNotification(sessionId: sessionId, title: title, body: "")
            }
            return IPCResponse(ok: true)

        case "report_pwd":
            // Shell integration: update session's current directory
            if let text = request.text, let surface = request.surface,
               let session = SessionManager.shared.findSession(surface) {
                DispatchQueue.main.async {
                    session.currentDirectory = text
                }
            }
            return IPCResponse(ok: true)

        case "report_cmd":
            // Shell integration: log command execution
            return IPCResponse(ok: true)

        case "pause_monitor":
            // Pause monitor polling for a session (used by test harness between tests)
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            let pst = ClaudeMonitor.shared.sessionStatesLock.withLock {
                ClaudeMonitor.shared.sessionStates[surfaceId]
            }
            pst?.paused = true
            pst?.clearInjectionQueue()
            return IPCResponse(ok: true)

        case "resume_monitor":
            // Resume monitor polling for a session
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            let rst = ClaudeMonitor.shared.sessionStatesLock.withLock {
                ClaudeMonitor.shared.sessionStates[surfaceId]
            }
            rst?.paused = false
            return IPCResponse(ok: true)

        case "clear_queue":
            // Clear the injection queue for a session (used by test harness)
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            ClaudeMonitor.shared.clearQueue(for: surfaceId)
            return IPCResponse(ok: true)

        case "remove_session":
            // Remove a session and its monitor state (used by test harness cleanup)
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            let removeSemaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                SessionManager.shared.removeSession(surfaceId)
                removeSemaphore.signal()
            }
            if removeSemaphore.wait(timeout: .now() + 10) == .timedOut {
                return IPCResponse(ok: false, error: "Timed out waiting for main thread")
            }
            return IPCResponse(ok: true)

        default:
            return IPCResponse(ok: false, error: "Unknown action: \(request.action)")
        }
    }

    private func sendResponse(_ fd: Int32, _ response: IPCResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        data.withUnsafeBytes { ptr in _ = write(fd, ptr.baseAddress, data.count) }
    }
}

/// Resolve named keys to terminal escape sequences (matches cmux protocol).
private func resolveKey(_ name: String) -> String {
    switch name.lowercased() {
    case "enter", "return": return "\r"
    case "tab": return "\t"
    case "escape", "esc": return "\u{1B}"
    case "backspace": return "\u{7F}"
    case "ctrl-c", "sigint": return "\u{03}"
    case "ctrl-d", "eof": return "\u{04}"
    case "ctrl-z", "sigtstp": return "\u{1A}"
    case "ctrl-\\", "sigquit": return "\u{1C}"
    case "up": return "\u{1B}[A"
    case "down": return "\u{1B}[B"
    case "right": return "\u{1B}[C"
    case "left": return "\u{1B}[D"
    case "home": return "\u{1B}[H"
    case "end": return "\u{1B}[F"
    case "delete": return "\u{1B}[3~"
    case "pageup": return "\u{1B}[5~"
    case "pagedown": return "\u{1B}[6~"
    default:
        // ctrl-<letter> pattern
        if name.lowercased().hasPrefix("ctrl-"), name.count == 6 {
            let letter = name.last!
            let code = Int(letter.asciiValue ?? 0) - 96  // a=1, b=2, etc.
            if code > 0 && code < 27 {
                return String(UnicodeScalar(code)!)
            }
        }
        return name
    }
}

struct IPCRequest: Codable {
    let action: String
    let surface: String?
    let text: String?
    let token: String?
}

struct IPCResponse: Codable {
    let ok: Bool
    var result: String?
    var error: String?
}
