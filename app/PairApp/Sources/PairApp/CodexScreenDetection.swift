import Foundation

/// Pure text-analysis functions for detecting what OpenAI Codex CLI is showing on screen.
/// Mirrors ScreenDetection's API but targets Codex's Ink-based TUI patterns.
///
/// Key differences from Claude Code (ScreenDetection):
/// - Prompt character: `›` (guillemet) not `❯` (arrow)
/// - Working indicator: `• Working (Ns • esc to interrupt)`
/// - Codex messages use `•` bullet prefix
/// - Status bar at bottom with model name and directory
/// - Selection uses `› 1.` prefix with numbered options
enum CodexScreenDetection {

    // MARK: - Prompt character

    /// The Codex CLI prompt marker (guillemet, U+203A).
    private static let promptChar: Character = "\u{203A}" // ›

    // MARK: - Public API

    /// Returns true when Codex is actively processing (not idle at a prompt).
    static func isStillWorking(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map(String.init)
        let tail = lines.suffix(15).joined(separator: "\n").lowercased()

        // Explicit working indicator from Codex
        if tail.contains("working (") || tail.contains("esc to interrupt") {
            return true
        }

        // Bullet-prefixed action lines — Codex streams progress with `•`
        let actionVerbs = [
            "reading", "writing", "checking", "looking", "searching",
            "running", "creating", "updating", "analyzing", "building",
            "installing", "fetching", "downloading", "compiling",
            "i'm ", "i am ", "let me "
        ]
        let bulletLines = lines.suffix(10).filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("•")
        }
        for line in bulletLines {
            let lower = line.lowercased()
            if actionVerbs.contains(where: { lower.contains($0) }) {
                return true
            }
        }

        return false
    }

    /// Returns true when a modal/overlay is displayed (e.g. help screen).
    static func isModalView(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("esc to close") || lower.contains("←/esc to close")
    }

    /// Returns true when Codex appears stuck — errors, failures, timeouts.
    static func isStuck(_ screenText: String) -> Bool {
        let tail = screenText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .suffix(20)
            .joined(separator: "\n")
            .lowercased()

        let stuckPatterns = [
            "error:", "failed to", "failed", "apiconnectionerror",
            "rate limit", "overloaded", "try again",
            "timed out", "timeout", "connection refused",
            "unexpected error", "something went wrong"
        ]
        return stuckPatterns.contains { tail.contains($0) }
    }

    /// Returns true when the `›` prompt line has no user-typed text
    /// (empty or only placeholder/hint text).
    static func isPromptEmpty(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Find the last line containing `›`
        guard let promptLine = lines.last(where: { $0.contains(String(promptChar)) }) else {
            // No prompt found — conservatively treat as empty
            return true
        }

        guard let range = promptLine.range(of: String(promptChar)) else { return true }
        let afterPrompt = promptLine[range.upperBound...]
            .trimmingCharacters(in: .whitespaces)

        // Empty prompt
        if afterPrompt.isEmpty { return true }

        // Placeholder text patterns (Codex shows greyed hints like "Improve documentation in @filename")
        let placeholderPatterns = [
            "improve documentation in @",
            "ask a question",
            "type a message",
            "enter a prompt"
        ]
        let lower = afterPrompt.lowercased()
        return placeholderPatterns.contains { lower.hasPrefix($0) }
    }

    /// Returns true when Codex is at its idle `›` prompt, ready for input.
    static func isAtCodexPrompt(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tail = lines.suffix(6)
        let hasGuillemet = tail.contains { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix(String(promptChar)) || s == String(promptChar)
        }

        guard hasGuillemet else { return false }

        // Must not be a selection prompt (which also uses ›)
        return !isSelectionPrompt(screenText)
    }

    /// Returns true when Codex shows an interrupted state.
    static func isInterruptedPrompt(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("interrupted")
            && (lower.contains("esc to interrupt") == false) // not mid-work
            && (isAtCodexPrompt(screenText) || lower.contains("aborted"))
    }

    /// Returns true when Codex is asking the user to accept or reject edits.
    static func isAcceptEditsPrompt(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("accept edits")
            || lower.contains("do you want to make this edit")
            || lower.contains("apply changes")
            || lower.contains("accept changes")
    }

    /// Returns true when Codex presents a numbered selection / trust dialog.
    static func isSelectionPrompt(_ screenText: String) -> Bool {
        if isAcceptEditsPrompt(screenText) { return false }

        let lines = screenText.split(separator: "\n").map(String.init)
        let lower = screenText.lowercased()

        // "Press enter to continue" or "enter to select" footer
        let hasSelectionFooter = lower.contains("press enter to continue")
            || lower.contains("enter to select")
            || lower.contains("press enter to select")

        // Numbered options with `›` prefix: `› 1. Yes, continue`
        let tail = lines.suffix(15)
        let numberedOptionLines = tail.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // `› 1.` or bare `1.` / `2.` / `3.`
            let hasGuillemet = t.hasPrefix(String(promptChar))
            let stripped = hasGuillemet
                ? t.dropFirst().trimmingCharacters(in: .whitespaces)
                : t
            return stripped.hasPrefix("1.") || stripped.hasPrefix("2.") || stripped.hasPrefix("3.")
        }

        // Trust dialog: "Do you trust" with numbered options
        let hasTrustQuestion = lower.contains("do you trust")

        // Selection keywords in numbered lines
        let selectionKeywords = ["yes", "no", "continue", "quit", "allow", "deny",
                                 "accept", "reject", "skip", "cancel", "trust"]
        let numberedWithKeywords = tail.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            let stripped = t.hasPrefix(String(promptChar))
                ? String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                : t
            guard stripped.hasPrefix("1.") || stripped.hasPrefix("2.") || stripped.hasPrefix("3.") else {
                return false
            }
            return selectionKeywords.contains { stripped.contains($0) }
        }

        return hasSelectionFooter
            || (numberedOptionLines.count >= 2 && (hasTrustQuestion || numberedWithKeywords.count >= 1))
            || numberedWithKeywords.count >= 2
    }

    /// Returns true when Codex needs any form of interactive user response —
    /// selection prompt, question, y/n confirmation, etc.
    static func isInteractivePrompt(_ screenText: String) -> Bool {
        if isSelectionPrompt(screenText) || isAcceptEditsPrompt(screenText) { return true }

        let lines = screenText.split(separator: "\n").map(String.init)
        let tailLower = lines.suffix(20).joined(separator: "\n").lowercased()

        if tailLower.contains("(y/n)") || tailLower.contains("[y/n]")
            || tailLower.contains("(yes/no)") || tailLower.contains("[yes/no]") { return true }
        if tailLower.contains("do you want to") { return true }
        if tailLower.contains("do you trust") { return true }
        if tailLower.contains("press enter") || tailLower.contains("press any key") { return true }
        if tailLower.contains("are you sure") || tailLower.contains("proceed?")
            || tailLower.contains("continue?") { return true }
        if tailLower.contains("would you like") { return true }

        // Check if Codex's output ends with a question above the prompt
        if isCodexAskingQuestion(lines) { return true }

        return false
    }

    /// Detect when Codex's output (above the `›` prompt) ends with a question
    /// directed at the user. Scans the last few lines before the prompt for `?`.
    static func isCodexAskingQuestion(_ lines: [String]) -> Bool {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }

        // Find the last `›` prompt line
        guard let promptIdx = trimmed.lastIndex(where: {
            $0.hasPrefix(String(promptChar)) || $0 == String(promptChar)
        }) else {
            return false
        }

        // Look at the last few non-empty lines before the prompt
        let above = trimmed[..<promptIdx].suffix(5).filter { !$0.isEmpty }
        guard let lastAbove = above.last else { return false }

        return lastAbove.hasSuffix("?")
    }
}
