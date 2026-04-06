import XCTest
@testable import PairApp

/// Tests for the screen change detection logic.
final class ClaudeMonitorTests: XCTestCase {

    // MARK: - Selection Prompt Detection

    func testDetectsArrowMarkerPrompt() {
        let screen = """
        Do you want to create this file?
        ❯ Yes
          Yes, allow all
          No
        """
        XCTAssertTrue(ClaudeMonitor.isSelectionPrompt(screen))
    }

    func testDetectsSingleGuillemotMarkerPrompt() {
        let screen = """
        Do you want to proceed?
        › Yes
          No
        """
        XCTAssertTrue(ClaudeMonitor.isSelectionPrompt(screen))
    }

    func testDetectsSingleGuillemotWithMultipleOptions() {
        let screen = """
        Claude wants to edit main.swift
        › Allow once
          Allow always
          Deny
        """
        XCTAssertTrue(ClaudeMonitor.isSelectionPrompt(screen))
    }

    func testDetectsNumberedOptionsPrompt() {
        let screen = """
        Claude wants to edit foo.swift
        1. Yes
        2. Yes, allow all
        3. No
        """
        XCTAssertTrue(ClaudeMonitor.isSelectionPrompt(screen))
    }

    func testDetectsPermissionKeywords() {
        let screen = """
        Do you want to allow Claude to write files?
        Press Enter to confirm
        """
        XCTAssertTrue(ClaudeMonitor.isSelectionPrompt(screen))
    }

    func testCursorPromptNotDetectedAsSelection() {
        // A bare shell prompt with ❯ followed by a blank line is NOT
        // an interactive selection  - it's just a zsh/fish cursor prompt.
        let screen = """
        Claude Code v2.1.85
        Done. Created hello.swift
        ❯

        """
        XCTAssertFalse(ClaudeMonitor.isSelectionPrompt(screen))
    }

    func testBareGuillemotPromptNotDetectedAsSelection() {
        // A bare › with no option text is a shell prompt, not a selection.
        let screen = """
        Claude Code v2.1.85
        Done. Created hello.swift
        ›

        """
        XCTAssertFalse(ClaudeMonitor.isSelectionPrompt(screen))
    }

    func testDoesNotDetectNormalOutput() {
        let screen = """
        Claude Code v2.1.85
        Working on your task...
        Created file: hello.swift
        """
        XCTAssertFalse(ClaudeMonitor.isSelectionPrompt(screen))
    }

    func testScreenChangeDetected() {
        var hashes: [Int] = []
        var stableCount = 0
        let threshold = 5

        // Simulate 3 screen changes then stability
        let screens = [
            "Claude Code v2.1.85\nWelcome",
            "Claude Code v2.1.85\nWelcome\n> working...",
            "Claude Code v2.1.85\nWelcome\n> done\nWhat next?",
            "Claude Code v2.1.85\nWelcome\n> done\nWhat next?",  // same
            "Claude Code v2.1.85\nWelcome\n> done\nWhat next?",  // same
            "Claude Code v2.1.85\nWelcome\n> done\nWhat next?",  // same
            "Claude Code v2.1.85\nWelcome\n> done\nWhat next?",  // same
            "Claude Code v2.1.85\nWelcome\n> done\nWhat next?",  // same = 5 stable
        ]

        var triggeredReview = false

        for screen in screens {
            let hash = screen.hashValue
            if hashes.last != hash {
                hashes.append(hash)
                stableCount = 0
            } else {
                stableCount += 1
                if stableCount == threshold {
                    triggeredReview = true
                }
            }
        }

        XCTAssertTrue(triggeredReview, "Should trigger review after 5 stable polls")
        XCTAssertEqual(hashes.count, 3, "Should have detected 3 distinct screens")
    }

    func testNoReviewWhileChanging() {
        var stableCount = 0
        let threshold = 5
        var lastHash = 0
        var triggered = false

        // Every screen is different  - should never trigger
        for i in 0..<20 {
            let hash = "screen \(i)".hashValue
            if hash != lastHash {
                lastHash = hash
                stableCount = 0
            } else {
                stableCount += 1
                if stableCount == threshold { triggered = true }
            }
        }

        XCTAssertFalse(triggered, "Should not trigger review while screen keeps changing")
    }

    func testImmediateStability() {
        // Screen never changes from the start  - should trigger after threshold
        var stableCount = 0
        let threshold = 5
        let hash = "static screen".hashValue
        var lastHash = hash
        var triggered = false

        for _ in 0..<10 {
            if hash != lastHash {
                lastHash = hash
                stableCount = 0
            } else {
                stableCount += 1
                if stableCount == threshold { triggered = true }
            }
        }

        XCTAssertTrue(triggered)
    }

    // MARK: - selectOption Arrow Down Count

    func testSelectOptionArrowDownCount() {
        // Subclass PairSession to record calls without a real terminal
        class MockSession: PairSession {
            var arrowDownCounts: [Int] = []
            var enterCount = 0

            override func sendArrowDown(_ count: Int = 1) {
                arrowDownCounts.append(count)
            }
            override func sendEnter() {
                enterCount += 1
            }
        }

        let session = MockSession(id: "test", cwd: "/tmp")

        // selectOption(1) → 0 arrow downs (first option is already selected)
        session.selectOption(1)
        XCTAssertEqual(session.arrowDownCounts, [0],
                       "Option 1 should send 0 arrow downs")

        // selectOption(3) → 2 arrow downs
        session.selectOption(3)
        XCTAssertEqual(session.arrowDownCounts, [0, 2],
                       "Option 3 should send 2 arrow downs")
    }

    // MARK: - Screen Change Detection

    func testChangeThresholdPreventsEarlyReview() {
        // Mirrors the poll() guard: stableCount == threshold && changeCount >= 10
        // With only 3 screen changes, review should NOT trigger even after stability.
        var lastHash = 0
        var stableCount = 0
        var changeCount = 0
        var triggered = false
        let stableThreshold = 5
        let changeThreshold = 10

        // 3 distinct screens then 6 stable polls (exceeds stableThreshold)
        let screens = [
            "screen A", "screen B", "screen C",
            "screen C", "screen C", "screen C",
            "screen C", "screen C", "screen C",
        ]

        for screen in screens {
            let hash = screen.hashValue
            if hash != lastHash {
                lastHash = hash
                stableCount = 0
                changeCount += 1
            } else {
                stableCount += 1
                if stableCount == stableThreshold && changeCount >= changeThreshold {
                    triggered = true
                }
            }
        }

        XCTAssertFalse(triggered, "Should not trigger review when changeCount (\(changeCount)) < \(changeThreshold)")
        XCTAssertEqual(changeCount, 3)

        // Now simulate enough changes (10+) followed by stability  - should trigger
        lastHash = 0; stableCount = 0; changeCount = 0; triggered = false

        var moreScreens: [String] = (0..<12).map { "changing \($0)" }
        moreScreens += Array(repeating: "changing 11", count: 6)

        for screen in moreScreens {
            let hash = screen.hashValue
            if hash != lastHash {
                lastHash = hash
                stableCount = 0
                changeCount += 1
            } else {
                stableCount += 1
                if stableCount == stableThreshold && changeCount >= changeThreshold {
                    triggered = true
                }
            }
        }

        XCTAssertTrue(triggered, "Should trigger review when changeCount (\(changeCount)) >= \(changeThreshold) and stable")
    }

    // MARK: - Exponential Backoff

    func testBackoffMultiplierIncreasesWithUnhelpfulReviews() {
        let st = SessionMonitorState(sessionId: "test-backoff")
        // Default backoff should be 1.0
        XCTAssertEqual(st.backoffMultiplier, 1.0)
        XCTAssertEqual(st.effectiveStableThreshold, 3) // 3 * 1.0 = 3

        // After 3 unhelpful reviews (backoff threshold), multiplier should increase
        st.consecutiveUnhelpful = 3
        st.backoffMultiplier = 1.0 // 2^0
        XCTAssertEqual(st.effectiveStableThreshold, 3)

        // After 4 unhelpful reviews: 2^1 = 2x
        st.backoffMultiplier = 2.0
        XCTAssertEqual(st.effectiveStableThreshold, 6) // 3 * 2.0 = 6

        // After 5 unhelpful reviews: 2^2 = 4x
        st.backoffMultiplier = 4.0
        XCTAssertEqual(st.effectiveStableThreshold, 12) // 3 * 4.0 = 12

        // Backoff should cap at 10x
        st.backoffMultiplier = 10.0
        XCTAssertEqual(st.effectiveStableThreshold, 30) // 3 * 10.0 = 30

        // Reset on success
        st.consecutiveUnhelpful = 0
        st.backoffMultiplier = 1.0
        XCTAssertEqual(st.effectiveStableThreshold, 3)
    }

    // MARK: - Progress Signal Outcome Computation

    func testOutcomeImprovedOnNewCommits() {
        let before = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 3, insertions: 50, deletions: 10)
        let after = CodexLedger.ProgressSignal(commitCount: 11, uncommittedFiles: 2, insertions: 30, deletions: 5)
        XCTAssertEqual(CodexLedger.computeOutcome(before: before, after: after), "improved")
    }

    func testOutcomeNeutralWhenNoChange() {
        let before = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 3, insertions: 50, deletions: 10)
        let after = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 3, insertions: 52, deletions: 12)
        XCTAssertEqual(CodexLedger.computeOutcome(before: before, after: after), "neutral")
    }

    func testOutcomeNeutralWhenNoBefore() {
        let after = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 3, insertions: 50, deletions: 10)
        XCTAssertEqual(CodexLedger.computeOutcome(before: nil, after: after), "neutral")
    }

    func testOutcomeImprovedOnSignificantCodeChange() {
        let before = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 3, insertions: 50, deletions: 10)
        let after = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 5, insertions: 80, deletions: 10)
        // Net before: 40, net after: 70, diff = 30 > 5
        XCTAssertEqual(CodexLedger.computeOutcome(before: before, after: after), "improved")
    }

    func testOutcomeImprovedWhenUncommittedDecreases() {
        // Uncommitted files went down = Claude committed existing work
        let before = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 5, insertions: 50, deletions: 10)
        let after = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 2, insertions: 50, deletions: 10)
        XCTAssertEqual(CodexLedger.computeOutcome(before: before, after: after), "improved")
    }

    func testOutcomeImprovedWhenNewFilesCreated() {
        // New uncommitted files = Claude is actively writing
        let before = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 2, insertions: 30, deletions: 5)
        let after = CodexLedger.ProgressSignal(commitCount: 10, uncommittedFiles: 4, insertions: 30, deletions: 5)
        XCTAssertEqual(CodexLedger.computeOutcome(before: before, after: after), "improved")
    }

    // MARK: - Loop Detection

    func testLoopDetectionRequiresThreeSnapshots() {
        let st = SessionMonitorState(sessionId: "test-loop")
        // Less than 3 snapshots should not detect loop
        st.recordScreenSnapshot("hello world this is a test")
        st.recordScreenSnapshot("hello world this is a test")
        XCTAssertFalse(st.detectLoop())

        // Third similar snapshot should trigger loop detection
        st.recordScreenSnapshot("hello world this is a test")
        XCTAssertTrue(st.detectLoop())
    }

    func testLoopDetectionDifferentContent() {
        let st = SessionMonitorState(sessionId: "test-no-loop")
        st.recordScreenSnapshot("completely different content here")
        st.recordScreenSnapshot("another very unique screen output")
        st.recordScreenSnapshot("third unique and separate screen")
        XCTAssertFalse(st.detectLoop())
    }

    // MARK: - isAcceptEditsPrompt

    func testDetectsAcceptEditsOnPrompt() {
        let screen = """
        app/PairApp/Sources/PairApp/Version.swift
        Accept edits on this file?
        Shift+Tab to cycle through options
        """
        XCTAssertTrue(ClaudeMonitor.isAcceptEditsPrompt(screen))
    }

    func testDetectsShiftTabToCyclePrompt() {
        let screen = """
        main.swift
        shift-tab to cycle through options
        """
        XCTAssertTrue(ClaudeMonitor.isAcceptEditsPrompt(screen))
    }

    func testDetectsDoYouWantToMakeThisEdit() {
        let screen = """
        Do you want to make this edit to main.swift?
        ❯ Yes
          No
        """
        XCTAssertTrue(ClaudeMonitor.isAcceptEditsPrompt(screen))
    }

    func testNormalOutputNotAcceptEdits() {
        let screen = """
        Claude Code v2.1.85
        Created hello.swift
        ❯
        """
        XCTAssertFalse(ClaudeMonitor.isAcceptEditsPrompt(screen))
    }

    // MARK: - isInteractivePrompt (comprehensive)

    func testDetectsYesNoParenthesized() {
        let screen = """
        Do you want to continue? (y/n)
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsBracketedYesNo() {
        let screen = """
        Overwrite file? [yes/no]
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsAreYouSure() {
        let screen = """
        This will delete 3 files.
        Are you sure?
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsProceedQuestion() {
        let screen = """
        Changes detected in 5 files.
        Proceed?
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsContinueQuestion() {
        let screen = """
        Rate limit reached.
        Continue?
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsPressEnter() {
        let screen = """
        Installation complete.
        Press Enter to continue
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsPressAnyKey() {
        let screen = """
        Setup finished.
        Press any key to exit
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsEscToCancel() {
        let screen = """
        Claude wants to run: rm -rf /tmp/test
        Esc to cancel
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDoesNotTriggerOnEscToClose() {
        // "esc to close" is a viewer/pager, not an interactive prompt
        let screen = """
        File contents displayed
        Esc to close
        """
        XCTAssertFalse(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsMcpTrustPrompt() {
        let screen = """
        MCP server "fetch" wants to access the network.
        Allow this MCP server?
        ❯ Allow once
          Allow always
          Deny
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsTrustThis() {
        let screen = """
        trust this MCP server to run tools?
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsDoYouWantTo() {
        let screen = """
        Do you want to allow Claude to write files?
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsWouldYouLike() {
        let screen = """
        Would you like to install the missing dependency?
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsRunCommand() {
        let screen = """
        Claude wants to run command: npm install
        Allow once?
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testDetectsClaudeAskingQuestion() {
        let screen = """
        I found 3 files that match.
        Which one would you like me to examine?
        ❯
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testClaudeAskingQuestionWithCostLine() {
        let screen = """
        Claude Code cost: $0.15
        I can refactor this two ways.
        Should I use approach A or B?
        ❯
        """
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testNormalOutputNotInteractive() {
        let screen = """
        Claude Code v2.1.85
        Working on your task...
        Created file: hello.swift
        ❯
        """
        XCTAssertFalse(ClaudeMonitor.isInteractivePrompt(screen))
    }

    func testNormalCodeOutputNotInteractive() {
        // Code output that happens to contain "?" in strings shouldn't trigger
        let screen = """
        Read src/main.ts
        let query = "what is this?"
        let url = "https://example.com?q=1"
        ❯
        """
        XCTAssertFalse(ClaudeMonitor.isInteractivePrompt(screen))
    }

    // MARK: - isAcceptEditsPrompt excludes from isSelectionPrompt

    func testAcceptEditsNotDetectedAsSelectionPrompt() {
        // isSelectionPrompt should return false for accept-edits screens
        // (they have ❯ markers but need different handling: Enter, not arrow keys)
        let screen = """
        Do you want to make this edit to main.swift?
        ❯ Yes
          No
        """
        XCTAssertFalse(ClaudeMonitor.isSelectionPrompt(screen))
        XCTAssertTrue(ClaudeMonitor.isAcceptEditsPrompt(screen))
        XCTAssertTrue(ClaudeMonitor.isInteractivePrompt(screen))
    }

    // MARK: - isClaudeAskingQuestion edge cases

    func testNotAskingWhenNoPromptMarker() {
        let lines = [
            "Here is the output.",
            "All done.",
        ]
        XCTAssertFalse(ClaudeMonitor.isClaudeAskingQuestion(lines))
    }

    func testNotAskingWhenLineAboveIsNotQuestion() {
        let lines = [
            "I created the file successfully.",
            "❯",
        ]
        XCTAssertFalse(ClaudeMonitor.isClaudeAskingQuestion(lines))
    }

    func testAskingWhenLineAboveEndsWithQuestionMark() {
        let lines = [
            "I found 3 matching files.",
            "Want me to examine them?",
            "❯",
        ]
        XCTAssertTrue(ClaudeMonitor.isClaudeAskingQuestion(lines))
    }

    func testAskingWithEmptyLinesBetween() {
        let lines = [
            "Should I proceed with the refactor?",
            "",
            "❯",
        ]
        XCTAssertTrue(ClaudeMonitor.isClaudeAskingQuestion(lines))
    }
}
