import XCTest
import Foundation

/// Integration tests that verify the full Codex call pipeline using a mock codex CLI.
/// These don't need real Claude or Codex credentials.
final class IntegrationTests: XCTestCase {

    /// Path to the mock codex script
    var mockCodexPath: String {
        // Find the mock relative to the test file
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return testDir.appendingPathComponent("mocks/codex").path
    }

    // MARK: - Mock Codex CLI

    func testMockCodexReturnsValidJSONL() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: mockCodexPath)
        process.arguments = ["exec", "--json", "-s", "read-only", "test prompt"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)!

        XCTAssertTrue(raw.contains("item.completed"))
        XCTAssertTrue(raw.contains("APPROVE"))
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testParseResponseFromMockCodex() throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: mockCodexPath)
        process.arguments = ["exec", "--json", "-s", "read-only", "test"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)!

        // Parse JSONL just like ClaudeMonitor does
        let response = extractCodexResponse(from: raw)
        XCTAssertEqual(response, "Yes, I approve this work. APPROVE")
    }

    // MARK: - IPC Socket

    func testIPCSocketRoundTrip() throws {
        let socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("pair-test-\(ProcessInfo.processInfo.processIdentifier).sock").path

        defer { unlink(socketPath) }

        // Create a simple echo server
        let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(serverFd, 0)
        defer { close(serverFd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    strcpy(dest, ptr)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bindResult, 0, "Bind failed: \(errno)")
        XCTAssertEqual(listen(serverFd, 1), 0)

        // Verify socket permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: socketPath)
        XCTAssertNotNil(attrs[.type])

        // Connect as client
        let clientFd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFd, 0)
        defer { close(clientFd) }

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectResult, 0, "Connect failed: \(errno)")

        // Send a request
        let request = #"{"action":"list_sessions"}"#
        request.withCString { ptr in
            _ = write(clientFd, ptr, strlen(ptr))
        }

        // Accept on server side
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let acceptedFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverFd, $0, &clientLen)
            }
        }
        XCTAssertGreaterThanOrEqual(acceptedFd, 0)
        defer { close(acceptedFd) }

        // Read what the client sent
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(acceptedFd, &buffer, buffer.count)
        XCTAssertGreaterThan(bytesRead, 0)

        let received = String(bytes: buffer[0..<bytesRead], encoding: .utf8)!
        XCTAssertEqual(received, request)

        // Send response back
        let response = #"{"ok":true,"result":"[]"}"#
        response.withCString { ptr in
            _ = write(acceptedFd, ptr, strlen(ptr))
        }
    }

    // MARK: - Screen Hash Stability Detection

    func testFullDetectionCycle() {
        // Simulates: screen changes → stabilizes → would trigger review
        var lastHash = 0
        var stableCount = 0
        let threshold = 5
        var events: [String] = []

        let screens = [
            "Loading...",
            "Claude Code v2.1.85",
            "Claude Code v2.1.85\n> What is 2+2",
            "Claude Code v2.1.85\n> What is 2+2\n● 4",
            "Claude Code v2.1.85\n> What is 2+2\n● 4",  // stable
            "Claude Code v2.1.85\n> What is 2+2\n● 4",
            "Claude Code v2.1.85\n> What is 2+2\n● 4",
            "Claude Code v2.1.85\n> What is 2+2\n● 4",
            "Claude Code v2.1.85\n> What is 2+2\n● 4",  // 5th stable = trigger
        ]

        for screen in screens {
            let hash = screen.hashValue
            if hash != lastHash {
                lastHash = hash
                stableCount = 0
                events.append("change")
            } else {
                stableCount += 1
                if stableCount == threshold {
                    events.append("trigger")
                } else {
                    events.append("stable(\(stableCount))")
                }
            }
        }

        XCTAssertEqual(events.filter { $0 == "change" }.count, 4, "4 screen changes")
        XCTAssertEqual(events.filter { $0 == "trigger" }.count, 1, "1 review trigger")
    }

    // MARK: - Helpers

    private func extractCodexResponse(from raw: String) -> String? {
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
