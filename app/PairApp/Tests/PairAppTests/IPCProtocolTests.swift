import XCTest

/// Tests for the IPC protocol  - verifies JSON encoding/decoding of commands.
final class IPCProtocolTests: XCTestCase {

    func testIPCRequestEncoding() throws {
        let json = """
        {"action":"send_input","surface":"test-session","text":"hello world"}
        """
        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(IPCRequestDTO.self, from: data)
        XCTAssertEqual(request.action, "send_input")
        XCTAssertEqual(request.surface, "test-session")
        XCTAssertEqual(request.text, "hello world")
    }

    func testIPCRequestListSessions() throws {
        let json = """
        {"action":"list_sessions"}
        """
        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(IPCRequestDTO.self, from: data)
        XCTAssertEqual(request.action, "list_sessions")
        XCTAssertNil(request.surface)
        XCTAssertNil(request.text)
    }

    func testIPCResponseEncoding() throws {
        let response = IPCResponseDTO(ok: true, result: "success", error: nil)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(IPCResponseDTO.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.result, "success")
        XCTAssertNil(decoded.error)
    }

    func testIPCResponseError() throws {
        let response = IPCResponseDTO(ok: false, result: nil, error: "Not found")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(IPCResponseDTO.self, from: data)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.error, "Not found")
    }
}

// Standalone DTOs for testing (mirrors IPCServer types)
struct IPCRequestDTO: Codable {
    let action: String
    let surface: String?
    let text: String?
}

struct IPCResponseDTO: Codable {
    let ok: Bool
    var result: String?
    var error: String?
}
