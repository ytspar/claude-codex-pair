import Foundation

/// Per-project learning ledger for Codex reviews.
/// Stores decision history, progress signals, and project strategy so Codex can learn
/// from past reviews and make better decisions over time.
///
/// Files are stored in `{projectDir}/.codex-pair/`:
/// - `ledger.jsonl` — append-only log of every review decision + outcome
/// - `context.md` — human-readable project context that Codex reads each review
/// - `strategy.md` — persistent per-project strategy memory (what works/doesn't)
class CodexLedger {
    private static let fileLock = NSLock()
    private let projectDir: String
    private let ledgerDir: String

    init(projectDir: String) {
        self.projectDir = projectDir
        self.ledgerDir = "\(projectDir)/.codex-pair"
    }

    // MARK: - Progress Signals

    /// Scalar metrics captured at a point in time — the "val_bpb" equivalent.
    struct ProgressSignal: Codable {
        let commitCount: Int        // Total commits on current branch
        let uncommittedFiles: Int   // Files with unstaged changes
        let insertions: Int         // Lines added (from diff --stat)
        let deletions: Int          // Lines removed (from diff --stat)
    }

    /// Capture current progress signals from git state.
    func captureProgress() -> ProgressSignal {
        let commitCount = runGitInt(["rev-list", "--count", "HEAD"])
        let diffStat = Self.runGit(["diff", "--stat", "--no-color"], cwd: projectDir) ?? ""
        let uncommitted = Self.runGit(["diff", "--name-only"], cwd: projectDir)?
            .split(separator: "\n").count ?? 0
        // Also count untracked files — Claude may create new files without staging them
        let untracked = Self.runGit(["ls-files", "--others", "--exclude-standard"], cwd: projectDir)?
            .split(separator: "\n").count ?? 0

        var insertions = 0
        var deletions = 0
        if let summaryLine = diffStat.split(separator: "\n").last.map(String.init) {
            if let match = summaryLine.range(of: #"(\d+) insertion"#, options: .regularExpression) {
                let numStr = summaryLine[match].split(separator: " ").first ?? ""
                insertions = Int(numStr) ?? 0
            }
            if let match = summaryLine.range(of: #"(\d+) deletion"#, options: .regularExpression) {
                let numStr = summaryLine[match].split(separator: " ").first ?? ""
                deletions = Int(numStr) ?? 0
            }
        }

        return ProgressSignal(
            commitCount: commitCount,
            uncommittedFiles: uncommitted + untracked,
            insertions: insertions,
            deletions: deletions
        )
    }

    /// Check if there are significant uncommitted changes that should be committed.
    func hasUncommittedWork() -> (files: Int, description: String)? {
        let staged = Self.runGit(["diff", "--cached", "--name-only"], cwd: projectDir)?
            .split(separator: "\n").count ?? 0
        let modified = Self.runGit(["diff", "--name-only"], cwd: projectDir)?
            .split(separator: "\n").count ?? 0
        let untracked = Self.runGit(["ls-files", "--others", "--exclude-standard"], cwd: projectDir)?
            .split(separator: "\n").count ?? 0
        let total = staged + modified + untracked
        guard total > 0 else { return nil }

        var parts: [String] = []
        if modified > 0 { parts.append("\(modified) modified") }
        if untracked > 0 { parts.append("\(untracked) new") }
        if staged > 0 { parts.append("\(staged) staged") }
        return (total, parts.joined(separator: ", "))
    }

    /// Get the last commit message (for Codex to verify completeness).
    func lastCommitSummary() -> String? {
        Self.runGit(["log", "--oneline", "-1"], cwd: projectDir)
    }

    // MARK: - Ledger entries

    struct LedgerEntry: Codable {
        let timestamp: String
        let cycle: Int
        let decision: String       // APPROVE, FEEDBACK, SELECT, etc.
        let response: String       // What Codex said
        let screenTail: String     // Last ~10 lines of screen at review time
        let diffSummary: String?   // git diff --stat at review time
        let wasLooping: Bool
        let durationMs: Int
        let outcome: String?       // "improved", "regressed", "neutral", "pending"
        let progressBefore: ProgressSignal?
        let progressAfter: ProgressSignal?
    }

    /// Record a review decision to the ledger with progress tracking.
    func recordDecision(cycle: Int, decision: String, response: String,
                        screenTail: String, diffSummary: String? = nil,
                        wasLooping: Bool, durationMs: Int,
                        progressBefore: ProgressSignal? = nil) {
        ensureDir()
        let entry = LedgerEntry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            cycle: cycle,
            decision: decision,
            response: response,
            screenTail: String(screenTail.prefix(500)),
            diffSummary: diffSummary,
            wasLooping: wasLooping,
            durationMs: durationMs,
            outcome: "pending",
            progressBefore: progressBefore,
            progressAfter: nil
        )
        appendEntry(entry)
    }

    /// Update the most recent ledger entry with outcome and post-intervention progress.
    func recordOutcome(outcome: String, progressAfter: ProgressSignal) {
        Self.fileLock.withLock {
            guard let content = try? String(contentsOfFile: ledgerPath, encoding: .utf8) else { return }
            var lines = content.split(separator: "\n").map(String.init)
            guard let lastIdx = lines.indices.last else { return }

            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            guard let data = lines[lastIdx].data(using: .utf8),
                  let entry = try? decoder.decode(LedgerEntry.self, from: data) else { return }

            // Re-encode with outcome filled in
            let updated = LedgerEntry(
                timestamp: entry.timestamp,
                cycle: entry.cycle,
                decision: entry.decision,
                response: entry.response,
                screenTail: entry.screenTail,
                diffSummary: entry.diffSummary,
                wasLooping: entry.wasLooping,
                durationMs: entry.durationMs,
                outcome: outcome,
                progressBefore: entry.progressBefore,
                progressAfter: progressAfter
            )
            guard let updatedData = try? encoder.encode(updated),
                  let updatedLine = String(data: updatedData, encoding: .utf8) else { return }

            lines[lastIdx] = updatedLine
            try? lines.joined(separator: "\n").appending("\n")
                .write(toFile: ledgerPath, atomically: true, encoding: .utf8)
        }
    }

    /// Compute outcome by comparing before/after progress signals.
    /// Multiple signals checked in priority order — commits are strongest, but
    /// file activity also counts since Claude often works before committing.
    static func computeOutcome(before: ProgressSignal?, after: ProgressSignal) -> String {
        guard let before = before else { return "neutral" }
        // New commits = strongest signal of progress
        if after.commitCount > before.commitCount { return "improved" }
        // Uncommitted files decreased = Claude committed existing work (progress)
        if before.uncommittedFiles > 0 && after.uncommittedFiles < before.uncommittedFiles { return "improved" }
        // New uncommitted files = Claude is actively writing code (progress)
        if after.uncommittedFiles > before.uncommittedFiles { return "improved" }
        // Significant code change in the diff (even without commit)
        let totalBefore = before.insertions + before.deletions
        let totalAfter = after.insertions + after.deletions
        if abs(totalAfter - totalBefore) > 10 { return "improved" }
        // No meaningful change detected
        return "neutral"
    }

    // MARK: - Project context

    /// Read the project context file. Returns nil if it doesn't exist.
    func readContext() -> String? {
        let path = contextPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Append a learning to the project context file.
    func appendLearning(_ text: String) {
        ensureDir()
        let entry = "\n## \(dateString())\n\(text)\n"
        let path = contextPath
        DispatchQueue.global(qos: .utility).async {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data(entry.utf8))
                handle.closeFile()
            } else {
                let header = "# Codex Project Context\n\nLearnings from reviewing Claude's work in this project.\n"
                try? (header + entry).write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Recent history with outcomes for prompt injection

    /// Get recent decision history with outcomes, formatted for Codex prompt.
    /// This is the Reflexion-style feedback loop — Codex sees what it tried and whether it helped.
    func recentHistoryWithOutcomes(limit: Int = 5) -> String? {
        Self.fileLock.withLock {
            guard let content = try? String(contentsOfFile: ledgerPath, encoding: .utf8) else {
                return nil
            }
            let lines = content.split(separator: "\n").suffix(limit)
            guard !lines.isEmpty else { return nil }

            let decoder = JSONDecoder()
            var summaries: [String] = []
            var outcomes: [String: Int] = ["improved": 0, "regressed": 0, "neutral": 0]

            for line in lines {
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(LedgerEntry.self, from: data) else { continue }
                let ago = timeAgo(entry.timestamp)
                let loopTag = entry.wasLooping ? " [LOOP]" : ""
                let outcomeTag: String
                switch entry.outcome {
                case "improved": outcomeTag = " ✓improved"
                case "regressed": outcomeTag = " ✗regressed"
                case "neutral": outcomeTag = " ~neutral"
                default: outcomeTag = ""
                }
                if let o = entry.outcome { outcomes[o, default: 0] += 1 }
                summaries.append("- \(ago): \(entry.decision)\(loopTag)\(outcomeTag) — \(entry.response.prefix(80))")
            }
            guard !summaries.isEmpty else { return nil }

            // Add effectiveness summary
            let total = outcomes.values.reduce(0, +)
            let improved = outcomes["improved"] ?? 0
            let regressed = outcomes["regressed"] ?? 0
            if total > 0 {
                summaries.insert("Effectiveness: \(improved)/\(total) improved, \(regressed)/\(total) regressed", at: 0)
            }

            return summaries.joined(separator: "\n")
        }
    }

    /// Legacy method for backward compatibility
    func recentHistory(limit: Int = 5) -> String? {
        return recentHistoryWithOutcomes(limit: limit)
    }

    // MARK: - Strategy memory (per-project persistent "what works")

    /// Read the strategy file. Returns nil if it doesn't exist.
    func readStrategy() -> String? {
        let path = strategyPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Update the strategy file based on accumulated ledger data.
    /// Called periodically (e.g., every 10 cycles) to synthesize patterns.
    func updateStrategy() {
        guard let content = try? String(contentsOfFile: ledgerPath, encoding: .utf8) else { return }
        let lines = content.split(separator: "\n")
        guard lines.count >= 5 else { return }  // Need enough data

        let decoder = JSONDecoder()
        var entries: [LedgerEntry] = []
        for line in lines.suffix(50) {  // Last 50 entries
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(LedgerEntry.self, from: data) else { continue }
            entries.append(entry)
        }
        guard !entries.isEmpty else { return }

        // Compute stats
        let total = entries.count
        let improved = entries.filter { $0.outcome == "improved" }.count
        let regressed = entries.filter { $0.outcome == "regressed" }.count
        let looping = entries.filter { $0.wasLooping }.count
        let avgDuration = entries.map(\.durationMs).reduce(0, +) / max(total, 1)

        // Identify patterns that led to improvement vs regression
        let improvedResponses = entries.filter { $0.outcome == "improved" }.map { $0.response.prefix(100) }
        let regressedResponses = entries.filter { $0.outcome == "regressed" }.map { $0.response.prefix(100) }

        ensureDir()
        var strategy = "# Codex Strategy for \(projectDir.split(separator: "/").last ?? "project")\n"
        strategy += "Updated: \(dateString())\n\n"
        strategy += "## Effectiveness\n"
        strategy += "- Total interventions: \(total)\n"
        strategy += "- Improved: \(improved) (\(total > 0 ? improved * 100 / total : 0)%)\n"
        strategy += "- Regressed: \(regressed) (\(total > 0 ? regressed * 100 / total : 0)%)\n"
        strategy += "- Loop detections: \(looping)\n"
        strategy += "- Avg review duration: \(avgDuration)ms\n\n"

        if !improvedResponses.isEmpty {
            strategy += "## What Worked\n"
            for r in improvedResponses.suffix(5) {
                strategy += "- \(r)\n"
            }
            strategy += "\n"
        }
        if !regressedResponses.isEmpty {
            strategy += "## What Didn't Work (avoid repeating)\n"
            for r in regressedResponses.suffix(5) {
                strategy += "- \(r)\n"
            }
            strategy += "\n"
        }

        let pending = pendingImprovements()
        if !pending.isEmpty {
            strategy += "## Pending Improvements (auto-queued as tasks)\n"
            for entry in pending.suffix(10) {
                strategy += "- \(entry.suggestion)\n"
            }
            strategy += "\n"
        }

        if let unmatched = readUnmatchedPatterns() {
            strategy += "\n\(unmatched)\n"
        }

        try? strategy.write(toFile: strategyPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Unmatched prompt patterns

    /// Record a screen pattern that wasn't properly categorized by the detection heuristics.
    /// These accumulate so strategy updates can surface them for heuristic improvement.
    func recordUnmatchedPrompt(screenTail: String, expectedCategory: String, codexResponse: String) {
        ensureDir()
        let entry: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "screenTail": String(screenTail.prefix(400)),
            "expectedCategory": expectedCategory,
            "codexResponse": String(codexResponse.prefix(200))
        ]
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let path = unmatchedPath
        if FileManager.default.fileExists(atPath: path) {
            guard let fh = FileHandle(forWritingAtPath: path) else { return }
            fh.seekToEndOfFile(); fh.write((line + "\n").data(using: .utf8)!); fh.closeFile()
        } else {
            try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        // Keep only last 50 entries
        if let content = try? String(contentsOfFile: path, encoding: .utf8) {
            let lines = content.split(separator: "\n")
            if lines.count > 50 {
                try? lines.suffix(50).joined(separator: "\n").appending("\n")
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Read recent unmatched patterns for strategy updates.
    func readUnmatchedPatterns() -> String? {
        guard let content = try? String(contentsOfFile: unmatchedPath, encoding: .utf8),
              !content.isEmpty else { return nil }
        let decoder = JSONDecoder()
        var summary = "## Unmatched Prompt Patterns (improve detection heuristics)\n"
        for line in content.split(separator: "\n").suffix(10) {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode([String: String].self, from: data) else { continue }
            let screen = entry["screenTail"] ?? ""
            let expected = entry["expectedCategory"] ?? ""
            let response = entry["codexResponse"] ?? ""
            summary += "- Expected: \(expected), Got response: \(response)\n  Screen: \(screen.prefix(120))\n"
        }
        return summary
    }

    // MARK: - Improvement suggestions (self-improving loop)

    struct ImprovementEntry: Codable {
        let timestamp: String
        let suggestion: String
        let queued: Bool
    }

    /// Record a tooling/skill improvement suggestion from the reviewer.
    func recordImprovement(_ suggestion: String) {
        ensureDir()
        let entry = ImprovementEntry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            suggestion: suggestion,
            queued: false
        )
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        let path = improvementsPath
        DispatchQueue.global(qos: .utility).async {
            Self.fileLock.withLock {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(Data((line + "\n").utf8))
                    handle.closeFile()
                } else {
                    try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        PairLog.info("Improvement recorded: \(suggestion)")
    }

    /// Read pending (un-queued) improvement suggestions.
    func pendingImprovements() -> [ImprovementEntry] {
        guard let content = try? String(contentsOfFile: improvementsPath, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return content.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(ImprovementEntry.self, from: data),
                  !entry.queued else { return nil }
            return entry
        }
    }

    /// Mark all pending improvements as queued (so they don't get re-queued).
    func markImprovementsQueued() {
        Self.fileLock.withLock {
            guard let content = try? String(contentsOfFile: improvementsPath, encoding: .utf8) else { return }
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let lines = content.split(separator: "\n").map { line -> String in
                guard let data = line.data(using: .utf8),
                      var entry = try? decoder.decode(ImprovementEntry.self, from: data) else {
                    return String(line)
                }
                if !entry.queued {
                    entry = ImprovementEntry(timestamp: entry.timestamp, suggestion: entry.suggestion, queued: true)
                    if let updated = try? encoder.encode(entry),
                       let str = String(data: updated, encoding: .utf8) {
                        return str
                    }
                }
                return String(line)
            }
            try? lines.joined(separator: "\n").appending("\n")
                .write(toFile: improvementsPath, atomically: true, encoding: .utf8)
        }
    }

    /// Auto-queue ONE pending improvement into the task queue.
    /// Only queues if the task queue has no pending IMPROVE tasks already.
    /// Called periodically alongside strategy updates.
    func queuePendingImprovements() {
        let pending = pendingImprovements()
        guard let next = pending.first else { return }

        // Don't pile up — only queue if no IMPROVE tasks are already pending
        let hasExistingImprove = TaskQueue.shared.items.contains {
            ($0.status == .pending || $0.status == .active) && $0.prompt.hasPrefix("IMPROVE:")
        }
        guard !hasExistingImprove else { return }

        let prompt = "IMPROVE: \(next.suggestion)\n\nThe reviewer flagged this as a recurring pattern that could be automated or improved. Investigate and implement the improvement — this could be a new Claude Code skill (.claude/skills/), a CLI script (scripts/), a pre-commit hook, a CLAUDE.md rule, or a code change. Commit your changes when done."
        DispatchQueue.main.async {
            TaskQueue.shared.addTask(prompt: prompt)
        }
        // Only mark this one as queued
        markSingleImprovementQueued(timestamp: next.timestamp)
        PairLog.info("Queued 1 improvement task (remaining: \(pending.count - 1))")
    }

    /// Mark a single improvement as queued by timestamp.
    private func markSingleImprovementQueued(timestamp: String) {
        Self.fileLock.withLock {
            guard let content = try? String(contentsOfFile: improvementsPath, encoding: .utf8) else { return }
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            var found = false
            let lines = content.split(separator: "\n").map { line -> String in
                guard !found,
                      let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(ImprovementEntry.self, from: data),
                      entry.timestamp == timestamp, !entry.queued else {
                    return String(line)
                }
                found = true
                let updated = ImprovementEntry(timestamp: entry.timestamp, suggestion: entry.suggestion, queued: true)
                if let data = try? encoder.encode(updated), let str = String(data: data, encoding: .utf8) {
                    return str
                }
                return String(line)
            }
            try? lines.joined(separator: "\n").appending("\n")
                .write(toFile: improvementsPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private var ledgerPath: String { "\(ledgerDir)/ledger.jsonl" }
    private var contextPath: String { "\(ledgerDir)/context.md" }
    private var strategyPath: String { "\(ledgerDir)/strategy.md" }
    private var unmatchedPath: String { "\(ledgerDir)/unmatched.jsonl" }
    private var improvementsPath: String { "\(ledgerDir)/improvements.jsonl" }

    private func ensureDir() {
        try? FileManager.default.createDirectory(
            atPath: ledgerDir, withIntermediateDirectories: true)
    }

    private func dateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    private func timeAgo(_ isoString: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: isoString) else { return isoString }
        let s = -date.timeIntervalSinceNow
        if s < 60 { return "\(Int(s))s ago" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        return "\(Int(s / 3600))h ago"
    }

    private func appendEntry(_ entry: LedgerEntry) {
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }

        let path = ledgerPath
        DispatchQueue.global(qos: .utility).async {
            Self.fileLock.withLock {
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    handle.write(Data((line + "\n").utf8))
                    handle.closeFile()
                } else {
                    try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
                // Rotate if file exceeds 5MB: keep only the last 1000 lines
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? UInt64, size > 5_000_000 {
                    if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                        let lines = content.split(separator: "\n").suffix(1000)
                        try? lines.joined(separator: "\n").appending("\n")
                            .write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
    }

    private func runGitInt(_ args: [String]) -> Int {
        guard let output = Self.runGit(args, cwd: projectDir) else { return 0 }
        return Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func runGit(_ args: [String], cwd: String) -> String? {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            // Read pipe on background thread BEFORE waitUntilExit to avoid
            // pipe deadlock (git blocks if 64KB buffer fills while we wait).
            var data = Data()
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                data = stdout.fileHandleForReading.readDataToEndOfFile()
                sem.signal()
            }
            process.waitUntilExit()
            _ = sem.wait(timeout: .now() + 10)
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return output?.isEmpty == true ? nil : output
        } catch {
            return nil
        }
    }
}
