import Foundation

/// Manages Claude Code hook installation/removal.
/// Hooks are Node.js scripts that need to be registered in ~/.claude/settings.json.
enum HookManager {

    /// Install the Stop + PermissionRequest hooks.
    static func install() {
        runNodeScript("""
            import { installHook } from './dist/monitor/daemon.js';
            installHook();
        """)
        PairLog.info("Hooks installed")
    }

    /// Remove hooks.
    static func remove() {
        runNodeScript("""
            import { removeHook } from './dist/monitor/daemon.js';
            removeHook();
        """)
        PairLog.info("Hooks removed")
    }

    /// Check if hooks are installed.
    static func isInstalled() -> Bool {
        let output = runNodeScript("""
            import { isHookInstalled } from './dist/monitor/daemon.js';
            console.log(isHookInstalled() ? 'true' : 'false');
        """)
        return output?.contains("true") ?? false
    }

    /// Find the project root (where dist/ lives) by looking relative to the binary.
    private static func findProjectRoot() -> String? {
        // When running from .build/debug or .build/release, project root is ../../..
        let binaryURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = binaryURL.deletingLastPathComponent()

        // Walk up looking for package.json (the Node project root)
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent("dist/monitor/daemon.js")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }

        // Try the repo root directly
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let knownPaths = [
            "\(home)/git/ytspar/claude-codex-pair",
            "\(home)/claude-codex-pair",
        ]
        for p in knownPaths {
            if FileManager.default.fileExists(atPath: "\(p)/dist/monitor/daemon.js") {
                return p
            }
        }

        return nil
    }

    @discardableResult
    private static func runNodeScript(_ script: String) -> String? {
        guard let root = findProjectRoot() else {
            PairLog.error("HookManager: could not find project root with dist/monitor/daemon.js")
            return nil
        }

        let process = Process()
        let pipe = Pipe()

        // Find node
        let nodePaths = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
        ]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node"
        var allPaths = nodePaths
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted().reversed() {
                allPaths.append("\(nvmDir)/\(v)/bin/node")
            }
        }

        guard let nodePath = allPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            PairLog.error("HookManager: node not found")
            return nil
        }

        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["--input-type=module", "-e", script]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            PairLog.error("HookManager: \(error)")
            return nil
        }
    }
}
