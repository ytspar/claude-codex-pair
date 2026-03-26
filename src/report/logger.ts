import fs from "node:fs";
import path from "node:path";
import { resolveLogDir, loadConfig } from "../shared/config.js";
import type { InteractionEntry } from "../types.js";

/**
 * Append an interaction entry to the session's JSONL log file.
 */
export function logInteraction(entry: InteractionEntry): string {
	const config = loadConfig();
	const logDir = resolveLogDir(config);
	const logFile = path.join(logDir, `${entry.sessionId}.jsonl`);

	fs.appendFileSync(logFile, JSON.stringify(entry) + "\n");
	return logFile;
}

/**
 * Read all interaction entries for a session.
 */
export function readSessionLog(sessionId: string): InteractionEntry[] {
	const config = loadConfig();
	const logDir = resolveLogDir(config);
	const logFile = path.join(logDir, `${sessionId}.jsonl`);

	if (!fs.existsSync(logFile)) return [];

	return fs
		.readFileSync(logFile, "utf-8")
		.trim()
		.split("\n")
		.filter(Boolean)
		.map((line) => JSON.parse(line) as InteractionEntry);
}

/**
 * List all session IDs that have log files.
 */
export function listSessions(): string[] {
	const config = loadConfig();
	const logDir = resolveLogDir(config);

	if (!fs.existsSync(logDir)) return [];

	return fs
		.readdirSync(logDir)
		.filter((f) => f.endsWith(".jsonl"))
		.map((f) => f.replace(".jsonl", ""));
}
