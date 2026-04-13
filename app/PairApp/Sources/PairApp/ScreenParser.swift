import Foundation

struct ParsedScreen {
    enum ClaudeState: String {
        case working, waitingForInput, askingQuestion, showingError
        case permissionPrompt, selectionMenu, acceptEdits, idle
    }
    let state: ClaudeState
    let lastToolUsed: String?
    let lastToolResult: String?
    let claudeMessage: String?
    let question: String?
    let permissionDetail: String?
    let selectionOptions: [String]?
    let filesModified: [String]
    let hasError: Bool
    let errorMessage: String?
}

enum ScreenParser {

    // MARK: - Public

    static func parse(_ screenText: String, mode: PairSession.PairMode = .claudeLeads) -> ParsedScreen {
        let lines = screenText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let state = determineState(screenText, lines: lines, mode: mode)
        let (toolName, toolResult) = extractTool(lines)
        let message = extractClaudeMessage(lines)
        let question = state == .askingQuestion ? extractQuestion(lines) : nil
        let options = (state == .selectionMenu || state == .permissionPrompt) ? extractSelectionOptions(lines) : nil
        let permDetail = state == .permissionPrompt ? extractPermissionDetail(lines) : nil
        let files = extractFilesModified(lines)
        let (hasErr, errMsg) = state == .showingError ? extractError(lines) : (false, nil)

        return ParsedScreen(
            state: state,
            lastToolUsed: toolName,
            lastToolResult: toolResult,
            claudeMessage: message,
            question: question,
            permissionDetail: permDetail,
            selectionOptions: options,
            filesModified: files,
            hasError: hasErr,
            errorMessage: errMsg
        )
    }

    // MARK: - State Determination

    private static func determineState(_ screenText: String, lines: [String], mode: PairSession.PairMode = .claudeLeads) -> ParsedScreen.ClaudeState {
        // Branch detection functions based on mode
        let isWorking: Bool
        let isAcceptEdits: Bool
        let isSelection: Bool
        let isStuck: Bool
        let isAskingQuestion: Bool
        let isAtPrompt: Bool
        let isPromptEmpty: Bool

        switch mode {
        case .claudeLeads:
            isWorking = ScreenDetection.isStillWorking(screenText)
            isAcceptEdits = ScreenDetection.isAcceptEditsPrompt(screenText)
            isSelection = ScreenDetection.isSelectionPrompt(screenText)
            isStuck = ScreenDetection.isStuck(screenText)
            isAskingQuestion = ScreenDetection.isClaudeAskingQuestion(lines)
            isAtPrompt = ScreenDetection.isAtClaudePrompt(screenText)
            isPromptEmpty = ScreenDetection.isPromptEmpty(screenText)
        case .codexLeads:
            isWorking = CodexScreenDetection.isStillWorking(screenText)
            isAcceptEdits = CodexScreenDetection.isAcceptEditsPrompt(screenText)
            isSelection = CodexScreenDetection.isSelectionPrompt(screenText)
            isStuck = CodexScreenDetection.isStuck(screenText)
            isAskingQuestion = CodexScreenDetection.isCodexAskingQuestion(lines)
            isAtPrompt = CodexScreenDetection.isAtCodexPrompt(screenText)
            isPromptEmpty = CodexScreenDetection.isPromptEmpty(screenText)
        }

        // Priority order matters
        if isWorking { return .working }
        if isAcceptEdits { return .acceptEdits }
        if isSelection {
            let lower = screenText.lowercased()
            let permissionKeywords = ["wants to", "allow", "permission", "do you want to proceed",
                                      "do you want to", "trust this", "deny"]
            let isPermission = permissionKeywords.contains { lower.contains($0) }
            return isPermission ? .permissionPrompt : .selectionMenu
        }
        if isStuck { return .showingError }
        if isAskingQuestion { return .askingQuestion }
        if isAtPrompt && isPromptEmpty { return .idle }
        if isAtPrompt { return .waitingForInput }
        return .working
    }

    // MARK: - Tool Extraction

    private static let toolPatterns = ["Bash(", "Read(", "Edit(", "Write(", "Glob(", "Grep("]

    private static func extractTool(_ lines: [String]) -> (String?, String?) {
        var lastToolName: String? = nil
        var lastToolLineIndex: Int? = nil

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for pattern in toolPatterns {
                if trimmed.contains(pattern) {
                    lastToolName = String(pattern.dropLast()) // remove the "("
                    lastToolLineIndex = i
                }
            }
        }

        guard let toolName = lastToolName, let toolIdx = lastToolLineIndex else {
            return (nil, nil)
        }

        // Collect result lines after the tool call until next bullet or empty line
        var resultLines: [String] = []
        for i in (toolIdx + 1)..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("●") || trimmed.hasPrefix("❯") {
                break
            }
            resultLines.append(trimmed)
        }

        let result = resultLines.joined(separator: "\n")
        let truncated = result.count > 200 ? String(result.prefix(200)) + "..." : result
        return (toolName, truncated.isEmpty ? nil : truncated)
    }

    // MARK: - Claude Message

    private static func extractClaudeMessage(_ lines: [String]) -> String? {
        // Find the last ● block, or text before ❯ that isn't tool output
        var messageLines: [String] = []
        var inBulletBlock = false
        var lastBulletStart = -1

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("●") {
                inBulletBlock = true
                lastBulletStart = i
                messageLines = [trimmed]
            } else if inBulletBlock {
                if trimmed.hasPrefix("❯") || trimmed.isEmpty {
                    inBulletBlock = false
                } else {
                    // Skip tool output lines
                    let isTool = toolPatterns.contains { trimmed.contains($0) }
                    if !isTool {
                        messageLines.append(trimmed)
                    }
                }
            }
        }

        // If no bullet block found, grab last chunk before prompt
        if lastBulletStart == -1 {
            let promptIdx = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }
            let endIdx = promptIdx ?? lines.count
            var chunk: [String] = []
            for i in stride(from: endIdx - 1, through: max(0, endIdx - 10), by: -1) {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { break }
                let isTool = toolPatterns.contains { trimmed.contains($0) }
                if isTool { break }
                chunk.insert(trimmed, at: 0)
            }
            messageLines = chunk
        }

        let msg = messageLines.joined(separator: " ")
        guard !msg.isEmpty else { return nil }
        return msg.count > 300 ? String(msg.prefix(300)) + "..." : msg
    }

    // MARK: - Question

    private static func extractQuestion(_ lines: [String]) -> String? {
        let promptIdx = lines.lastIndex {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("❯") || t == ">" || t.hasSuffix("> ")
        }
        let searchEnd = promptIdx ?? lines.count
        // Scan backward for lines ending with "?"
        var questionLines: [String] = []
        for i in stride(from: searchEnd - 1, through: max(0, searchEnd - 8), by: -1) {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            questionLines.insert(trimmed, at: 0)
            if trimmed.hasSuffix("?") { break }
        }
        let q = questionLines.joined(separator: " ")
        return q.isEmpty ? nil : q
    }

    // MARK: - Selection Options

    private static func extractSelectionOptions(_ lines: [String]) -> [String]? {
        var options: [String] = []
        let numberedRegex = try? NSRegularExpression(pattern: #"^\s*\d+[.)]\s+(.+)"#)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Numbered options: 1. Foo or 1) Foo
            if let regex = numberedRegex {
                let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
                if let match = regex.firstMatch(in: trimmed, range: range),
                   let captureRange = Range(match.range(at: 1), in: trimmed) {
                    options.append(String(trimmed[captureRange]))
                    if options.count >= 10 { break }
                    continue
                }
            }

            // Arrow markers: ❯ or ›
            if trimmed.hasPrefix("❯") || trimmed.hasPrefix("›") {
                let afterMarker: String
                if let r = trimmed.range(of: "❯") {
                    afterMarker = trimmed[r.upperBound...].trimmingCharacters(in: .whitespaces)
                } else if let r = trimmed.range(of: "›") {
                    afterMarker = trimmed[r.upperBound...].trimmingCharacters(in: .whitespaces)
                } else {
                    continue
                }
                if !afterMarker.isEmpty && afterMarker.count <= 50 {
                    options.append(afterMarker)
                    if options.count >= 10 { break }
                }
            }
        }

        // Also pick up indented lines that follow arrow markers (non-arrow, non-empty)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("❯") || trimmed.hasPrefix("›")
                || trimmed.hasPrefix("─") || trimmed.hasPrefix("●") { continue }
            // If it looks like a plain option in a list following arrow items
            if !options.isEmpty,
               line.hasPrefix("  ") || line.hasPrefix("\t"),
               trimmed.count <= 50,
               numberedRegex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)) == nil {
                // Only add if it looks like a short option, not descriptive text
                if !trimmed.contains(".swift") && !trimmed.contains("to navigate") && !trimmed.contains("to select") {
                    let alreadyHas = options.contains(trimmed)
                    if !alreadyHas {
                        options.append(trimmed)
                        if options.count >= 10 { break }
                    }
                }
            }
        }

        return options.isEmpty ? nil : options
    }

    // MARK: - Permission Detail

    private static func extractPermissionDetail(_ lines: [String]) -> String? {
        let keywords = ["wants to", "allow", "permission", "do you want to proceed"]
        var detailLines: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if keywords.contains(where: { lower.contains($0) }) {
                detailLines.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        let detail = detailLines.joined(separator: " ")
        return detail.isEmpty ? nil : detail
    }

    // MARK: - Files Modified

    private static let fileExtensions = [".swift", ".ts", ".tsx", ".js", ".jsx", ".json", ".md",
                                         ".sh", ".yml", ".yaml", ".toml", ".css", ".html", ".py",
                                         ".rs", ".go", ".rb", ".txt", ".xml", ".plist"]

    private static func extractFilesModified(_ lines: [String]) -> [String] {
        var files = Set<String>()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Diff headers: +++ b/path or --- a/path
            if trimmed.hasPrefix("+++ ") || trimmed.hasPrefix("--- ") {
                let path = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
                let cleaned = path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
                if let basename = cleaned.split(separator: "/").last {
                    files.insert(String(basename))
                }
                continue
            }

            // Scan for file extensions in the line
            for ext in fileExtensions {
                var searchRange = trimmed.startIndex..<trimmed.endIndex
                while let range = trimmed.range(of: ext, range: searchRange) {
                    // Extract the filename by walking backward from the extension
                    let endOfFile = range.upperBound
                    // Make sure it's a word boundary (end of token)
                    if endOfFile < trimmed.endIndex {
                        let nextChar = trimmed[endOfFile]
                        if nextChar.isLetter || nextChar.isNumber || nextChar == "." {
                            searchRange = range.upperBound..<trimmed.endIndex
                            continue
                        }
                    }
                    // Walk backward to find start of filename
                    var start = range.lowerBound
                    while start > trimmed.startIndex {
                        let prevIdx = trimmed.index(before: start)
                        let ch = trimmed[prevIdx]
                        if ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "." {
                            start = prevIdx
                        } else {
                            break
                        }
                    }
                    let filename = String(trimmed[start..<endOfFile])
                    if filename.count > ext.count { // Must have a name, not just extension
                        files.insert(filename)
                    }
                    searchRange = range.upperBound..<trimmed.endIndex
                }
            }
        }

        return Array(files).sorted()
    }

    // MARK: - Error Extraction

    private static func extractError(_ lines: [String]) -> (Bool, String?) {
        let errorKeywords = ["error:", "failed", "interrupted", "rate limit"]
        var errorLines: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if errorKeywords.contains(where: { lower.contains($0) }) {
                errorLines.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        let msg = errorLines.joined(separator: "\n")
        let truncated = msg.count > 200 ? String(msg.prefix(200)) + "..." : msg
        return (true, truncated.isEmpty ? nil : truncated)
    }
}
