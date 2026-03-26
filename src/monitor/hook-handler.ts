#!/usr/bin/env node
/**
 * Hook handler — standalone script spawned by Claude Code's Stop hook.
 *
 * Two modes:
 *   1. REVIEW — Claude finished working. Codex checks if the task is complete.
 *   2. RESPOND — Claude asked a question / wants input. Codex answers as the human.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { callCodex } from "../codex/client.js";
import { buildReviewPrompt } from "../codex/prompt-builder.js";
import { loadConfig } from "../shared/config.js";
import { gitDiff } from "../shared/git.js";
import { getConversationContext, getTaskContext } from "./transcript.js";
import { logInteraction, readSessionLog } from "../report/logger.js";
import { readState, updateState } from "./state.js";
import { sendInput as sendInputGhostty } from "../shared/ghostty.js";
import { isPairTerminalRunning, sendInputViaPairTerminal } from "../shared/pair-terminal.js";
import { findActiveSessions } from "./session-watcher.js";
import type { HookInput, HookResponse } from "../types.js";

function debugLog(label: string, data: unknown): void {
	const logFile = path.join(os.homedir(), ".claude-codex-pair", "hook-debug.log");
	const entry = `[${new Date().toISOString()}] ${label}: ${JSON.stringify(data)}\n`;
	try { fs.appendFileSync(logFile, entry); } catch { /* ignore */ }
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

	// Session filter — skip if not targeted
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
		exit(approve("Max review cycles reached — auto-approving"));
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

		// Build previous feedback history so Codex can track progress
		const previousEntries = readSessionLog(sessionId);
		const previousFeedback = previousEntries
			.filter((e) => e.codexDecision === "FEEDBACK")
			.slice(-3)
			.map((e) => `[Cycle ${e.cycle}] ${e.codexResponse}`)
			.join("\n\n---\n\n");

		// Always send both review context AND last message — Codex decides what to do
		const reviewPrompt = buildReviewPrompt({ cwd, diffResult, sessionContext, previousFeedback: previousFeedback || undefined });
		const prompt = lastMessage
			? `${reviewPrompt}\n\nCLAUDE'S LAST MESSAGE (it may be asking a question — if so, answer it instead of reviewing):\n${lastMessage}`
			: reviewPrompt;

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

		// Unified response handling — Codex decides what to do
		let hookResponse: HookResponse;
		const stateBase = { cycle, task, diffStats: diffResult.stat, claudeResponse: undefined };

		if (result.decision === "APPROVE") {
			hookResponse = approve(result.response);
			updateState(sessionId, { ...stateBase, status: "approved", lastDecision: "APPROVE", lastResponse: result.response });
		} else {
			// Strip verdict line and frame as instruction
			const issues = result.response
				.split("\n")
				.filter((l) => l.trim() && !l.trim().match(/^(FEEDBACK|CONTEXT)$/))
				.join("\n");
			const instruction = `You are not done yet. Fix the following issues before stopping:\n\n${issues}\n\nDo not stop until all of the above are addressed.`;

			// Try input injection: pair-terminal → Ghostty → hook block fallback
			let inputSent = false;

			// 1. Try pair-terminal (native app with PTY control)
			if (await isPairTerminalRunning()) {
				const ptResult = await sendInputViaPairTerminal(sessionId, result.response);
				debugLog("PAIR_TERMINAL", ptResult);
				inputSent = ptResult.success;
			}

			// 2. Try Ghostty (System Events clipboard paste)
			if (!inputSent) {
				const activeSessions = findActiveSessions();
				const ghosttyResult = await sendInputGhostty(sessionId, result.response, activeSessions);
				debugLog("GHOSTTY", ghosttyResult);
				inputSent = ghosttyResult.success;
			}

			if (inputSent) {
				hookResponse = approve(`[Ghostty] Sent feedback`);
				updateState(sessionId, {
					...stateBase,
					status: "feedback",
					lastDecision: result.decision,
					lastResponse: `[via Ghostty] ${result.response}`,
				});
			} else {
				// Fall back to hook block
				hookResponse = block(instruction);
				updateState(sessionId, {
					...stateBase,
					status: "feedback",
					lastDecision: result.decision,
					lastResponse: result.response,
				});
			}
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

main().catch((err) => {
	process.stdout.write(JSON.stringify(approve(`Fatal: ${err}`)));
	process.exit(0);
});
