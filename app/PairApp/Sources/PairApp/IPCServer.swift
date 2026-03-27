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

    func start() {
        let path = Self.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)

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

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { close(serverSocket); return }
        guard listen(serverSocket, 5) == 0 else { close(serverSocket); return }

        // Restrict socket to current user only
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
        switch request.action {
        case "send_input":
            guard let surfaceId = request.surface, let text = request.text else {
                return IPCResponse(ok: false, error: "Missing surface or text")
            }
            let success = SessionManager.shared.sendInput(sessionId: surfaceId, text: text)
            return IPCResponse(ok: success, error: success ? nil : "Session not found")

        case "list_sessions":
            let sessions = SessionManager.shared.sessions.map { ["id": $0.id, "cwd": $0.cwd] }
            if let data = try? JSONEncoder().encode(sessions), let str = String(data: data, encoding: .utf8) {
                return IPCResponse(ok: true, result: str)
            }
            return IPCResponse(ok: true, result: "[]")

        case "create_session":
            let cwd = request.text ?? FileManager.default.currentDirectoryPath
            DispatchQueue.main.async {
                SessionManager.shared.createSession(cwd: cwd, id: request.surface)
            }
            return IPCResponse(ok: true)

        case "read_screen":
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            guard let session = SessionManager.shared.findSession(surfaceId),
                  let termView = session.terminalView else {
                return IPCResponse(ok: false, error: "Session not found or no terminal")
            }
            // Read screen on main thread (SwiftTerm is not thread-safe)
            var screenText = ""
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                screenText = ScreenReader.readScreen(from: termView, scrollback: request.text == "--scrollback")
                semaphore.signal()
            }
            semaphore.wait()
            return IPCResponse(ok: true, result: screenText)

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
}

struct IPCResponse: Codable {
    let ok: Bool
    var result: String?
    var error: String?
}
