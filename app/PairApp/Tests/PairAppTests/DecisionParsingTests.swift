import XCTest
@testable import PairApp

final class DecisionParsingTests: XCTestCase {

    func testApprove() {
        let decision = CodexDecision.parse("APPROVE")
        guard case .approve = decision else {
            XCTFail("Expected .approve, got \(decision)")
            return
        }
        XCTAssertEqual(decision.rawDescription, "APPROVE")
    }

    func testWait() {
        let decision = CodexDecision.parse("WAIT")
        guard case .wait = decision else {
            XCTFail("Expected .wait, got \(decision)")
            return
        }
        XCTAssertEqual(decision.rawDescription, "WAIT")
    }

    func testAnswer() {
        let decision = CodexDecision.parse("ANSWER: yes, run the integration tests")
        guard case .answer(let text) = decision else {
            XCTFail("Expected .answer, got \(decision)")
            return
        }
        XCTAssertEqual(text, "yes, run the integration tests")
        XCTAssertEqual(decision.rawDescription, "ANSWER: yes, run the integration tests")
    }

    func testSelect() {
        let decision = CodexDecision.parse("SELECT: 2")
        guard case .select(let n) = decision else {
            XCTFail("Expected .select, got \(decision)")
            return
        }
        XCTAssertEqual(n, 2)
    }

    func testRedirect() {
        let decision = CodexDecision.parse("REDIRECT: focus on the failing test first")
        guard case .redirect(let text) = decision else {
            XCTFail("Expected .redirect, got \(decision)")
            return
        }
        XCTAssertEqual(text, "focus on the failing test first")
    }

    func testEscalate() {
        let decision = CodexDecision.parse("ESCALATE: tests keep failing, need human review")
        guard case .escalate(let text) = decision else {
            XCTFail("Expected .escalate, got \(decision)")
            return
        }
        XCTAssertEqual(text, "tests keep failing, need human review")
    }

    func testBareNumberIsUnknown() {
        // Bare numbers must NOT auto-convert to SELECT — they caused false injections
        // when the reviewer hallucinated selection prompts. Reviewer must use "SELECT: N".
        let decision = CodexDecision.parse("2")
        guard case .unknown(let text) = decision else {
            XCTFail("Expected .unknown, got \(decision)")
            return
        }
        XCTAssertEqual(text, "2")
    }

    func testSelectWithPrefix() {
        let decision = CodexDecision.parse("SELECT: 2")
        guard case .select(let n) = decision else {
            XCTFail("Expected .select, got \(decision)")
            return
        }
        XCTAssertEqual(n, 2)
    }

    func testApproveAnywhere() {
        let decision = CodexDecision.parse("looks good, APPROVE")
        guard case .approve = decision else {
            XCTFail("Expected .approve, got \(decision)")
            return
        }
    }

    func testUnknown() {
        let decision = CodexDecision.parse("random freeform text")
        guard case .unknown(let text) = decision else {
            XCTFail("Expected .unknown, got \(decision)")
            return
        }
        XCTAssertEqual(text, "random freeform text")
    }
}
