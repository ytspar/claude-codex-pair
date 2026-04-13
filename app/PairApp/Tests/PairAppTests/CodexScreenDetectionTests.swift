import XCTest
@testable import PairApp

final class CodexScreenDetectionTests: XCTestCase {

    // MARK: - Header constant used in multi-line screens

    private let codexHeader = """
    ╭───────────────────────────────────────────╮
    │ >_ OpenAI Codex (v0.120.0)                │
    │                                           │
    │ model:     gpt-5.4   /model to change     │
    │ directory: ~/git/ytspar/claude-codex-pair │
    ╰───────────────────────────────────────────╯
    """

    // MARK: - isAtCodexPrompt

    func testIdlePromptDetected() {
        let screen = """
        \(codexHeader)
        ›
          gpt-5.4 default · ~/git/ytspar/claude-codex-pair
        """
        XCTAssertTrue(CodexScreenDetection.isAtCodexPrompt(screen))
        XCTAssertTrue(CodexScreenDetection.isPromptEmpty(screen))
    }

    func testPromptWithPlaceholder() {
        let screen = """
        \(codexHeader)
        › Improve documentation in @filename
          gpt-5.4 default · ~/git/ytspar/claude-codex-pair
        """
        XCTAssertTrue(CodexScreenDetection.isAtCodexPrompt(screen))
        XCTAssertTrue(CodexScreenDetection.isPromptEmpty(screen))
    }

    func testPromptWithUserText() {
        let screen = """
        \(codexHeader)
        › What files are in app/PairApp/Sources/PairApp/? Just list filenames.
          gpt-5.4 default · ~/git/ytspar/claude-codex-pair
        """
        XCTAssertTrue(CodexScreenDetection.isAtCodexPrompt(screen))
        XCTAssertFalse(CodexScreenDetection.isPromptEmpty(screen))
    }

    // MARK: - isStillWorking

    func testWorkingStateWithTimer() {
        let screen = """
        \(codexHeader)
        • I'm checking that directory directly and will return only the filenames.
        • Working (3s • esc to interrupt)
        """
        XCTAssertTrue(CodexScreenDetection.isStillWorking(screen))
        XCTAssertFalse(CodexScreenDetection.isAtCodexPrompt(screen))
    }

    func testWorkingStateWithActionVerb() {
        let screen = """
        \(codexHeader)
        • Reading the file contents now.
        """
        XCTAssertTrue(CodexScreenDetection.isStillWorking(screen))
    }

    func testNotWorkingAtIdle() {
        let screen = """
        \(codexHeader)
        ›
          gpt-5.4 default · ~/git/ytspar/claude-codex-pair
        """
        XCTAssertFalse(CodexScreenDetection.isStillWorking(screen))
    }

    // MARK: - isSelectionPrompt / trust dialog

    func testTrustDialog() {
        let screen = """
        \(codexHeader)
        > You are in /Users/ytspar/git/ytspar/claude-codex-pair
          Do you trust the contents of this directory?
        › 1. Yes, continue
          2. No, quit
          Press enter to continue
        """
        XCTAssertTrue(CodexScreenDetection.isSelectionPrompt(screen))
        XCTAssertTrue(CodexScreenDetection.isInteractivePrompt(screen))
        // Should NOT be detected as a normal prompt
        XCTAssertFalse(CodexScreenDetection.isAtCodexPrompt(screen))
    }

    func testSelectionWithEnterToSelect() {
        let screen = """
        Which model would you like?
        › 1. gpt-5.4
          2. gpt-4o
          3. o3-pro
          Press enter to select
        """
        XCTAssertTrue(CodexScreenDetection.isSelectionPrompt(screen))
    }

    // MARK: - isStuck

    func testStuckOnError() {
        let screen = """
        \(codexHeader)
        • Attempting to fetch data...
        error: connection refused
        ›
          gpt-5.4 default · ~/git/ytspar/claude-codex-pair
        """
        XCTAssertTrue(CodexScreenDetection.isStuck(screen))
    }

    func testStuckOnRateLimit() {
        let screen = """
        \(codexHeader)
        rate limit exceeded, try again in 30 seconds
        """
        XCTAssertTrue(CodexScreenDetection.isStuck(screen))
    }

    func testNotStuckWhenWorking() {
        let screen = """
        \(codexHeader)
        • Working (5s • esc to interrupt)
        """
        XCTAssertFalse(CodexScreenDetection.isStuck(screen))
    }

    // MARK: - isCodexAskingQuestion

    func testCodexAskingQuestion() {
        let lines = [
            "• Here are the files I found.",
            "Would you like me to edit any of them?",
            "›",
            "  gpt-5.4 default · ~/git/ytspar/claude-codex-pair"
        ]
        XCTAssertTrue(CodexScreenDetection.isCodexAskingQuestion(lines))
    }

    func testCodexNotAskingQuestion() {
        let lines = [
            "• Done. I listed all the files.",
            "›",
            "  gpt-5.4 default · ~/git/ytspar/claude-codex-pair"
        ]
        XCTAssertFalse(CodexScreenDetection.isCodexAskingQuestion(lines))
    }

    // MARK: - isInteractivePrompt

    func testInteractiveOnYesNo() {
        let screen = """
        \(codexHeader)
        Do you want to proceed? (y/n)
        ›
        """
        XCTAssertTrue(CodexScreenDetection.isInteractivePrompt(screen))
    }

    func testInteractiveOnQuestionAbovePrompt() {
        let screen = """
        \(codexHeader)
        • I found 3 issues. Should I fix them?
        ›
          gpt-5.4 default · ~/git/ytspar/claude-codex-pair
        """
        XCTAssertTrue(CodexScreenDetection.isInteractivePrompt(screen))
    }

    func testNotInteractiveAtPlainPrompt() {
        let screen = """
        \(codexHeader)
        • Done. All tests pass.
        ›
          gpt-5.4 default · ~/git/ytspar/claude-codex-pair
        """
        XCTAssertFalse(CodexScreenDetection.isInteractivePrompt(screen))
    }

    // MARK: - isModalView

    func testModalDetected() {
        let screen = """
        Help — Keyboard Shortcuts
        esc to close
        """
        XCTAssertTrue(CodexScreenDetection.isModalView(screen))
    }

    func testNoModal() {
        let screen = """
        \(codexHeader)
        ›
        """
        XCTAssertFalse(CodexScreenDetection.isModalView(screen))
    }

    // MARK: - isInterruptedPrompt

    func testInterruptedDetected() {
        let screen = """
        \(codexHeader)
        • Task was interrupted
        ›
          gpt-5.4 default · ~/git/ytspar/claude-codex-pair
        """
        XCTAssertTrue(CodexScreenDetection.isInterruptedPrompt(screen))
    }

    func testNotInterruptedWhileWorking() {
        let screen = """
        \(codexHeader)
        • Working (3s • esc to interrupt)
        """
        XCTAssertFalse(CodexScreenDetection.isInterruptedPrompt(screen))
    }

    // MARK: - isAcceptEditsPrompt

    func testAcceptEditsDetected() {
        let screen = """
        \(codexHeader)
        Do you want to make this edit?
        ›
        """
        XCTAssertTrue(CodexScreenDetection.isAcceptEditsPrompt(screen))
    }

    func testAcceptChangesDetected() {
        let screen = """
        \(codexHeader)
        Accept changes to main.swift?
        """
        XCTAssertTrue(CodexScreenDetection.isAcceptEditsPrompt(screen))
    }
}
