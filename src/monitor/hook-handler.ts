#!/usr/bin/env node
/**
 * Hook handler  - standalone script spawned by Claude Code's Stop hook.
 *
 * Two modes:
 *   1. REVIEW  - Claude finished working. Codex checks if the task is complete.
 *   2. RESPOND  - Claude asked a question / wants input. Codex answers via hook block.
 *
 * All Codex responses are delivered via the hook block mechanism (Claude sees them
 * as system-level messages). We never inject text into the terminal — the user
 * must remain in control of the prompt at all times.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { callCodex } from "../codex/client.js";
import { buildReviewPrompt, buildRespondPrompt } from "../codex/prompt-builder.js";
import { loadConfig } from "../shared/config.js";
import { gitDiff } from "../shared/git.js";
import { getConversationContext, getTaskContext } from "./transcript.js";
import { logInteraction, readSessionLog } from "../report/logger.js";
import { readState, updateState } from "./state.js";
import type { HookInput, HookResponse } from "../types.js";

function debugLog(label: string, data: unknown): void {
	const logFile = path.join(os.homedir(), ".claude-codex-pair", "hook-debug.log");
	const entry = `[${new Date().toISOString()}] ${label}: ${JSON.stringify(data)}\n`;
	try {
		fs.appendFileSync(logFile, entry, { mode: 0o600 });
	} catch { /* ignore */ }
}

async function main(): Promise<void> {
	let input: HookInput;
	try {
		const stdin = await readStdin();
		input = JSON.parse(stdin);
	} catch {
		exit(approve());
		return;
	}

	debugLog("HOOK_INPUT", {
		session_id: input.session_id,
		stop_hook_active: input.stop_hook_active,
		has_last_assistant_message: !!input.last_assistant_message,
		last_assistant_message_preview: input.last_assistant_message?.slice(0, 200),
		all_keys: Object.keys(input),
	});

	const { session_id: sessionId, transcript_path: transcriptPath, cwd } = input;
	const lastMessage = input.last_assistant_message ?? "";
	const config = loadConfig();

	// Session filter  - skip if not targeted
	if (config.targetSessions && config.targetSessions.length > 0) {
		const projectName = cwd.split("/").pop() ?? "";
		const matches = config.targetSessions.some(
			(t) => sessionId.startsWith(t) || projectName.toLowerCase().includes(t.toLowerCase()),
		);
		if (!matches) {
			debugLog("SKIP", { sessionId, cwd, reason: "not in targetSessions" });
			exit(approve());
			return;
		}
	}

	const currentState = readState(sessionId);
	const previousCycle = currentState?.cycle ?? 0;

	// Detect if Claude is continuing after our previous block (using our own state, not stop_hook_active)
	const previouslyBlocked = currentState?.status === "feedback" || currentState?.status === "reviewing";
	if (previouslyBlocked && lastMessage) {
		updateState(sessionId, {
			...currentState,
			status: "claude-responding",
			claudeResponse: lastMessage.length > 500 ? lastMessage.slice(0, 500) + "…" : lastMessage,
		});
	}

	const cycle = previousCycle + 1;

	if (cycle > config.maxCycles) {
		updateState(sessionId, {
			cycle,
			status: "approved",
			lastDecision: "APPROVE",
			lastResponse: "Max cycles reached",
		});
		exit(approve("Max review cycles reached  - auto-approving"));
		return;
	}

	const task = getTaskContext(transcriptPath, 200);
	debugLog("CYCLE", { cycle, lastMessageLen: lastMessage.length, lastMessagePreview: lastMessage.slice(0, 150) });

	updateState(sessionId, {
		cycle,
		status: "reviewing",
		task,
		claudeResponse: currentState?.claudeResponse,
	});

	try {
		const [sessionContext, diffResult] = await Promise.all([
			Promise.resolve(getConversationContext(transcriptPath)),
			gitDiff(cwd),
		]);

		// Detect if Claude is asking a question vs reporting completion
		const isQuestion = lastMessage && looksLikeQuestion(lastMessage);

		// Build previous feedback history so Codex can track progress
		const previousEntries = readSessionLog(sessionId);
		const previousFeedback = previousEntries
			.filter((e) => e.codexDecision === "FEEDBACK")
			.slice(-3)
			.map((e) => `[Cycle ${e.cycle}] ${e.codexResponse}`)
			.join("\n\n---\n\n");

		// If Claude is asking a question, use the respond template (direct answer, no verdict parsing)
		// Otherwise use the review template (completion check with APPROVE/FEEDBACK verdict)
		let prompt: string;
		if (isQuestion) {
			prompt = buildRespondPrompt({ cwd, sessionContext, lastMessage });
		} else {
			const reviewPrompt = buildReviewPrompt({ cwd, diffResult, sessionContext, previousFeedback: previousFeedback || undefined });
			prompt = lastMessage
				? `${reviewPrompt}\n\nCLAUDE'S LAST MESSAGE:\n${lastMessage}`
				: reviewPrompt;
		}

		const result = await callCodex({
			prompt,
			cwd,
			timeout: config.codexTimeout,
			model: config.codexModel,
			onProgress: (text) => {
				updateState(sessionId, {
					cycle,
					status: "reviewing",
					task,
					diffStats: diffResult.stat || undefined,
					lastResponse: text,
					claudeResponse: currentState?.claudeResponse,
				});
			},
		});

		let hookResponse: HookResponse;
		const stateBase = { cycle, task, diffStats: diffResult.stat, claudeResponse: undefined };

		if (isQuestion) {
			// Question mode: always block with the answer, regardless of parsed verdict.
			// parseCodexResponse may misclassify plain answers like "Yes" as APPROVE.
			const answer = result.response.trim();
			hookResponse = block(answer);
			updateState(sessionId, { ...stateBase, status: "feedback", lastDecision: "FEEDBACK", lastResponse: answer });
		} else if (result.decision === "APPROVE") {
			hookResponse = approve(result.response);
			updateState(sessionId, { ...stateBase, status: "approved", lastDecision: "APPROVE", lastResponse: result.response });
		} else {
			const response = result.response.trim();
			const message = `You are not done yet. Fix the following issues before stopping:\n\n${stripVerdictLine(response)}\n\nDo not stop until all of the above are addressed.`;
			hookResponse = block(message);
			updateState(sessionId, { ...stateBase, status: "feedback", lastDecision: "FEEDBACK", lastResponse: response });
		}

		logInteraction({
			timestamp: new Date().toISOString(),
			sessionId,
			cycle,
			claudeSummary: sessionContext,
			gitDiffStats: diffResult.stat,
			codexDecision: result.decision,
			codexResponse: result.response,
			hookResponse,
			codexTokens: result.tokensUsed,
			codexDurationMs: result.durationMs,
		});

		exit(hookResponse);
	} catch (err) {
		const message = err instanceof Error ? err.message : String(err);
		updateState(sessionId, { cycle, status: "error", lastResponse: message });
		exit(approve(`Codex review error (auto-approving): ${message}`));
	}
}


function approve(reason?: string): HookResponse {
	return { decision: "approve", ...(reason ? { reason } : {}) };
}

function block(reason: string): HookResponse {
	return { decision: "block", reason };
}

function exit(response: HookResponse): void {
	process.stdout.write(JSON.stringify(response));
	process.exit(0);
}

function readStdin(): Promise<string> {
	return new Promise((resolve, reject) => {
		let data = "";
		process.stdin.setEncoding("utf-8");
		process.stdin.on("data", (chunk) => (data += chunk));
		process.stdin.on("end", () => resolve(data));
		process.stdin.on("error", reject);
		if (process.stdin.readableEnded) resolve(data);
	});
}

/** Strip verdict lines (FEEDBACK, CONTEXT) from Codex response. */
function stripVerdictLine(text: string): string {
	return text
		.split("\n")
		.filter((l) => l.trim() && !l.trim().match(/^(FEEDBACK|CONTEXT)$/))
		.join("\n");
}

/**
 * Detect if Claude's last message is asking a question rather than reporting completion.
 * Questions get the respond template (direct answer); non-questions get the review template.
 */
function looksLikeQuestion(message: string): boolean {
	const lower = message.toLowerCase();
	// Explicit question patterns
	if (/\?\s*$/.test(message.trim())) return true;
	if (/\bshould (i|we)\b/.test(lower)) return true;
	if (/\bwould you like\b/.test(lower)) return true;
	if (/\bdo you want\b/.test(lower)) return true;
	if (/\bcan (i|we)\b/.test(lower)) return true;
	if (/\bpermission to\b/.test(lower)) return true;
	if (/\bplease (confirm|choose|select|decide)\b/.test(lower)) return true;
	if (/\bwhich (option|approach|one)\b/.test(lower)) return true;
	// Numbered option lists (Claude presenting choices)
	if (/^\s*[1-3][.)]\s/m.test(message) && /\b(option|choice|approach)\b/i.test(message)) return true;
	return false;
}

main().catch((err) => {
	process.stdout.write(JSON.stringify(approve(`Fatal: ${err}`)));
	process.exit(0);
});
