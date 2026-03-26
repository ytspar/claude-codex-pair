import Foundation
import Bridge

/// pair-terminal: headless terminal manager for claude-codex-pair.
///
/// Manages PTY-backed Claude Code sessions and exposes a unix socket IPC
/// server for the hook-handler to send input programmatically.
///
/// Usage:
///   pair-terminal                          # Start IPC server only (headless)
///   pair-terminal --launch <cwd>           # Launch a Claude session in <cwd>
///   pair-terminal --launch <cwd> --id <id> # Launch with specific session ID

let args = CommandLine.arguments
let manager = SurfaceManager()
let ipc = IPCServer()
ipc.delegate = manager

// Handle signals for clean shutdown
signal(SIGINT) { _ in
    NSLog("[pair-terminal] Shutting down...")
    exit(0)
}
signal(SIGTERM) { _ in
    NSLog("[pair-terminal] Shutting down...")
    exit(0)
}

// Start IPC server
do {
    try ipc.start()
} catch {
    NSLog("[pair-terminal] Failed to start IPC server: \(error)")
    exit(1)
}

// If --launch is provided, create a surface immediately
if let launchIdx = args.firstIndex(of: "--launch"), launchIdx + 1 < args.count {
    let cwd = args[launchIdx + 1]
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
}

NSLog("[pair-terminal] Running. Socket: ~/.claude-codex-pair/pair-terminal.sock")
NSLog("[pair-terminal] Send commands via: echo '{\"action\":\"list_surfaces\"}' | nc -U ~/.claude-codex-pair/pair-terminal.sock")

// Run the main run loop (keeps the process alive)
RunLoop.main.run()
