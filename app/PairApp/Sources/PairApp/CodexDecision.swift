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
        guard let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return .unknown("")
        }
        let first = firstLine.trimmingCharacters(in: .whitespaces)
        let upper = first.uppercased()

        // Only the first line is authoritative. Explanatory text must not turn
        // REDIRECT/ANSWER responses into accidental approvals.
        if upper == "APPROVE" {
            return .approve
        }
        if upper == "WAIT" {
            return .wait
        }
        if upper.hasPrefix("ANSWER:") {
            let value = String(first.dropFirst("ANSWER:".count)).trimmingCharacters(in: .whitespaces)
            return .answer(value)
        }
        if upper.hasPrefix("SELECT:") {
            let value = String(first.dropFirst("SELECT:".count)).trimmingCharacters(in: .whitespaces)
            guard let token = value.split(separator: " ").first,
                  let n = Int(token),
                  n >= 1 else {
                return .escalate("Reviewer returned invalid SELECT decision: \(first)")
            }
            return .select(n)
        }
        if upper.hasPrefix("REDIRECT:") {
            let value = String(first.dropFirst("REDIRECT:".count)).trimmingCharacters(in: .whitespaces)
            return .redirect(value)
        }
        if upper.hasPrefix("ESCALATE:") {
            let value = String(first.dropFirst("ESCALATE:".count)).trimmingCharacters(in: .whitespaces)
            return .escalate(value)
        }

        // Bare numbers are NOT auto-converted to SELECT — the reviewer must
        // explicitly use "SELECT: N". Bare numbers caused false injections when
        // the reviewer hallucinated selection prompts during normal Claude work.

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
