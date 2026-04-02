import Foundation

/// JSON protocol for IPC communication between hook-handler and pair-terminal.
///
/// Requests:
///   {"action": "send_input", "surface": "<session-id>", "text": "..."}
///   {"action": "list_surfaces"}
///   {"action": "focus_surface", "surface": "<session-id>"}
///   {"action": "get_surface", "surface": "<session-id>"}
///
/// Responses:
///   {"ok": true, "result": ...}
///   {"ok": false, "error": "..."}

public struct IPCRequest: Codable {
    public let action: String
    public let surface: String?
    public let text: String?
}

public struct IPCResponse: Codable {
    public let ok: Bool
    public let result: String?
    public let error: String?

    public static func success(_ result: String? = nil) -> IPCResponse {
        IPCResponse(ok: true, result: result, error: nil)
    }

    public static func failure(_ error: String) -> IPCResponse {
        IPCResponse(ok: false, result: nil, error: error)
    }
}

public struct SurfaceInfo: Codable {
    public let id: String
    public let title: String
    public let pid: Int32?
    public let cwd: String?
    public let cols: Int
    public let rows: Int

    public init(id: String, title: String, pid: Int32?, cwd: String?, cols: Int, rows: Int) {
        self.id = id
        self.title = title
        self.pid = pid
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
    }
}

/// Delegate protocol  - the app implements this to handle IPC actions.
public protocol IPCServerDelegate: AnyObject {
    func handleSendInput(surfaceId: String, text: String) -> IPCResponse
    func handleListSurfaces() -> [SurfaceInfo]
    func handleFocusSurface(surfaceId: String) -> IPCResponse
    func handleGetSurface(surfaceId: String) -> IPCResponse
}

/// Unix domain socket IPC server.
/// Listens at ~/.claude-codex-pair/pair-terminal.sock
public class IPCServer {
    private let socketPath: String
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "pair-terminal.ipc", qos: .userInitiated)
    public weak var delegate: IPCServerDelegate?

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.claude-codex-pair"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.socketPath = "\(dir)/pair-terminal.sock"
    }

    public func start() throws {
        // Remove stale socket
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw IPCError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
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
        guard bindResult == 0 else {
            close(serverSocket)
            throw IPCError.bindFailed(errno: errno)
        }

        guard listen(serverSocket, 5) == 0 else {
            close(serverSocket)
            throw IPCError.listenFailed
        }

        isRunning = true
        NSLog("[IPC] Listening on \(socketPath)")

        // Use DispatchSource for non-blocking accept (works with RunLoop.main.run())
        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        self.acceptSource = source
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        source.resume()
    }

    private var acceptSource: DispatchSourceRead?

    public func stop() {
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil
        unlink(socketPath)
        NSLog("[IPC] Stopped")
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientSocket = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverSocket, $0, &clientLen)
            }
        }

        guard clientSocket >= 0 else {
            NSLog("[IPC] Accept error: \(errno)")
            return
        }

        NSLog("[IPC] Accepted connection")
        queue.async { [weak self] in
            self?.handleConnection(clientSocket)
        }
    }

    private func handleConnection(_ clientFd: Int32) {
        defer { close(clientFd) }

        // Set a read timeout so we don't block forever
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Read until we get a complete JSON object or timeout
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)

        while true {
            let bytesRead = read(clientFd, &buffer, buffer.count)
            NSLog("[IPC] read returned \(bytesRead)")
            if bytesRead <= 0 { break }
            accumulated.append(contentsOf: buffer[0..<bytesRead])
            NSLog("[IPC] accumulated \(accumulated.count) bytes")

            // Try to parse  - if valid JSON, we have the full request
            if (try? JSONDecoder().decode(IPCRequest.self, from: accumulated)) != nil {
                NSLog("[IPC] Parsed request successfully")
                break
            }
        }

        guard !accumulated.isEmpty else { return }

        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: accumulated) else {
            sendResponse(clientFd, .failure("Invalid JSON request"))
            return
        }

        let response = dispatch(request)
        sendResponse(clientFd, response)
    }

    private func dispatch(_ request: IPCRequest) -> IPCResponse {
        guard let delegate = delegate else {
            return .failure("No delegate configured")
        }

        switch request.action {
        case "send_input":
            guard let surfaceId = request.surface, let text = request.text else {
                return .failure("send_input requires 'surface' and 'text'")
            }
            return delegate.handleSendInput(surfaceId: surfaceId, text: text)

        case "list_surfaces":
            let surfaces = delegate.handleListSurfaces()
            if let json = try? JSONEncoder().encode(surfaces),
               let str = String(data: json, encoding: .utf8) {
                return .success(str)
            }
            return .failure("Failed to serialize surfaces")

        case "focus_surface":
            guard let surfaceId = request.surface else {
                return .failure("focus_surface requires 'surface'")
            }
            return delegate.handleFocusSurface(surfaceId: surfaceId)

        case "get_surface":
            guard let surfaceId = request.surface else {
                return .failure("get_surface requires 'surface'")
            }
            return delegate.handleGetSurface(surfaceId: surfaceId)

        default:
            return .failure("Unknown action: \(request.action)")
        }
    }

    private func sendResponse(_ socket: Int32, _ response: IPCResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        data.withUnsafeBytes { ptr in
            _ = write(socket, ptr.baseAddress, data.count)
        }
    }

    enum IPCError: Error {
        case socketCreationFailed
        case bindFailed(errno: Int32)
        case listenFailed
    }
}
