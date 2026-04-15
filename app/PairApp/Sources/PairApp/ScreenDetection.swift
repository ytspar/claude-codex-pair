import Foundation

/// Pure text-analysis functions for detecting what Claude Code is showing on screen.
/// These are stateless helpers extracted from ClaudeMonitor — no dependencies on
/// monitor state, sessions, or any other runtime objects.
enum ScreenDetection {

    static func isStillWorking(_ screenText: String) -> Bool {
        let tail = screenText.split(separator: "\n").suffix(15).joined(separator: "\n").lowercased()
        let patterns = ["agent still running", "still working", "waiting for", "let me wait", "let it finish", "wait for it to complete", "in progress", "tasks (", "churned for", "running agent"]
        let hasOpenTask = tail.contains("open)") || tail.contains("□") || tail.contains("⠋") || tail.contains("⠙") || tail.contains("⠸")
        let hasWaitLanguage = patterns.contains { tail.contains($0) }
        return hasWaitLanguage && (hasOpenTask || tail.contains("still") || tail.contains("wait"))
    }

    static func isModalView(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("esc to close") || lower.contains("←/esc to close")
    }

    static func isStuck(_ screenText: String) -> Bool {
        let tail = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.suffix(20).joined(separator: "\n").lowercased()
        return tail.contains("interrupted") || tail.contains("error:") || tail.contains("failed to")
            || tail.contains("apiconnectionerror") || tail.contains("api_error") || tail.contains("api error")
            || tail.contains("internal server error") || tail.contains("\"type\":\"error\"")
            || tail.contains("what should claude do") || tail.contains("rate limit")
            || tail.contains("overloaded") || tail.contains("try again")
            || tail.contains("529") || tail.contains("500")
    }

    /// Detect transient API errors that should be auto-retried (not sent to reviewer).
    static func isTransientError(_ screenText: String) -> Bool {
        let tail = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.suffix(15).joined(separator: "\n").lowercased()
        return tail.contains("internal server error") || tail.contains("api_error")
            || tail.contains("overloaded") || tail.contains("rate limit")
            || tail.contains("529") || (tail.contains("500") && tail.contains("error"))
            || tail.contains("apiconnectionerror") || tail.contains("connection error")
    }

    static func isPromptEmpty(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if lines.contains(where: { $0.contains("[Pasted text") }) { return false }
        guard let lastNonEmpty = lines.last(where: { !$0.isEmpty }) else { return true }
        // Strip cursor/block characters for clean comparison
        let stripped = String(lastNonEmpty.unicodeScalars.filter { ($0.value >= 0x20 && $0.value < 0x2500) || $0.value >= 0x25A0 || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
        if let range = stripped.range(of: "❯") {
            return stripped[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        }
        if stripped.hasSuffix(">") || stripped == ">" || stripped.hasSuffix("> ") { return true }
        // Also check original in case ❯ is in the raw text
        if let range = lastNonEmpty.range(of: "❯") {
            return lastNonEmpty[range.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty
        }
        if lastNonEmpty.hasSuffix(">") || lastNonEmpty.hasSuffix("> ") { return true }
        return true
    }

    static func isAtClaudePrompt(_ screenText: String) -> Bool {
        let lines = screenText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Scan the last several lines — Claude Code renders separator bars (─────)
        // below the ❯ prompt line, so the last non-empty line is often a rule, not the prompt.
        let tail = lines.suffix(6)
        let isClaudePrompt = tail.contains { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            return s.hasPrefix("❯") || s == "❯"
        }

        // Bare angle bracket (>) check — also scan tail lines
        let isBareAngle = !isClaudePrompt && tail.contains { line in
            let s = String(line.unicodeScalars.filter { ($0.value >= 0x20 && $0.value < 0x2500) || $0.value >= 0x25A0 || $0 == " " })
                .trimmingCharacters(in: .whitespaces)
            return s == ">" || s.hasSuffix("> ")
        }
        if isBareAngle {
            let lower = screenText.lowercased()
            if !(lower.contains("claude") || lower.contains("tool use") || lower.contains("compact") || lower.contains("autocompact") || lower.contains("cost:") || lower.contains("tokens") || lower.contains("opus") || lower.contains("sonnet")) { return false }
        }
        return (isClaudePrompt || isBareAngle) && !isSelectionPrompt(screenText)
    }

    static func isInterruptedPrompt(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("interrupted") && lower.contains("what should claude do")
    }

    static func isAcceptEditsPrompt(_ screenText: String) -> Bool {
        let lower = screenText.lowercased()
        return lower.contains("accept edits on")
            || lower.contains("shift+tab to cycle") || lower.contains("shift-tab to cycle")
            || lower.contains("do you want to make this edit")
            || lower.contains("allow claude to edit")
            || lower.contains("allow edit to")
            || lower.contains("wants to edit")
            || (lower.contains("edit") && lower.contains("allow") && lower.contains("deny"))
    }

    static func isSelectionPrompt(_ screenText: String) -> Bool {
        if isAcceptEditsPrompt(screenText) { return false }
        let lines = screenText.split(separator: "\n").map(String.init)
        let lower = screenText.lowercased()

        // 1. Definitive TUI selection footer — "Enter to select" or "↑/↓ to navigate"
        //    This is the strongest signal: Claude Code's interactive picker.
        let hasSelectionFooter = lower.contains("enter to select") || lower.contains("↑/↓ to navigate") || lower.contains("to navigate")

        // 2. Arrow markers (❯/›) with SHORT option text (≤30 chars).
        //    Long text after ❯ is the input prompt, not a selection option.
        var hasArrowMarker = false
        let tailForArrow = Array(lines.suffix(25))
        for (i, line) in tailForArrow.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let r = t.range(of: "❯") ?? t.range(of: "›") else { continue }
            let after = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !after.isEmpty && after.count > 1 && after.count <= 30 else { continue }
            let nextLines = tailForArrow.dropFirst(i + 1).prefix(3)
            let hasIndentedOptions = nextLines.contains { nextLine in
                let nt = nextLine.trimmingCharacters(in: .whitespaces)
                return !nt.isEmpty && !nt.hasPrefix("❯") && !nt.hasPrefix("›") && !nt.hasPrefix("─")
            }
            if hasIndentedOptions { hasArrowMarker = true; break }
        }

        // 3. Numbered permission options with selection keywords
        let tail = lines.suffix(10)
        let selectionKeywords = ["yes", "no", "allow", "deny", "accept", "reject", "skip", "cancel", "confirm", "trust"]
        let numberedSelectionLines = tail.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard t.hasPrefix("1.") || t.hasPrefix("2.") || t.hasPrefix("3.") else { return false }
            return selectionKeywords.contains { t.contains($0) }
        }

        // 4. Permission keywords in the tail
        let hasPermissionKeywords = tail.contains { let l = $0.lowercased(); return (l.contains("yes") && l.contains("allow")) || l.contains("do you want to") || l.contains("permission") }

        return hasSelectionFooter || hasArrowMarker || numberedSelectionLines.count >= 2 || hasPermissionKeywords
    }

    /// Strict selection check — only matches actual TUI selection widgets (❯ markers
    /// or "Enter to select" footer), NOT numbered text in Claude's output.
    /// Used to re-verify before injecting SELECT responses.
    static func isStrictSelectionPrompt(_ screenText: String) -> Bool {
        if isAcceptEditsPrompt(screenText) { return false }
        let lines = screenText.split(separator: "\n").map(String.init)
        let lower = screenText.lowercased()

        // 1. TUI selection/permission footer
        let hasSelectionFooter = lower.contains("enter to select") || lower.contains("↑/↓ to navigate")
            || lower.contains("esc to cancel") || lower.contains("tab to amend")
            || lower.contains("do you want to proceed")

        // 2. Arrow markers (❯/›)
        var hasArrowMarker = false
        for line in lines.suffix(20) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "❯") ?? t.range(of: "›") {
                let after = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
                if !after.isEmpty && after.count > 1 && after.count <= 40 {
                    hasArrowMarker = true; break
                }
            }
        }

        return hasSelectionFooter || hasArrowMarker
    }

    static func isInteractivePrompt(_ screenText: String) -> Bool {
        if isSelectionPrompt(screenText) || isAcceptEditsPrompt(screenText) { return true }
        let lines = screenText.split(separator: "\n").map(String.init)
        let tailLower = lines.suffix(20).joined(separator: "\n").lowercased()
        if tailLower.contains("esc to cancel") && !tailLower.contains("esc to close") { return true }
        if tailLower.contains("(y/n)") || tailLower.contains("[y/n]") || tailLower.contains("(yes/no)") || tailLower.contains("[yes/no]") { return true }
        if tailLower.contains("do you want to") { return true }
        if tailLower.contains("trust this") || tailLower.contains("allow this mcp") || (tailLower.contains("mcp server") && tailLower.contains("allow")) { return true }
        if tailLower.contains("press enter") || tailLower.contains("press any key") { return true }
        if tailLower.contains("are you sure") || tailLower.contains("proceed?") || tailLower.contains("continue?") { return true }
        if tailLower.contains("would you like") || tailLower.contains("run command") || tailLower.contains("allow command") { return true }
        if tailLower.contains("do you want to make this") { return true }
        if let lastNonEmpty = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let t = lastNonEmpty.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix("?") {
                let lower = screenText.lowercased()
                if lower.contains("claude") || lower.contains("tool use") || lower.contains("compact") || lower.contains("cost:") || lower.contains("tokens") { return true }
            }
        }
        // Check if Claude's output (above the prompt) ends with a question.
        // Claude often finishes work and asks "Want me to X?" or "Should I Y?"
        // The prompt line (❯) is empty but Claude is waiting for a user answer.
        if isClaudeAskingQuestion(lines) {
            return true
        }
        return false
    }

    /// Detect when Claude's output (above the ❯ prompt) ends with a question
    /// directed at the user. Scans the last few lines before the prompt for "?".
    /// This catches cases like "Want me to dig deeper?" or "Should I fix this?"
    /// where Claude is waiting for user input but the prompt line itself is empty.
    static func isClaudeAskingQuestion(_ lines: [String]) -> Bool {
        // Find the prompt line (❯ or bare >) and look at lines above it
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let promptIdx = trimmed.lastIndex(where: { $0.hasPrefix("❯") || $0 == ">" || $0.hasSuffix("> ") }) else {
            return false
        }

        // Look at the last few non-empty lines before the prompt
        let above = trimmed[..<promptIdx].suffix(5).filter { !$0.isEmpty }
        guard let lastAbove = above.last else { return false }

        // If the last meaningful line before the prompt ends with "?", Claude is asking
        return lastAbove.hasSuffix("?")
    }
}
