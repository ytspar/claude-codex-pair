import XCTest
@testable import PairApp

final class ScreenParserTests: XCTestCase {

    // MARK: - State Detection

    func testWorkingScreen() {
        let screen = """
        agent still running
        tasks (2 open)
        ⠋ Building project...
        Still working on it, let me wait for it to complete
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.state, .working)
    }

    func testSelectionMenu() {
        let screen = """
        Which file would you like to edit?
        ❯ main.swift
          utils.swift
          config.json
        Enter to select · ↑/↓ to navigate
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.state, .selectionMenu)
        XCTAssertNotNil(parsed.selectionOptions)
        XCTAssertTrue(parsed.selectionOptions?.contains("main.swift") == true)
    }

    func testPermissionPrompt() {
        let screen = """
        Claude wants to run: rm -rf /tmp/build
        Do you want to allow this?
        ❯ Yes
          No
          Allow always
        Enter to select · ↑/↓ to navigate
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.state, .permissionPrompt)
        XCTAssertNotNil(parsed.permissionDetail)
        XCTAssertTrue(parsed.permissionDetail?.lowercased().contains("allow") == true)
    }

    func testClaudeAskingQuestion() {
        let screen = """
        Claude Code cost: $0.15
        I found 3 matching files.
        Want me to examine them?
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.state, .askingQuestion)
        XCTAssertNotNil(parsed.question)
        XCTAssertTrue(parsed.question?.contains("examine") == true)
    }

    func testErrorScreen() {
        let screen = """
        Claude Code v2.1.85
        Running build...
        error: module 'SwiftTerm' not found
        Build failed to complete
        What should Claude do
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.state, .showingError)
        XCTAssertTrue(parsed.hasError)
        XCTAssertNotNil(parsed.errorMessage)
        XCTAssertTrue(parsed.errorMessage?.contains("error:") == true)
    }

    func testIdlePrompt() {
        let screen = """
        Claude Code v2.1.85
        cost: $0.03
        Done. Created hello.swift
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.state, .idle)
    }

    func testAcceptEditsState() {
        let screen = """
        app/PairApp/Sources/PairApp/Version.swift
        Accept edits on this file?
        Shift+Tab to cycle through options
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.state, .acceptEdits)
    }

    // MARK: - Tool Extraction

    func testExtractBashTool() {
        let screen = """
        ● Running command
        Bash(ls -la)
        total 48
        drwxr-xr-x  5 user  staff  160 Jan  1 12:00 .
        -rw-r--r--  1 user  staff  200 Jan  1 12:00 main.swift
        ● Done
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.lastToolUsed, "Bash")
        XCTAssertNotNil(parsed.lastToolResult)
    }

    func testExtractReadTool() {
        let screen = """
        ● Checking file
        Read(main.swift)
        import Foundation
        print("hello")

        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.lastToolUsed, "Read")
    }

    func testExtractEditTool() {
        let screen = """
        cost: $0.10
        ● Editing
        Edit(main.swift)
        Applied changes
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertEqual(parsed.lastToolUsed, "Edit")
    }

    // MARK: - File Path Extraction

    func testFilePathExtraction() {
        let screen = """
        Modified files:
        +++ b/Sources/PairApp/ScreenParser.swift
        --- a/Sources/PairApp/ClaudeMonitor.swift
        Also touched config.json and README.md
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertTrue(parsed.filesModified.contains("ScreenParser.swift"))
        XCTAssertTrue(parsed.filesModified.contains("ClaudeMonitor.swift"))
        XCTAssertTrue(parsed.filesModified.contains("config.json"))
        XCTAssertTrue(parsed.filesModified.contains("README.md"))
    }

    func testFilePathDeduplication() {
        let screen = """
        Read main.swift
        Edit main.swift
        Write main.swift
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        let swiftCount = parsed.filesModified.filter { $0 == "main.swift" }.count
        XCTAssertEqual(swiftCount, 1, "main.swift should appear only once")
    }

    func testMultipleExtensions() {
        let screen = """
        Changed: app.ts, utils.tsx, package.json, run.sh
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertTrue(parsed.filesModified.contains("app.ts"))
        XCTAssertTrue(parsed.filesModified.contains("utils.tsx"))
        XCTAssertTrue(parsed.filesModified.contains("package.json"))
        XCTAssertTrue(parsed.filesModified.contains("run.sh"))
    }

    // MARK: - Claude Message

    func testClaudeMessageExtraction() {
        let screen = """
        ● I have updated the file successfully.
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertNotNil(parsed.claudeMessage)
        XCTAssertTrue(parsed.claudeMessage?.contains("updated the file") == true)
    }

    // MARK: - Edge Cases

    func testEmptyScreen() {
        let parsed = ScreenParser.parse("")
        XCTAssertEqual(parsed.state, .working)
        XCTAssertNil(parsed.lastToolUsed)
        XCTAssertTrue(parsed.filesModified.isEmpty)
    }

    func testNoToolResult() {
        let screen = """
        Just some regular output
        Nothing special here
        ❯
        """
        let parsed = ScreenParser.parse(screen)
        XCTAssertNil(parsed.lastToolUsed)
        XCTAssertNil(parsed.lastToolResult)
    }
}
