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
    private var testIPCEnabled: Bool {
        if ProcessInfo.processInfo.environment["PAIR_ENABLE_TEST_IPC"] == "1" { return true }
        if ProcessInfo.processInfo.arguments.first?.contains("/.build/debug/") == true { return true }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

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
        if Self.isTestHarnessAction(request.action) && !testIPCEnabled {
            return IPCResponse(ok: false, error: "Test IPC action disabled: \(request.action)")
        }

        switch request.action {
        case "send_input":
            guard let surfaceId = request.surface, let text = request.text else {
                return IPCResponse(ok: false, error: "Missing surface or text")
            }
            return runOnMain {
                let success = SessionManager.shared.sendInput(sessionId: surfaceId, text: text)
                return IPCResponse(ok: success, error: success ? nil : "Session not found")
            }

        case "type_input":
            // Character-by-character typing for Ink-based TUIs (Codex)
            guard let surfaceId = request.surface, let text = request.text else {
                return IPCResponse(ok: false, error: "Missing surface or text")
            }
            var response = IPCResponse(ok: false, error: "No response")
            let typeSem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                guard let session = SessionManager.shared.findSession(surfaceId) else {
                    response = IPCResponse(ok: false, error: "Session not found")
                    typeSem.signal()
                    return
                }
                session.typeInput(text, delayMs: 15) {
                    response = IPCResponse(ok: true)
                    typeSem.signal()
                }
            }
            // Wait for typing to complete (text.count * 15ms + buffer)
            let typeTimeout = DispatchTime.now() + Double(text.count) * 0.02 + 5.0
            if typeSem.wait(timeout: typeTimeout) == .timedOut {
                return IPCResponse(ok: false, error: "Typing timed out")
            }
            return response

        case "list_sessions":
            return runOnMain {
                let sessions = SessionManager.shared.sessions.map { ["id": $0.id, "cwd": $0.cwd] }
                if let data = try? JSONEncoder().encode(sessions), let str = String(data: data, encoding: .utf8) {
                    return IPCResponse(ok: true, result: str)
                }
                return IPCResponse(ok: true, result: "[]")
            }

        case "create_session":
            let cwd = request.text ?? FileManager.default.currentDirectoryPath
            // Optional mode: "codexLeads" or "claudeLeads" (default)
            let mode: PairSession.PairMode = request.surface?.hasSuffix(":codex") == true ? .codexLeads : .claudeLeads
            let sessionId = request.surface?.replacingOccurrences(of: ":codex", with: "")
            return runOnMain {
                let id = SessionManager.shared.createSession(cwd: cwd, id: sessionId, mode: mode)
                return IPCResponse(ok: true, result: id)
            }

        case "read_screen":
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            return runOnMain {
                guard let session = SessionManager.shared.findSession(surfaceId) else {
                    return IPCResponse(ok: false, error: "Session not found")
                }
                return IPCResponse(ok: true, result: session.readScreen())
            }

        case "debug_screen":
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            return runOnMain {
                guard let session = SessionManager.shared.findSession(surfaceId) else {
                    return IPCResponse(ok: false, error: "Session not found")
                }
                let screen = session.readScreen()
                let isAlt = session.isAltBuffer
                if let tv = session.terminalView {
                    let t = tv.getTerminal()
                    return IPCResponse(ok: true, result: "alt=\(isAlt) rows=\(t.rows) cols=\(t.cols) len=\(screen.count)\n---\n\(screen)")
                }
                return IPCResponse(ok: true, result: "alt=\(isAlt) rows=0 cols=0 len=\(screen.count) (no terminal)\n---\n\(screen)")
            }

        case "send_key":
            guard let surfaceId = request.surface, let key = request.text else {
                return IPCResponse(ok: false, error: "Missing surface or key")
            }
            let keySequence = resolveKey(key)
            return runOnMain {
                guard let session = SessionManager.shared.findSession(surfaceId) else {
                    return IPCResponse(ok: false, error: "Session not found")
                }
                session.sendRawInput(keySequence)
                return IPCResponse(ok: true)
            }

        case "notify":
            let sessionId = request.surface ?? ""
            let title = request.text ?? "Notification"
            return runOnMain {
                NotificationStore.shared.addNotification(sessionId: sessionId, title: title, body: "")
                return IPCResponse(ok: true)
            }

        case "report_pwd":
            // Shell integration: update session's current directory
            return runOnMain {
                if let text = request.text, let surface = request.surface,
                   let session = SessionManager.shared.findSession(surface) {
                    session.currentDirectory = text
                }
                return IPCResponse(ok: true)
            }

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

        case "test_decision":
            // Test harness only: run a supplied structured decision through the
            // production FeedbackHandler path.
            guard let surfaceId = request.surface, let response = request.text else {
                return IPCResponse(ok: false, error: "Missing surface or text")
            }
            return runOnMain {
                guard let session = SessionManager.shared.findSession(surfaceId) else {
                    return IPCResponse(ok: false, error: "Session not found")
                }
                ClaudeMonitor.shared.handleTestDecision(session: session, response: response)
                return IPCResponse(ok: true)
            }

        case "test_feedback":
            // Test harness only: run a structured decision against a supplied
            // synthetic screen. Used when real Claude permission state is cached.
            guard let surfaceId = request.surface,
                  let text = request.text,
                  let data = text.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(IPCTestFeedbackPayload.self, from: data) else {
                return IPCResponse(ok: false, error: "Missing or invalid test_feedback payload")
            }
            return runOnMain {
                guard let session = SessionManager.shared.findSession(surfaceId) else {
                    return IPCResponse(ok: false, error: "Session not found")
                }
                let parsed = ScreenParser.parse(payload.screen)
                let entry = ClaudeMonitor.shared.handleTestFeedback(
                    session: session,
                    response: payload.response,
                    screenText: payload.screen,
                    dryRunSelection: payload.dryRunSelection ?? true
                )
                let state = IPCTestFeedbackState(
                    event: entry?.event,
                    detail: entry?.detail,
                    screenState: parsed.state.rawValue,
                    optionCount: PairSession.selectionOptionCount(in: payload.screen),
                    currentSelection: PairSession.currentSelectionIndex(in: payload.screen)
                )
                guard let data = try? JSONEncoder().encode(state),
                      let encoded = String(data: data, encoding: .utf8) else {
                    return IPCResponse(ok: false, error: "Failed to encode test feedback state")
                }
                return IPCResponse(ok: true, result: encoded)
            }

        case "test_unhelpful":
            // Test harness only: apply one neutral/regressed outcome through the
            // production backoff calculation.
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            return runOnMain {
                guard let session = SessionManager.shared.findSession(surfaceId) else {
                    return IPCResponse(ok: false, error: "Session not found")
                }
                let result = ClaudeMonitor.shared.handleTestUnhelpfulOutcome(session: session)
                let state = IPCTestBackoffState(streak: result.streak, backoff: result.backoff)
                guard let data = try? JSONEncoder().encode(state),
                      let encoded = String(data: data, encoding: .utf8) else {
                    return IPCResponse(ok: false, error: "Failed to encode backoff state")
                }
                return IPCResponse(ok: true, result: encoded)
            }

        case "queue_add", "queue_start", "queue_stop", "queue_clear", "queue_state":
            // Test harness queue controls. Auth is still required above, and the
            // queue is scoped to the target session's project directory.
            return handleQueueAction(request)

        case "remove_session":
            // Remove a session and its monitor state (used by test harness cleanup)
            guard let surfaceId = request.surface else {
                return IPCResponse(ok: false, error: "Missing surface")
            }
            return runOnMain {
                SessionManager.shared.removeSession(surfaceId)
                return IPCResponse(ok: true)
            }

        default:
            return IPCResponse(ok: false, error: "Unknown action: \(request.action)")
        }
    }

    private func handleQueueAction(_ request: IPCRequest) -> IPCResponse {
        guard let surfaceId = request.surface else {
            return IPCResponse(ok: false, error: "Missing surface")
        }

        var response = IPCResponse(ok: false, error: "No response")
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard let session = SessionManager.shared.findSession(surfaceId) else {
                response = IPCResponse(ok: false, error: "Session not found")
                semaphore.signal()
                return
            }

            switch request.action {
            case "queue_state":
                let snapshot = TaskQueue.shared.projectDir == session.cwd
                    ? TaskQueue.shared.snapshot()
                    : TaskQueue.snapshot(forProject: session.cwd)
                response = IPCResponse(ok: true, result: Self.encodeQueueState(snapshot))
                semaphore.signal()
                return
            case "queue_add":
                guard let prompt = request.text, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    response = IPCResponse(ok: false, error: "Missing text")
                    semaphore.signal()
                    return
                }
                TaskQueue.shared.setProject(session.cwd)
                TaskQueue.shared.addTask(prompt: prompt)
            case "queue_start":
                TaskQueue.shared.setProject(session.cwd)
                TaskQueue.shared.start()
            case "queue_stop":
                TaskQueue.shared.setProject(session.cwd)
                TaskQueue.shared.stop()
            case "queue_clear":
                TaskQueue.shared.setProject(session.cwd)
                TaskQueue.shared.stop()
                TaskQueue.shared.clearAll()
                ClaudeMonitor.shared.clearQueue(for: session.id)
            default:
                response = IPCResponse(ok: false, error: "Unknown queue action: \(request.action)")
                semaphore.signal()
                return
            }

            response = IPCResponse(ok: true, result: Self.encodeQueueState(TaskQueue.shared.snapshot()))
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return IPCResponse(ok: false, error: "Timed out waiting for main thread")
        }
        return response
    }

    private static func encodeQueueState(_ snapshot: TaskQueue.Snapshot) -> String {
        let state = IPCQueueState(
            isRunning: snapshot.isRunning,
            pendingCount: snapshot.pendingCount,
            activeTitle: snapshot.activeTitle,
            items: snapshot.items.map {
                IPCQueueItemState(
                    id: $0.id.uuidString,
                    title: $0.title,
                    prompt: $0.prompt,
                    status: $0.status.rawValue
                )
            }
        )
        guard let data = try? JSONEncoder().encode(state),
              let encoded = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return encoded
    }

    private func runOnMain(_ work: @escaping () -> IPCResponse) -> IPCResponse {
        if Thread.isMainThread {
            return work()
        }
        var response = IPCResponse(ok: false, error: "No response")
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            response = work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return IPCResponse(ok: false, error: "Timed out waiting for main thread")
        }
        return response
    }

    private static func isTestHarnessAction(_ action: String) -> Bool {
        if action.hasPrefix("queue_") { return true }
        return [
            "pause_monitor",
            "resume_monitor",
            "clear_queue",
            "test_decision",
            "test_feedback",
            "test_unhelpful",
            "remove_session",
        ].contains(action)
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

private struct IPCQueueState: Codable {
    let isRunning: Bool
    let pendingCount: Int
    let activeTitle: String?
    let items: [IPCQueueItemState]
}

private struct IPCQueueItemState: Codable {
    let id: String
    let title: String
    let prompt: String
    let status: String
}

private struct IPCTestBackoffState: Codable {
    let streak: Int
    let backoff: Double
}

private struct IPCTestFeedbackPayload: Codable {
    let screen: String
    let response: String
    let dryRunSelection: Bool?
}

private struct IPCTestFeedbackState: Codable {
    let event: String?
    let detail: String?
    let screenState: String
    let optionCount: Int?
    let currentSelection: Int?
}
