import Foundation
import Bridge

/// pair-terminal: managed terminal for claude-codex-pair.
///
/// Modes:
///   pair-terminal                              # Headless daemon (IPC server only)
///   pair-terminal --attach <cwd>               # Interactive: run Claude, mirror I/O, accept IPC input
///   pair-terminal --attach <cwd> --id <id>     # Interactive with specific session ID
///   pair-terminal --launch <cwd>               # Daemon: create surface in background
///
/// The --attach mode is what users run in a Ghostty tab. It:
/// 1. Creates a PTY running `claude` in the given directory
/// 2. Mirrors PTY output to stdout (so you see Claude's output)
/// 3. Forwards your keyboard input to the PTY (so you can type normally)
/// 4. Also accepts input via IPC from the hook handler (for Codex injection)

let args = CommandLine.arguments
let manager = SurfaceManager()
let ipc = IPCServer()
ipc.delegate = manager

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

// Start IPC server
do {
    try ipc.start()
} catch {
    fputs("[pair-terminal] Warning: IPC server failed to start: \(error)\n", stderr)
    // Continue anyway — attach mode still works for display, just no IPC injection
}

let isAttach = args.contains("--attach")
let isLaunch = args.contains("--launch")

if isAttach {
    // Suppress all logging in attach mode — it interleaves with PTY output
    quietMode = true
    // Redirect stderr to /dev/null to suppress NSLog from Bridge module
    freopen("/dev/null", "w", stderr)

    guard let cwdIdx = args.firstIndex(of: "--attach"), cwdIdx + 1 < args.count else {
        fputs("Usage: pair-terminal --attach <cwd> [--id <session-id>]\n", stderr)
        exit(1)
    }

    let cwd = args[cwdIdx + 1]
    let id: String
    if let idIdx = args.firstIndex(of: "--id"), idIdx + 1 < args.count {
        id = args[idIdx + 1]
    } else {
        id = UUID().uuidString.lowercased().prefix(12).description
    }

    do {
        let surface = try manager.createSurface(id: id, cwd: cwd)

        // Mirror PTY output to stdout
        surface.onOutput = { data in
            FileHandle.standardOutput.write(data)
        }

        // Put terminal in raw mode so we can forward keystrokes
        enableRawMode()

        // Forward stdin to PTY in background
        let stdinQueue = DispatchQueue(label: "stdin-reader")
        stdinQueue.async {
            let stdinHandle = FileHandle.standardInput
            while true {
                let data = stdinHandle.availableData
                if data.isEmpty { break }
                _ = surface.sendInput(String(data: data, encoding: .utf8) ?? "")
            }
            // stdin closed — Claude exited or user closed terminal
            exit(0)
        }

        // Match terminal size
        syncTerminalSize(surface: surface)
        signal(SIGWINCH) { _ in
            // Can't easily pass surface here, but the manager can find it
        }

        // No header output — keep terminal clean for Claude

        // Wait for child process to exit
        DispatchQueue.global().async {
            while surface.isAlive {
                Thread.sleep(forTimeInterval: 1.0)
            }
            fputs("\n[pair-terminal] Claude session ended.\n", stderr)
            restoreTerminal()
            exit(0)
        }

        RunLoop.main.run()

    } catch {
        fputs("[pair-terminal] Failed to launch: \(error)\n", stderr)
        exit(1)
    }

} else if isLaunch {
    // Background daemon mode — create surface without I/O mirroring
    guard let cwdIdx = args.firstIndex(of: "--launch"), cwdIdx + 1 < args.count else {
        fputs("Usage: pair-terminal --launch <cwd> [--id <session-id>]\n", stderr)
        exit(1)
    }

    let cwd = args[cwdIdx + 1]
    let id: String
    if let idIdx = args.firstIndex(of: "--id"), idIdx + 1 < args.count {
        id = args[idIdx + 1]
    } else {
        id = UUID().uuidString.lowercased()
    }

    do {
        let surface = try manager.createSurface(id: id, cwd: cwd)
        NSLog("[pair-terminal] Launched surface \(surface.id) in \(cwd)")
    } catch {
        NSLog("[pair-terminal] Failed to launch: \(error)")
    }

    RunLoop.main.run()

} else {
    // Pure daemon mode — IPC server only, surfaces created via IPC
    NSLog("[pair-terminal] Running as daemon. Socket: ~/.claude-codex-pair/pair-terminal.sock")
    RunLoop.main.run()
}

// MARK: - Terminal raw mode helpers

private var originalTermios = termios()

func enableRawMode() {
    tcgetattr(STDIN_FILENO, &originalTermios)
    var raw = originalTermios
    // Disable echo, canonical mode, signals
    raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
    // Disable input processing
    raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
    // Disable output processing
    raw.c_oflag &= ~UInt(OPOST)
    // Read byte-by-byte
    raw.c_cc.16 = 1  // VMIN
    raw.c_cc.17 = 0  // VTIME
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

func restoreTerminal() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
}

func syncTerminalSize(surface: TerminalSurface) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
        surface.resize(cols: ws.ws_col, rows: ws.ws_row)
    }
}
