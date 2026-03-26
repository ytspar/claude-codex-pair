import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { CodexDecision } from "../types.js";

const STATE_DIR = path.join(os.homedir(), ".claude-codex-pair", "state");

export interface SessionState {
	cycle: number;
	status: "idle" | "reviewing" | "responding" | "approved" | "feedback" | "error" | "claude-responding";
	lastUpdate: string;
	lastDecision?: CodexDecision;
	lastResponse?: string;
	/** The original task from the first user message */
	task?: string;
	/** Git diff stats from the last review */
	diffStats?: string;
	/** Claude's response after receiving Codex feedback */
	claudeResponse?: string;
}

function stateFile(sessionId: string): string {
	return path.join(STATE_DIR, `${sessionId}.json`);
}

function ensureStateDir(): void {
	if (!fs.existsSync(STATE_DIR)) {
		fs.mkdirSync(STATE_DIR, { recursive: true });
	}
}

export function readState(sessionId: string): SessionState | null {
	const file = stateFile(sessionId);
	if (!fs.existsSync(file)) return null;
	try {
		return JSON.parse(fs.readFileSync(file, "utf-8"));
	} catch {
		return null;
	}
}

export function writeState(sessionId: string, state: SessionState): void {
	ensureStateDir();
	fs.writeFileSync(stateFile(sessionId), JSON.stringify(state, null, 2) + "\n");
}

export function updateState(sessionId: string, partial: Partial<SessionState>): SessionState {
	const current = readState(sessionId) ?? {
		cycle: 0,
		status: "idle" as const,
		lastUpdate: new Date().toISOString(),
	};
	const updated: SessionState = {
		...current,
		...partial,
		lastUpdate: new Date().toISOString(),
	};
	writeState(sessionId, updated);
	return updated;
}

export function removeState(sessionId: string): void {
	const file = stateFile(sessionId);
	if (fs.existsSync(file)) fs.unlinkSync(file);
}

export function listActiveStates(): Array<{ sessionId: string; state: SessionState }> {
	ensureStateDir();
	const files = fs.readdirSync(STATE_DIR).filter((f) => f.endsWith(".json"));
	const results: Array<{ sessionId: string; state: SessionState }> = [];

	for (const f of files) {
		const sessionId = f.replace(".json", "");
		const state = readState(sessionId);
		if (state) results.push({ sessionId, state });
	}

	return results;
}
