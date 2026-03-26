import Foundation
import Bridge

let args = CommandLine.arguments
let manager = SurfaceManager()
let ipc = IPCServer()
ipc.delegate = manager

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

do { try ipc.start() } catch {
    // IPC failure is non-fatal in attach mode
}

let isAttach = args.contains("--attach")
let isLaunch = args.contains("--launch")

if isAttach {
    quietMode = true
    freopen("/dev/null", "w", stderr)

    guard let cwdIdx = args.firstIndex(of: "--attach"), cwdIdx + 1 < args.count else {
        fputs("Usage: pair-terminal --attach <cwd> [--id <id>]\n", stdout)
        exit(1)
    }

    let cwd = args[cwdIdx + 1]
    let id: String
    if let idIdx = args.firstIndex(of: "--id"), idIdx + 1 < args.count {
        id = args[idIdx + 1]
    } else {
        id = UUID().uuidString.lowercased().prefix(12).description
    }

    let dashboard = Dashboard()

    do {
        let surface = try manager.createSurface(id: id, cwd: cwd)

        // Put terminal in raw mode first
        enableRawMode()

        // Set up dashboard (scroll region + status bar)
        dashboard.setup()

        // Resize PTY to match the Claude portion (left pane: claudeCols wide, full height)
        syncTerminalSize(surface: surface, dashboard: dashboard)

        // Mirror PTY output into the scroll region
        surface.onOutput = { data in
            dashboard.writePtyOutput(data)
        }

        // Forward stdin to PTY
        let stdinQueue = DispatchQueue(label: "stdin-reader")
        stdinQueue.async {
            let stdinHandle = FileHandle.standardInput
            while true {
                let data = stdinHandle.availableData
                if data.isEmpty { break }
                _ = surface.sendInput(String(data: data, encoding: .utf8) ?? "")
            }
            exit(0)
        }

        // Handle terminal resize
        signal(SIGWINCH) { _ in
            // Will be picked up by the status poll timer
        }

        // Poll Codex state and refresh status bar every 2 seconds
        let statusTimer = DispatchSource.makeTimerSource(queue: .main)
        statusTimer.schedule(deadline: .now(), repeating: 2.0)
        statusTimer.setEventHandler {
            dashboard.updateTermSize()
            dashboard.updateFromStateFile()
            // Also re-sync PTY size on resize
            syncTerminalSize(surface: surface, dashboard: dashboard)
        }
        statusTimer.resume()

        // Watch for child exit
        DispatchQueue.global().async {
            while surface.isAlive {
                Thread.sleep(forTimeInterval: 1.0)
            }
            dashboard.teardown()
            restoreTerminal()
            exit(0)
        }

        RunLoop.main.run()

    } catch {
        restoreTerminal()
        fputs("Failed to launch: \(error)\n", stdout)
        exit(1)
    }

} else if isLaunch {
    guard let cwdIdx = args.firstIndex(of: "--launch"), cwdIdx + 1 < args.count else {
        fputs("Usage: pair-terminal --launch <cwd> [--id <id>]\n", stderr)
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
        _ = try manager.createSurface(id: id, cwd: cwd)
    } catch {
        NSLog("[pair-terminal] Launch failed: \(error)")
    }
    RunLoop.main.run()

} else {
    NSLog("[pair-terminal] Daemon mode. Socket: ~/.claude-codex-pair/pair-terminal.sock")
    RunLoop.main.run()
}

// MARK: - Terminal helpers

private var originalTermios = termios()

func enableRawMode() {
    tcgetattr(STDIN_FILENO, &originalTermios)
    var raw = originalTermios
    raw.c_lflag &= ~UInt(ECHO | ICANON | ISIG | IEXTEN)
    raw.c_iflag &= ~UInt(IXON | ICRNL | BRKINT | INPCK | ISTRIP)
    raw.c_oflag &= ~UInt(OPOST)
    raw.c_cc.16 = 1   // VMIN
    raw.c_cc.17 = 0   // VTIME
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
}

func restoreTerminal() {
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
}

func syncTerminalSize(surface: TerminalSurface, dashboard: Dashboard) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 {
        dashboard.updateTermSize()
        // Claude gets the left pane width and full height
        surface.resize(cols: UInt16(dashboard.claudeCols), rows: ws.ws_row)
    }
}
