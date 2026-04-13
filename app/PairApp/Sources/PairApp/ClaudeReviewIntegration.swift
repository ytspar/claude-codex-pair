import Foundation

/// Claude CLI subprocess management for "Codex leads" mode — where Claude acts as
/// the reviewer/operator for the Codex CLI session.
/// Mirrors CodexIntegration but spawns `claude -p` (print mode) instead of `codex exec`.
enum ClaudeReviewIntegration {

    struct ReviewResult {
        let response: String?
        let prompt: String
        let diffSummary: String?
    }

    // MARK: - Main entry point

    /// Build the review prompt, spawn `claude -p`, read the response.
    /// All instance state that `ClaudeMonitor` formerly accessed is passed in explicitly.
    static func callClaude(parsedScreen: ParsedScreen? = nil, screenText: String, cwd: String,
                           conversationSummary: String = "", claudeLooping: Bool = false,
                           repeatCount: Int = 0, timeoutSec: Double = 30) -> ReviewResult {
        PairLog.info(">>> callClaude (review) entered (cwd=\(cwd), screen=\(screenText.count) chars)")
        let lastLines = screenText.split(separator: "\n").suffix(20).joined(separator: "\n")
        let screen = parsedScreen ?? ScreenParser.parse(screenText)
        let diffSummary = CodexIntegration.gitDiffSummary(cwd: cwd)
        let diffDetail = CodexIntegration.gitDiffDetail(cwd: cwd)
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
            loopWarning += "\n⚠️ POSSIBLE LOOP: Codex's screen looks similar across recent cycles. If stuck, tell Codex to STOP and try something fundamentally different. Suggest a concrete alternative.\n"
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
            When Codex reaches a good checkpoint (feature works, tests pass, or logical unit complete), \
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
            stateBlock += "\nCODEX_SAYS: \(String(msg.prefix(300)))"
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

        var stateHints = ""
        if screen.state == .selectionMenu || screen.state == .permissionPrompt {
            stateHints += """
            \nThis is a selection/permission prompt. Respond with SELECT: <number>.
            For permission prompts, prefer the most permissive option (usually 2 for "Yes, allow all").
            """
        }
        if screen.state == .askingQuestion {
            stateHints += "\nCodex is asking you a question. Respond with ANSWER: <your response>."
        }

        let prompt = """
        You are the human operator for Codex CLI. Analyze the current state and decide what to do.

        \(stateBlock)
        \(conversationBlock)
        \(contextBlock)\(diffBlock)\(commitBlock)\(loopWarning)
        --- BEGIN TERMINAL OUTPUT ---
        \(lastLines)
        --- END TERMINAL OUTPUT ---

        Respond with exactly ONE line in this format:
        - APPROVE — Work is correct, let Codex continue
        - WAIT — Codex is still working, do not intervene
        - ANSWER: <text> — Answer Codex's question or provide input
        - SELECT: <number> — Choose option from the menu (for permissions: pick most permissive)
        - REDIRECT: <instructions> — Codex is off track, give new direction
        - ESCALATE: <reason> — Risky/unclear situation, flag for human
        \(stateHints)

        You may also append LEARN: notes on a separate line after your decision.
        If you notice a pattern worth remembering, add a note prefixed with "LEARN:" at the end.
        """

        guard let claudePath = findClaude() else {
            PairLog.error("Claude CLI not found")
            return ReviewResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["-p", prompt]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = stderr

        // Ensure claude binary's directory is on PATH
        var env = ProcessInfo.processInfo.environment
        let claudeDir = (claudePath as NSString).deletingLastPathComponent
        env["PATH"] = "\(claudeDir):\(env["PATH"] ?? "/usr/bin")"
        process.environment = env

        PairLog.info("Claude spawning: \(claudePath) -p [prompt \(prompt.count) chars]")

        do {
            try process.run()
            PairLog.info("Claude PID \(process.processIdentifier) started")

            // Read pipes on background threads BEFORE waitUntilExit to avoid pipe deadlock.
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

            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    PairLog.error("Claude timed out after \(Int(timeoutSec))s - killing")
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
                PairLog.error("Claude pipe read timed out — possible deadlock avoided")
            }

            let raw = String(data: rawData, encoding: .utf8) ?? ""
            let errOut = String(data: errData, encoding: .utf8) ?? ""
            if !errOut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                PairLog.error("Claude stderr: \(errOut.prefix(500))")
            }
            if process.terminationStatus != 0 {
                PairLog.error("Claude exited with code \(process.terminationStatus), stdout=\(raw.count) bytes")
            }

            // claude -p returns plain text (not JSON), so just trim and return
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return ReviewResult(response: trimmed.isEmpty ? nil : trimmed, prompt: prompt, diffSummary: diffSummary)
        } catch {
            PairLog.error("Claude failed: \(error)")
            return ReviewResult(response: nil, prompt: prompt, diffSummary: diffSummary)
        }
    }

    // MARK: - Learning extraction (delegates to CodexIntegration)

    static func extractLearnings(from response: String, ledger: CodexLedger) {
        CodexIntegration.extractLearnings(from: response, ledger: ledger)
    }

    static func stripLearnings(_ response: String) -> String {
        CodexIntegration.stripLearnings(response)
    }

    // MARK: - Binary discovery

    static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "/usr/local/bin/claude",
            "/usr/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/bin/claude",
        ]
        if let found = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return found
        }
        // Fall back to `which claude`
        return whichClaude()
    }

    /// Use `which` to locate the claude binary on PATH.
    private static func whichClaude() -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["claude"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}
