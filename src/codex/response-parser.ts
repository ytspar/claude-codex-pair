import type { CodexDecision, CodexReviewResult } from "../types.js";

/**
 * Parse raw Codex stdout into a structured review result.
 * Expects the first non-empty line to be one of: APPROVE, FEEDBACK, CONTEXT.
 */
export function parseCodexResponse(raw: string): Omit<CodexReviewResult, "durationMs"> {
	const trimmed = raw.trim();
	if (!trimmed) {
		return { decision: "APPROVE", response: "Empty response from Codex (auto-approving)" };
	}

	const lines = trimmed.split("\n");
	const firstLine = lines[0].trim().toUpperCase();

	let decision: CodexDecision;
	if (firstLine.startsWith("APPROVE")) {
		decision = "APPROVE";
	} else if (firstLine.startsWith("FEEDBACK")) {
		decision = "FEEDBACK";
	} else if (firstLine.startsWith("CONTEXT")) {
		decision = "CONTEXT";
	} else {
		// If no clear verdict, look for keywords in the full response
		decision = inferDecision(trimmed);
	}

	return { decision, response: trimmed };
}

function inferDecision(text: string): CodexDecision {
	const upper = text.toUpperCase();
	if (upper.includes("FEEDBACK") || upper.includes("ISSUE") || upper.includes("FIX")) {
		return "FEEDBACK";
	}
	if (upper.includes("CONTEXT") || upper.includes("MISSING") || upper.includes("NEED MORE")) {
		return "CONTEXT";
	}
	return "APPROVE";
}
