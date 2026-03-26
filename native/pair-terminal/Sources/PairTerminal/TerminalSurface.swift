import Foundation

/// A managed terminal surface — wraps a PTY-backed shell session.
/// Each surface corresponds to one Claude Code session.
class TerminalSurface {
    let id: String
    let cwd: String
    let command: [String]

    private(set) var title: String
    private(set) var pid: pid_t = 0
    private var masterFd: Int32 = -1
    private let readQueue = DispatchQueue(label: "surface.read")

    var onOutput: ((Data) -> Void)?

    init(id: String, cwd: String, command: [String] = ["/usr/bin/env", "claude"]) {
        self.id = id
        self.cwd = cwd
        self.command = command
        self.title = "pair-terminal: \(cwd.split(separator: "/").last ?? Substring(cwd))"
    }

    /// Launch the shell process in a PTY using posix_spawn with file actions.
    func start() throws {
        var master: Int32 = 0
        var slave: Int32 = 0

        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw SurfaceError.ptyOpenFailed
        }
        masterFd = master

        // Set terminal size
        var winSize = winsize(ws_row: 50, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &winSize)

        // Set up file actions: dup slave fd to stdin/stdout/stderr
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        if slave > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&fileActions, slave)
        }
        posix_spawn_file_actions_addclose(&fileActions, master)

        // Set up spawn attributes for new session
        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_SETSID))

        // Build argv
        let argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]

        // Build envp with custom vars
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["PAIR_TERMINAL_SURFACE"] = id
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]

        // Change to working directory before spawn
        let originalDir = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(cwd)

        var childPid: pid_t = 0
        let spawnResult = posix_spawnp(&childPid, command[0], &fileActions, &spawnAttr, argv, envp)

        // Restore directory
        FileManager.default.changeCurrentDirectoryPath(originalDir)

        // Clean up
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttr)
        argv.forEach { if let p = $0 { free(p) } }
        envp.forEach { if let p = $0 { free(p) } }
        close(slave)

        guard spawnResult == 0 else {
            close(masterFd)
            masterFd = -1
            throw SurfaceError.spawnFailed(errno: spawnResult)
        }

        self.pid = childPid
        NSLog("[Surface \(id)] Started PID \(childPid) in \(cwd)")

        readQueue.async { [weak self] in
            self?.readLoop()
        }
    }

    /// Send text as input to the terminal (as if the user typed it).
    func sendInput(_ text: String) -> Bool {
        guard masterFd >= 0 else { return false }
        guard let data = text.data(using: .utf8) else { return false }

        let written = data.withUnsafeBytes { ptr in
            write(masterFd, ptr.baseAddress, data.count)
        }

        if written > 0 {
            NSLog("[Surface \(id)] Sent \(written) bytes")
        }
        return written > 0
    }

    /// Send text followed by Enter.
    func sendLine(_ text: String) -> Bool {
        return sendInput(text + "\n")
    }

    /// Resize the terminal.
    func resize(cols: UInt16, rows: UInt16) {
        guard masterFd >= 0 else { return }
        var winSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &winSize)
    }

    /// Check if the child process is still running.
    var isAlive: Bool {
        guard pid > 0 else { return false }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        return result == 0
    }

    /// Stop the surface and clean up.
    func stop() {
        if pid > 0 {
            kill(pid, SIGTERM)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            pid = 0
        }
        if masterFd >= 0 {
            close(masterFd)
            masterFd = -1
        }
        NSLog("[Surface \(id)] Stopped")
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while masterFd >= 0 {
            let bytesRead = read(masterFd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            let data = Data(buffer[0..<bytesRead])
            DispatchQueue.main.async { [weak self] in
                self?.onOutput?(data)
            }
        }
    }

    enum SurfaceError: Error {
        case ptyOpenFailed
        case spawnFailed(errno: Int32)
    }
}
