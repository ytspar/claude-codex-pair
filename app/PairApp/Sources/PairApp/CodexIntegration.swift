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
                           repeatCount: Int = 0, codexTimeoutSec: Double = 30) -> CodexResult {
        PairLog.info(">>> callCodex entered (cwd=\(cwd), screen=\(screenText.count) chars)")
        let lastLines = screenText.split(separator: "\n").suffix(40).joined(separator: "\n")
        let isSelection = ScreenDetection.isSelectionPrompt(screenText)
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

        let isPrompt = !isSelection && ScreenDetection.isInteractivePrompt(screenText)
        let prompt: String

        if isSelection {
            prompt = """
            You are acting as the human operator for Claude Code. Claude is showing \
            an interactive selection prompt. Here is the terminal output:

            --- BEGIN TERMINAL OUTPUT ---
            \(lastLines)
            --- END TERMINAL OUTPUT ---

            This is a selection prompt where options are chosen by number. \
            Pick the most permissive/thorough option. Usually: \
            - For permission prompts, choose "Yes, allow all" (usually option 2). \
            - For file creation/edit prompts, choose "Yes" (usually option 1). \
            - For trust prompts, choose the most permissive option. \
            Reply with ONLY the option number (e.g., "2"). Nothing else.
            """
        } else if isPrompt {
            prompt = """
            You are acting as the human operator for Claude Code. Claude is asking \
            for your input or confirmation. Here is the terminal output:

            --- BEGIN TERMINAL OUTPUT ---
            \(lastLines)
            --- END TERMINAL OUTPUT ---
            \(contextBlock)
            You ARE the user. Respond exactly as a knowledgeable developer would: \
            - For Y/n or yes/no prompts: reply "y" or "yes" to proceed (or "n" if the action looks wrong). \
            - For "Press Enter to continue": reply with just an empty line. \
            - For questions about what to do: answer directly and concisely. \
            - For trust/permission prompts: grant permission (the user trusts their tools). \
            - For "Are you sure?" / "Proceed?": confirm with "y" or "yes". \
            - For any other question: use your best judgment as the developer would. \
            Only output the exact text to type. No explanations. No quotes.
            """
        } else {
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

            prompt = """
            You are acting as the human operator for Claude Code. Claude has paused. \
            Here is the terminal output:

            --- BEGIN TERMINAL OUTPUT ---
            \(lastLines)
            --- END TERMINAL OUTPUT ---
            \(contextBlock)\(diffBlock)\(commitBlock)\(loopWarning)
            If Claude asked a question, answer it directly. Pick the most thorough option. \
            If Claude finished work, reply with just: APPROVE \
            Only output the text to type into Claude. \
            IMPORTANT: If Claude has made meaningful changes (new files, significant edits) \
            but hasn't committed yet, tell it to commit before continuing. Say something like: \
            "Commit your changes so far before moving on. Stage all relevant files including any new ones." \
            This ensures progress is saved incrementally. \
            If you notice a pattern worth remembering, add a note prefixed with "LEARN:" at the end.
            """
        }

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
            }
        }
    }

    static func stripLearnings(_ response: String) -> String {
        response.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("LEARN:") }
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
