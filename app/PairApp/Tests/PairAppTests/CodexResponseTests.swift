import XCTest

/// Tests parsing of codex exec --json JSONL output.
final class CodexResponseTests: XCTestCase {

    func testParseItemCompleted() {
        let jsonl = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Yes, this is my first time."}}
        {"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":10}}
        """

        let text = extractResponse(from: jsonl)
        XCTAssertEqual(text, "Yes, this is my first time.")
    }

    func testParseEmptyResponse() {
        let jsonl = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":0}}
        """

        let text = extractResponse(from: jsonl)
        XCTAssertNil(text)
    }

    func testParseMultipleItems() {
        let jsonl = """
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"First part"}}
        {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"APPROVE"}}
        """

        // Should return the last item.completed text
        let text = extractResponse(from: jsonl)
        XCTAssertEqual(text, "APPROVE")
    }

    /// Mirrors the parsing logic from ClaudeMonitor.callCodex
    private func extractResponse(from raw: String) -> String? {
        var responseText = ""
        for line in raw.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "item.completed",
               let item = json["item"] as? [String: Any],
               let text = item["text"] as? String {
                responseText = text
            }
        }
        let cleaned = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
