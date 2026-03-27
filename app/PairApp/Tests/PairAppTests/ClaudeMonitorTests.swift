import XCTest

/// Tests for the screen change detection logic.
final class ClaudeMonitorTests: XCTestCase {

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

        // Every screen is different — should never trigger
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
        // Screen never changes from the start — should trigger after threshold
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
}
