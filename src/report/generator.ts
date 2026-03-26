import type { InteractionEntry } from "../types.js";
import { readSessionLog } from "./logger.js";

/**
 * Generate a markdown report for a session.
 */
export function generateReport(sessionId: string): string {
	const entries = readSessionLog(sessionId);
	if (entries.length === 0) {
		return `# Session Report: ${sessionId}\n\nNo interactions recorded.`;
	}

	const lines: string[] = [
		`# Session Report: ${sessionId}`,
		"",
		`**Total cycles:** ${entries.length}`,
		`**Started:** ${entries[0].timestamp}`,
		`**Ended:** ${entries[entries.length - 1].timestamp}`,
		"",
		"## Summary",
		"",
		formatSummary(entries),
		"",
		"## Interactions",
		"",
	];

	for (const entry of entries) {
		lines.push(formatEntry(entry));
	}

	return lines.join("\n");
}

function formatSummary(entries: InteractionEntry[]): string {
	const approvals = entries.filter((e) => e.codexDecision === "APPROVE").length;
	const feedbacks = entries.filter((e) => e.codexDecision === "FEEDBACK").length;
	const contexts = entries.filter((e) => e.codexDecision === "CONTEXT").length;
	const totalDuration = entries.reduce((sum, e) => sum + e.codexDurationMs, 0);

	return [
		`| Metric | Value |`,
		`|--------|-------|`,
		`| Approvals | ${approvals} |`,
		`| Feedback rounds | ${feedbacks} |`,
		`| Context requests | ${contexts} |`,
		`| Total Codex time | ${(totalDuration / 1000).toFixed(1)}s |`,
	].join("\n");
}

function formatEntry(entry: InteractionEntry): string {
	return [
		`### Cycle ${entry.cycle}`,
		"",
		`**Time:** ${entry.timestamp}`,
		`**Decision:** ${entry.codexDecision}`,
		`**Git diff:** ${entry.gitDiffStats}`,
		"",
		"**Claude's actions:**",
		entry.claudeSummary,
		"",
		"**Codex response:**",
		entry.codexResponse,
		"",
		"---",
		"",
	].join("\n");
}
