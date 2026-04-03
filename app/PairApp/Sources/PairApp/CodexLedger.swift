import Foundation

/// Per-project learning ledger for Codex reviews.
/// Stores decision history and project context so Codex can learn
/// from past reviews and make better decisions over time.
///
/// Files are stored in `{projectDir}/.codex-pair/`:
/// - `ledger.jsonl` — append-only log of every review decision + outcome
/// - `context.md` — human-readable project context that Codex reads each review
class CodexLedger {
    private let projectDir: String
    private let ledgerDir: String

    init(projectDir: String) {
        self.projectDir = projectDir
        self.ledgerDir = "\(projectDir)/.codex-pair"
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
        let outcome: String?       // Filled in later: "continued", "looped", "completed"
    }

    /// Record a review decision to the ledger.
    func recordDecision(cycle: Int, decision: String, response: String,
                        screenTail: String, diffSummary: String? = nil,
                        wasLooping: Bool, durationMs: Int) {
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
            outcome: nil
        )
        guard let data = try? JSONEncoder().encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }

        let path = ledgerPath
        DispatchQueue.global(qos: .utility).async {
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
                handle.closeFile()
            } else {
                try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
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

    // MARK: - Recent history for prompt injection

    /// Get recent decision history formatted for inclusion in the Codex prompt.
    /// Returns the last N decisions as a compact summary.
    func recentHistory(limit: Int = 5) -> String? {
        guard let content = try? String(contentsOfFile: ledgerPath, encoding: .utf8) else {
            return nil
        }
        let lines = content.split(separator: "\n").suffix(limit)
        guard !lines.isEmpty else { return nil }

        let decoder = JSONDecoder()
        var summaries: [String] = []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(LedgerEntry.self, from: data) else { continue }
            let ago = timeAgo(entry.timestamp)
            let loopTag = entry.wasLooping ? " [LOOP]" : ""
            summaries.append("- \(ago): \(entry.decision)\(loopTag) — \(entry.response.prefix(80))")
        }
        guard !summaries.isEmpty else { return nil }
        return summaries.joined(separator: "\n")
    }

    // MARK: - Helpers

    private var ledgerPath: String { "\(ledgerDir)/ledger.jsonl" }
    private var contextPath: String { "\(ledgerDir)/context.md" }

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
}
