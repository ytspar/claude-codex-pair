import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const CLAUDE_DIR = path.join(os.homedir(), ".claude");
const SESSIONS_DIR = path.join(CLAUDE_DIR, "sessions");
const PROJECTS_DIR = path.join(CLAUDE_DIR, "projects");

export interface ActiveSession {
	sessionId: string;
	pid: number;
	cwd: string;
	transcriptPath: string;
	startedAt: number;
}

interface SessionIndex {
	pid: number;
	sessionId: string;
	cwd: string;
	startedAt: number;
	kind: string;
	entrypoint: string;
}

/**
 * Find active Claude Code sessions by reading ~/.claude/sessions/*.json index files.
 * Each file maps a PID to a session ID and working directory.
 */
export function findActiveSessions(): ActiveSession[] {
	if (!fs.existsSync(SESSIONS_DIR)) return [];

	const sessions: ActiveSession[] = [];

	try {
		const files = fs.readdirSync(SESSIONS_DIR).filter((f) => f.endsWith(".json"));

		for (const file of files) {
			try {
				const raw = fs.readFileSync(path.join(SESSIONS_DIR, file), "utf-8");
				const index: SessionIndex = JSON.parse(raw);
				const transcriptPath = findTranscriptPath(index.sessionId, index.cwd);

				if (transcriptPath) {
					sessions.push({
						sessionId: index.sessionId,
						pid: index.pid,
						cwd: index.cwd,
						transcriptPath,
						startedAt: index.startedAt,
					});
				}
			} catch {
				// Skip malformed files
			}
		}
	} catch {
		// Sessions dir not accessible
	}

	return sessions.sort((a, b) => b.startedAt - a.startedAt);
}

/**
 * Resolve the transcript JSONL path for a session.
 * Transcripts live at ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
 */
function findTranscriptPath(sessionId: string, cwd: string): string | null {
	// Claude encodes cwd by replacing / with - and stripping leading -
	const encoded = cwd.replace(/\//g, "-");
	const projectDir = path.join(PROJECTS_DIR, encoded);
	const transcriptFile = path.join(projectDir, `${sessionId}.jsonl`);

	if (fs.existsSync(transcriptFile)) return transcriptFile;

	// Fallback: scan all project dirs for this session
	if (fs.existsSync(PROJECTS_DIR)) {
		try {
			for (const dir of fs.readdirSync(PROJECTS_DIR, { withFileTypes: true })) {
				if (!dir.isDirectory()) continue;
				const candidate = path.join(PROJECTS_DIR, dir.name, `${sessionId}.jsonl`);
				if (fs.existsSync(candidate)) return candidate;
			}
		} catch {
			// ignore
		}
	}

	return null;
}

/**
 * Get the most recently started session.
 */
export function getMostRecentSession(): ActiveSession | null {
	const sessions = findActiveSessions();
	return sessions[0] ?? null;
}

/**
 * Check if a process is still running.
 */
export function isProcessAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}
