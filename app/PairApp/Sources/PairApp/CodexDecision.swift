import Foundation

/// Codex decision type — the structured action Codex takes in response to a Claude prompt.
enum CodexDecision {
    case approve
    case wait
    case answer(String)
    case select(Int)
    case redirect(String)
    case escalate(String)
    case unknown(String)

    /// Parse a raw Codex response string into a structured decision.
    static func parse(_ response: String) -> CodexDecision {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        // Exact prefix matches (case-insensitive)
        if upper == "APPROVE" {
            return .approve
        }
        if upper == "WAIT" {
            return .wait
        }
        if upper.hasPrefix("ANSWER:") {
            let value = String(trimmed.dropFirst("ANSWER:".count)).trimmingCharacters(in: .whitespaces)
            return .answer(value)
        }
        if upper.hasPrefix("SELECT:") {
            let value = String(trimmed.dropFirst("SELECT:".count)).trimmingCharacters(in: .whitespaces)
            return .select(Int(value) ?? 1)
        }
        if upper.hasPrefix("REDIRECT:") {
            let value = String(trimmed.dropFirst("REDIRECT:".count)).trimmingCharacters(in: .whitespaces)
            return .redirect(value)
        }
        if upper.hasPrefix("ESCALATE:") {
            let value = String(trimmed.dropFirst("ESCALATE:".count)).trimmingCharacters(in: .whitespaces)
            return .escalate(value)
        }

        // Backward compat: APPROVE anywhere in response
        if upper.contains("APPROVE") {
            return .approve
        }

        // Backward compat: bare number → select
        if let n = Int(trimmed) {
            return .select(n)
        }

        return .unknown(trimmed)
    }

    /// Human-readable description matching the raw format.
    var rawDescription: String {
        switch self {
        case .approve:
            return "APPROVE"
        case .wait:
            return "WAIT"
        case .answer(let text):
            return "ANSWER: \(text)"
        case .select(let n):
            return "SELECT: \(n)"
        case .redirect(let text):
            return "REDIRECT: \(text)"
        case .escalate(let text):
            return "ESCALATE: \(text)"
        case .unknown(let text):
            return text
        }
    }
}
