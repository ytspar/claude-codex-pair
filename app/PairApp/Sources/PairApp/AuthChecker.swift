import Foundation

/// Checks authentication status for Claude Code and Codex CLI.
struct AuthChecker {

    struct AuthStatus {
        var claudeInstalled: Bool = false
        var claudeAuthenticated: Bool = false
        var claudeVersion: String = ""
        var codexInstalled: Bool = false
        var codexAuthenticated: Bool = false
        var codexVersion: String = ""
        var codexAuthMethod: String = "" // "subscription" or "api_key"

        var allReady: Bool { claudeInstalled && claudeAuthenticated && codexInstalled && codexAuthenticated }

        var issues: [String] {
            var problems: [String] = []
            if !claudeInstalled { problems.append("Claude Code not found. Install: npm install -g @anthropic-ai/claude-code") }
            else if !claudeAuthenticated { problems.append("Claude Code not authenticated. Run: claude login") }
            if !codexInstalled { problems.append("Codex CLI not found. Install: npm install -g @openai/codex") }
            else if !codexAuthenticated { problems.append("Codex not authenticated. Run: codex auth") }
            return problems
        }
    }

    /// Check both CLIs. Runs synchronously (call from background thread).
    static func check() -> AuthStatus {
        var status = AuthStatus()

        // Check Claude Code
        if let version = runCommand("claude", args: ["--version"]) {
            status.claudeInstalled = true
            status.claudeVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
            // Claude is authenticated if `claude --version` works and there's a session
            // Check for auth by looking for session files
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let sessionsDir = "\(home)/.claude/sessions"
            status.claudeAuthenticated = FileManager.default.fileExists(atPath: sessionsDir)
        }

        // Check Codex CLI
        if let version = runCommand("codex", args: ["--version"]) {
            status.codexInstalled = true
            status.codexVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)

            // Check auth: try `codex auth status` or check for API key / subscription
            let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            if apiKey != nil && !apiKey!.isEmpty {
                status.codexAuthenticated = true
                status.codexAuthMethod = "api_key"
            } else {
                // Subscription auth  - check if codex can reach the API
                // `codex exec` with a trivial prompt will fail fast if not authed
                if let authCheck = runCommand("codex", args: ["auth", "status"]) {
                    status.codexAuthenticated = authCheck.lowercased().contains("authenticated")
                        || authCheck.lowercased().contains("logged in")
                        || !authCheck.lowercased().contains("not")
                    status.codexAuthMethod = "subscription"
                } else {
                    // codex auth status might not exist  - try a quick exec
                    if let execCheck = runCommand("codex", args: ["exec", "-s", "read-only", "say ok"], timeout: 15) {
                        status.codexAuthenticated = !execCheck.lowercased().contains("unauthorized")
                            && !execCheck.lowercased().contains("authentication")
                            && !execCheck.isEmpty
                        status.codexAuthMethod = "subscription"
                    }
                }
            }
        }

        PairLog.info("Auth check: claude=\(status.claudeInstalled)/\(status.claudeAuthenticated) codex=\(status.codexInstalled)/\(status.codexAuthenticated) (\(status.codexAuthMethod))")
        return status
    }

    private static func runCommand(_ command: String, args: [String], timeout: Int = 10) -> String? {
        let process = Process()
        let pipe = Pipe()

        // Find the command in common paths
        // Search common binary locations  - don't hardcode specific versions
        var paths = [
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
        ]
        // Dynamically find NVM node bin if present
        let nvmDir = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for version in versions.sorted().reversed() {
                paths.append("\(nvmDir)/\(version)/bin/\(command)")
            }
        }

        let fullPath = paths.first { FileManager.default.fileExists(atPath: $0) }
            ?? (runWhich(command) ?? "/usr/bin/env")

        if fullPath == "/usr/bin/env" {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
        } else {
            process.executableURL = URL(fileURLWithPath: fullPath)
            process.arguments = args
        }

        process.standardOutput = pipe
        process.standardError = pipe
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            let timer = DispatchSource.makeTimerSource()
            timer.schedule(deadline: .now() + .seconds(timeout))
            timer.setEventHandler { process.terminate() }
            timer.resume()
            process.waitUntilExit()
            timer.cancel()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func runWhich(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }
}
