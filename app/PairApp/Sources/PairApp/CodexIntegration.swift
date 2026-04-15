import Foundation

/// Codex subprocess management — spawning the Codex binary, building prompts,
/// parsing JSON responses, and related git/filesystem helpers.
/// Extracted from ClaudeMonitor for single-responsibility separation.
enum CodexIntegration {

    struct CodexResult {
        let response: String?
        let prompt: String
        let diffSummary: String?
    }

    // MARK: - Main entry point

    /// Build the Codex prompt, spawn the subprocess, parse the JSON response.
    /// All instance state that `ClaudeMonitor` formerly accessed is passed in explicitly.
    static func callCodex(screenText: String, cwd: String, claudeLooping: Bool = false,
                           repeatCount: Int = 0, codexTimeoutSec: Double = 30,
                           parsedScreen: ParsedScreen? = nil, conversationSummary: String = "") -> CodexResult {
        PairLog.info(">>> callCodex entered (cwd=\(cwd), screen=\(screenText.count) chars)")
        let lastLines = screenText.split(separator: "\n").suffix(20).joined(separator: "\n")
        let screen = parsedScreen ?? ScreenParser.parse(screenText)
        let diffSummary = gitDiffSummary(cwd: cwd)
        let diffDetail = gitDiffDetail(cwd: cwd)
        let ledger = CodexLedger(projectDir: cwd)

        let projectContext = ledger.readContext()
        let recentHistory = ledger.recentHistoryWithOutcomes()
        let strategy = ledger.readStrategy()

        var contextBlock = ""
        if let strat = strategy { contextBlock += "\n--- PROJECT STRATEGY ---\n\(String(strat.suffix(500)))\n" }
        if let ctx = projectContext { contextBlock += "\n--- PROJECT CONTEXT ---\n\(String(ctx.suffix(800)))\n" }
        if let history = recentHistory {
            contextBlock += "\n--- YOUR RECENT DECISIONS (with outcomes) ---\n\(history)\n"
            contextBlock += "Use this history to avoid repeating interventions that regressed or were neutral.\nDouble down on patterns that led to improvement.\n"
        }

        var loopWarning = ""
        if claudeLooping {
            loopWarning += "\n⚠️ POSSIBLE LOOP: Claude's screen looks similar across recent cycles. If stuck, tell Claude to STOP and try something fundamentally different. Suggest a concrete alternative.\n"
        }
        if repeatCount >= 2 {
            loopWarning += "\nNOTE: Your last \(repeatCount + 1) responses were identical. Check if the situation is actually progressing.\n"
        }
        let diffBlock = (diffDetail.map { !$0.isEmpty } ?? false) ? "\n--- GIT DIFF ---\n\(diffDetail!)\n" : ""

        // Build commit nudge when there's significant uncommitted work
        var commitBlock = ""
        if let uncommitted = ledger.hasUncommittedWork(), uncommitted.files >= 3 {
            commitBlock = """

            --- UNCOMMITTED WORK ---
            \(uncommitted.description) (\(uncommitted.files) files total)
            When Claude reaches a good checkpoint (feature works, tests pass, or logical unit complete), \
            tell it to commit its changes: "Good progress. Commit what you have so far with a descriptive \
            message, making sure all new and modified files are staged." \
            This keeps the git history clean and makes it easy to roll back if needed.

            """
        } else if let lastCommit = ledger.lastCommitSummary() {
            commitBlock = "\n--- LAST COMMIT ---\n\(lastCommit)\n"
        }

        // Build structured state block from ParsedScreen
        var stateBlock = "STATE: \(screen.state.rawValue)"
        if let tool = screen.lastToolUsed {
            let result = screen.lastToolResult.map { " → \(String($0.prefix(200)))" } ?? ""
            stateBlock += "\nLAST_TOOL: \(tool)\(result)"
        }
        if let msg = screen.claudeMessage {
            stateBlock += "\nCLAUDE_SAYS: \(String(msg.prefix(300)))"
        }
        if let q = screen.question {
            stateBlock += "\nQUESTION: \(q)"
        }
        if let options = screen.selectionOptions {
            let numbered = options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
            stateBlock += "\nOPTIONS:\n\(numbered)"
        }
        if let perm = screen.permissionDetail {
            stateBlock += "\nPERMISSION: \(perm)"
        }
        if screen.hasError, let errMsg = screen.errorMessage {
            stateBlock += "\nERROR: \(errMsg)"
        }
        if !screen.filesModified.isEmpty {
            stateBlock += "\nFILES: \(screen.filesModified.joined(separator: ", "))"
        }

        var conversationBlock = ""
        if !conversationSummary.isEmpty {
            conversationBlock = "\nRECENT CONVERSATION:\n\(conversationSummary)\n"
        }

        let prompt = """
        You are the human operator sitting at a terminal running Claude Code. \
        You see the terminal output below. Decide what to do — exactly like a \
        skilled developer would.

        \(stateBlock)
        \(conversationBlock)
        \(contextBlock)\(diffBlock)\(commitBlock)\(loopWarning)
        --- BEGIN TERMINAL OUTPUT ---
        \(lastLines)
        --- END TERMINAL OUTPUT ---

        Look at the terminal and respond with ONE of these:
        - WAIT — if Claude is still working or thinking, do nothing
        - APPROVE — if Claude finished successfully and nothing needs doing
        - SELECT: <number> — if you see a permission/selection menu (› markers, \
          numbered options like "1. Yes / 2. Yes, allow all / 3. No"), pick the \
          appropriate option number. For permissions, prefer the most permissive.
        - ANSWER: <text> — if Claude asked you a question, answer it naturally
        - REDIRECT: <instructions> — if Claude is going in the wrong direction
        - ESCALATE: <reason> — if something looks dangerous or you're unsure

        You may append extra lines after your decision:
        - LEARN: <observation> — A pattern worth remembering for future reviews.
        - IMPROVE: <suggestion> — A recurring problem that should be automated: a new skill, script, hook, or tool. Be specific about what to build.
        """

        guard let codexPath = findCodex() else {
            PairLog.error("Codex not found")
            return CodexResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }

        // codex is a Node.js script (#!/usr/bin/env node) — Swift's Process can't
        // exec .js files directly. Run through node explicitly.
        let nodePath = findNode()
        let resolvedCodex = resolveSymlink(codexPath)

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        if let node = nodePath {
            process.executableURL = URL(fileURLWithPath: node)
            process.arguments = [resolvedCodex, "exec", "--json", "-s", "read-only", prompt]
            PairLog.info("Codex: node \(resolvedCodex) [prompt \(prompt.count) chars]")
        } else {
            PairLog.error("Node.js not found — cannot run Codex")
            return CodexResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = stderr
        var env = ProcessInfo.processInfo.environment
        let nodeDir = (nodePath! as NSString).deletingLastPathComponent
        env["PATH"] = "\(nodeDir):\(env["PATH"] ?? "/usr/bin")"
        process.environment = env

        do {
            PairLog.info("Codex spawning: \(codexPath) exec --json -s read-only [prompt \(prompt.count) chars]")
            try process.run()
            PairLog.info("Codex PID \(process.processIdentifier) started")
            // Read pipes on background threads BEFORE waitUntilExit to avoid pipe deadlock.
            // If the process fills the pipe buffer (~64KB), it blocks waiting for reads,
            // while waitUntilExit blocks waiting for the process — classic deadlock.
            var rawData = Data()
            var errData = Data()
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global().async {
                rawData = stdout.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            readGroup.enter()
            DispatchQueue.global().async {
                errData = stderr.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }
            let timeoutSec = codexTimeoutSec
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    PairLog.error("Codex timed out after \(Int(timeoutSec))s - killing")
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec, execute: timeoutItem)
            process.waitUntilExit()
            timeoutItem.cancel()
            let readResult = readGroup.wait(timeout: .now() + timeoutSec + 5)
            if readResult == .timedOut {
                PairLog.error("Codex pipe read timed out — possible deadlock avoided")
            }
            let raw = String(data: rawData, encoding: .utf8) ?? ""
            let errOut = String(data: errData, encoding: .utf8) ?? ""
            if !errOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { PairLog.error("Codex stderr: \(errOut.prefix(500))") }
            if process.terminationStatus != 0 { PairLog.error("Codex exited with code \(process.terminationStatus), stdout=\(raw.count) bytes") }

            var text = ""
            var deltaText = ""
            for line in raw.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let eventType = j["type"] as? String else { continue }
                if eventType == "item.completed", let item = j["item"] as? [String: Any], let t = item["text"] as? String { text = t }
                else if eventType == "item.delta", let delta = j["delta"] as? [String: Any], let t = delta["text"] as? String { deltaText += t }
            }
            if text.isEmpty && !deltaText.isEmpty { text = deltaText }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return CodexResult(response: trimmed.isEmpty ? nil : trimmed, prompt: prompt, diffSummary: diffSummary)
        } catch {
            PairLog.error("Codex failed: \(error)")
            return CodexResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }
    }

    // MARK: - Learning extraction

    static func extractLearnings(from response: String, ledger: CodexLedger) {
        for line in response.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("LEARN:") {
                let learning = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !learning.isEmpty { PairLog.info("Codex learning: \(learning)"); ledger.appendLearning(learning) }
            } else if trimmed.uppercased().hasPrefix("IMPROVE:") {
                let suggestion = String(trimmed.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                if !suggestion.isEmpty { ledger.recordImprovement(suggestion) }
            }
        }
    }

    static func stripLearnings(_ response: String) -> String {
        response.split(separator: "\n")
            .filter {
                let upper = $0.trimmingCharacters(in: .whitespaces).uppercased()
                return !upper.hasPrefix("LEARN:") && !upper.hasPrefix("IMPROVE:")
            }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Git helpers

    static func gitDiffSummary(cwd: String) -> String? {
        CodexLedger.runGit(["diff", "--stat", "--no-color"], cwd: cwd)
    }

    static func gitDiffDetail(cwd: String) -> String? {
        guard let full = CodexLedger.runGit(["diff", "--no-color", "-U2"], cwd: cwd) else { return nil }
        return full.count > 2000 ? String(full.prefix(2000)) + "\n... (diff truncated)" : full
    }

    // MARK: - Binary discovery

    static func findCodex() -> String? {
        let paths = ["/usr/local/bin/codex", "/opt/homebrew/bin/codex"]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node"
        var all = paths
        if let vs = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in vs.sorted().reversed() { all.append("\(nvmDir)/\(v)/bin/codex") }
        }
        return all.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Find node binary — needed to run codex (which is a .js script).
    static func findNode() -> String? {
        let paths = ["/usr/local/bin/node", "/opt/homebrew/bin/node"]
        let nvmDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.nvm/versions/node"
        var all = paths
        if let vs = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for v in vs.sorted().reversed() { all.append("\(nvmDir)/\(v)/bin/node") }
        }
        return all.first(where: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Resolve symlinks to get the actual file path (codex → codex.js).
    static func resolveSymlink(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.resolvingSymlinksInPath().path
    }
}
