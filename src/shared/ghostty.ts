import { execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const execFile = promisify(execFileCb);

const DEBUG_LOG = path.join(os.homedir(), ".claude-codex-pair", "ghostty-debug.log");
const MAPPING_FILE = path.join(os.homedir(), ".claude-codex-pair", "ghostty-mapping.json");

function log(msg: string): void {
	try {
		fs.appendFileSync(DEBUG_LOG, `[${new Date().toISOString()}] ${msg}\n`);
	} catch { /* ignore */ }
}

export interface GhosttyWindow {
	index: number;
	title: string;
}

interface SessionWindowMapping {
	[sessionId: string]: { windowIndex: number; tty: string; updatedAt: string };
}

// ── Pre-flight Checks ───────────────────────────────────────────────────

export async function isGhosttyRunning(): Promise<boolean> {
	try {
		const { stdout } = await execFile("pgrep", ["-if", "ghostty"]);
		return stdout.trim().length > 0;
	} catch {
		return false;
	}
}

export async function hasAccessibilityAccess(): Promise<boolean> {
	try {
		await execFile("osascript", ["-e", `tell application "System Events" to get name of first process`]);
		return true;
	} catch {
		return false;
	}
}

// ── Session → TTY Resolution ────────────────────────────────────────────

/**
 * Get the TTY for a Claude session by its PID.
 * Chain: Claude PID → ps -o tty=
 */
export async function getTtyForPid(pid: number): Promise<string | null> {
	try {
		const { stdout } = await execFile("ps", ["-p", String(pid), "-o", "tty="]);
		const tty = stdout.trim();
		return tty && tty !== "??" ? tty : null;
	} catch {
		return null;
	}
}

/**
 * Get the Ghostty main process PID.
 */
async function getGhosttyPid(): Promise<number | null> {
	try {
		const { stdout } = await execFile("ps", ["aux"]);
		for (const line of stdout.split("\n")) {
			if (line.includes("Ghostty.app/Contents/MacOS/ghostty") && !line.includes("grep")) {
				const parts = line.trim().split(/\s+/);
				return Number.parseInt(parts[1], 10);
			}
		}
		return null;
	} catch {
		return null;
	}
}

/**
 * Build a TTY → Ghostty-child-PID mapping.
 * Each Ghostty window/tab has a login process as direct child.
 */
async function buildTtyToGhosttyChildMap(): Promise<Map<string, number>> {
	const ghosttyPid = await getGhosttyPid();
	if (!ghosttyPid) return new Map();

	try {
		const { stdout } = await execFile("pgrep", ["-P", String(ghosttyPid)]);
		const childPids = stdout.trim().split("\n").filter(Boolean).map(Number);
		const map = new Map<string, number>();

		for (const childPid of childPids) {
			try {
				const { stdout: ttyOut } = await execFile("ps", ["-p", String(childPid), "-o", "tty="]);
				const tty = ttyOut.trim();
				if (tty && tty !== "??") {
					map.set(tty, childPid);
				}
			} catch { /* skip */ }
		}

		return map;
	} catch {
		return new Map();
	}
}

// ── Window Discovery ────────────────────────────────────────────────────

export async function listGhosttyWindows(): Promise<GhosttyWindow[]> {
	if (!(await isGhosttyRunning())) return [];

	try {
		const { stdout } = await execFile("osascript", [
			"-e",
			`tell application "System Events"
				tell process "ghostty"
					set output to ""
					set windowCount to count of windows
					repeat with i from 1 to windowCount
						set w to window i
						set output to output & i & "|||" & name of w & linefeed
					end repeat
					return output
				end tell
			end tell`,
		]);

		return stdout.trim().split("\n").filter(Boolean).map((line) => {
			const sep = line.indexOf("|||");
			if (sep === -1) return null;
			return { index: Number.parseInt(line.slice(0, sep), 10), title: line.slice(sep + 3) };
		}).filter((w): w is GhosttyWindow => w !== null && !Number.isNaN(w.index));
	} catch (err) {
		log(`listWindows error: ${err}`);
		return [];
	}
}

// ── Session → Window Mapping ────────────────────────────────────────────

/**
 * Build a fresh mapping of session_id → window_index.
 *
 * Strategy:
 * 1. Get all Ghostty windows + all Claude sessions
 * 2. For each session, find its TTY
 * 3. For each window, check its focused TTY by matching Ghostty children
 * 4. Match session TTY to window
 *
 * Fallback: fuzzy title matching using session CWD project name
 */
export async function buildSessionMapping(
	sessions: Array<{ sessionId: string; pid: number; cwd: string; transcriptPath?: string }>,
): Promise<SessionWindowMapping> {
	const windows = await listGhosttyWindows();
	if (windows.length === 0) return {};

	const mapping: SessionWindowMapping = {};
	const claimedWindows = new Set<number>();

	for (const session of sessions) {
		const tty = await getTtyForPid(session.pid);
		if (!tty) continue;

		if (windows.length === 1) {
			mapping[session.sessionId] = { windowIndex: windows[0].index, tty, updatedAt: new Date().toISOString() };
			continue;
		}

		const available = windows.filter((w) => !claimedWindows.has(w.index));
		if (available.length === 0) break;

		const match = findBestWindowMatch(session, available);
		if (match) {
			mapping[session.sessionId] = { windowIndex: match.index, tty, updatedAt: new Date().toISOString() };
			claimedWindows.add(match.index);
		}
	}

	try { fs.writeFileSync(MAPPING_FILE, JSON.stringify(mapping, null, 2)); } catch { /* ignore */ }
	log(`buildSessionMapping: mapped ${Object.keys(mapping).length}/${sessions.length} sessions`);
	return mapping;
}

/**
 * Score each window against a session using multiple signals:
 * 1. Project name in title (strong)
 * 2. Task words from transcript in title (strong)
 * 3. CWD path segments in title (medium)
 */
function findBestWindowMatch(
	session: { sessionId: string; pid: number; cwd: string; transcriptPath?: string },
	windows: GhosttyWindow[],
): GhosttyWindow | null {
	const projectName = (session.cwd.split("/").pop() ?? "").toLowerCase();
	let bestWindow: GhosttyWindow | null = null;
	let bestScore = 0;

	// Collect search words from project name and task context
	const searchWords: string[] = [];
	// Project name words
	searchWords.push(...projectName.split(/[-_]/).filter((w) => w.length >= 3));
	// CWD path segments
	searchWords.push(...session.cwd.toLowerCase().split("/").filter((w) => w.length >= 3).slice(-3));

	// Task context from transcript (if available)
	if (session.transcriptPath) {
		try {
			const raw = fs.readFileSync(session.transcriptPath, "utf-8");
			// Get first user message for task keywords
			for (const line of raw.split("\n").slice(0, 20)) {
				try {
					const entry = JSON.parse(line);
					if (entry.type === "user") {
						const msg = typeof entry.message?.content === "string" ? entry.message.content : "";
						searchWords.push(...msg.toLowerCase().split(/\s+/).filter((w: string) => w.length >= 4).slice(0, 10));
						break;
					}
				} catch { /* skip */ }
			}
		} catch { /* skip */ }
	}

	for (const w of windows) {
		const titleLower = w.title.toLowerCase();
		let score = 0;

		// Exact project name match (highest signal)
		if (titleLower.includes(projectName) && projectName.length >= 3) score += 10;

		// Word matches
		for (const word of searchWords) {
			if (titleLower.includes(word)) score += 1;
		}

		if (score > bestScore) {
			bestScore = score;
			bestWindow = w;
		}
	}

	// Require minimum confidence
	return bestScore >= 2 ? bestWindow : null;
}

/**
 * Load cached mapping, refreshing if stale (>30s old).
 */
function loadMapping(): SessionWindowMapping {
	try {
		if (!fs.existsSync(MAPPING_FILE)) return {};
		return JSON.parse(fs.readFileSync(MAPPING_FILE, "utf-8"));
	} catch {
		return {};
	}
}

/**
 * Find the window index for a session, using cached mapping or building fresh.
 */
export async function findWindowForSession(
	sessionId: string,
	sessions: Array<{ sessionId: string; pid: number; cwd: string }>,
): Promise<{ windowIndex: number; tty: string } | null> {
	// Check cache first
	let mapping = loadMapping();
	const cached = mapping[sessionId];
	if (cached) {
		const age = Date.now() - new Date(cached.updatedAt).getTime();
		if (age < 60_000) return cached; // Fresh enough
	}

	// Rebuild mapping
	mapping = await buildSessionMapping(sessions);
	return mapping[sessionId] ?? null;
}

// ── Input Sending ───────────────────────────────────────────────────────

/**
 * Paste text into a Ghostty window via clipboard.
 *
 * Defenses:
 * - Pre-flight: Ghostty running + accessibility
 * - Save/restore clipboard (always, via finally)
 * - Verify focus before pasting
 * - Timeout on osascript
 * - Single-line sanitization
 */
export async function sendToWindow(windowIndex: number, text: string): Promise<boolean> {
	if (!(await isGhosttyRunning())) { log("send: Ghostty not running"); return false; }
	if (!(await hasAccessibilityAccess())) { log("send: no accessibility"); return false; }

	const sanitized = text.replace(/[\n\r]+/g, " ").trim();
	if (!sanitized) { log("send: empty text"); return false; }

	log(`send: window=${windowIndex} text="${sanitized.slice(0, 80)}..."`);

	const clipBackup = await getClipboard();

	try {
		await setClipboard(sanitized);

		await execFile("osascript", ["-e", [
			`tell application "System Events"`,
			`  tell process "ghostty"`,
			`    set frontmost to true`,
			`    perform action "AXRaise" of window ${windowIndex}`,
			`  end tell`,
			`end tell`,
			`delay 0.4`,
			`tell application "System Events"`,
			`  set fg to name of first process whose frontmost is true`,
			`  if fg is not "ghostty" then error "Focus lost to " & fg`,
			`end tell`,
			`tell application "System Events"`,
			`  keystroke "v" using command down`,
			`end tell`,
			`delay 0.3`,
			`tell application "System Events"`,
			`  key code 36`,
			`end tell`,
		].join("\n")], { timeout: 10_000 });

		log("send: success");
		return true;
	} catch (err) {
		log(`send error: ${err}`);
		return false;
	} finally {
		await new Promise((r) => setTimeout(r, 500));
		if (clipBackup !== null) await setClipboard(clipBackup);
	}
}

/**
 * Send text to a Claude session's Ghostty window.
 * Uses PID-based session mapping with title fallback.
 */
export async function sendInput(
	sessionId: string,
	text: string,
	sessions: Array<{ sessionId: string; pid: number; cwd: string }>,
	retries = 2,
): Promise<{ success: boolean; method: string; error?: string }> {
	for (let attempt = 0; attempt <= retries; attempt++) {
		if (attempt > 0) {
			log(`sendInput: retry ${attempt}/${retries}`);
			await new Promise((r) => setTimeout(r, 1500));
		}

		const target = await findWindowForSession(sessionId, sessions);
		if (!target) {
			log(`sendInput: no window for session ${sessionId} (attempt ${attempt})`);
			continue;
		}

		log(`sendInput: session=${sessionId} → window=${target.windowIndex} tty=${target.tty}`);

		const sent = await sendToWindow(target.windowIndex, text);
		if (sent) return { success: true, method: "ghostty-session-mapped" };
	}

	return {
		success: false,
		method: "ghostty-session-mapped",
		error: `Failed after ${retries + 1} attempts for session ${sessionId}`,
	};
}

// ── Clipboard ───────────────────────────────────────────────────────────

async function getClipboard(): Promise<string | null> {
	try {
		const { stdout } = await execFile("pbpaste");
		return stdout;
	} catch {
		return null;
	}
}

async function setClipboard(text: string): Promise<void> {
	try {
		const escaped = text.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n");
		await execFile("osascript", ["-e", `set the clipboard to "${escaped}"`]);
	} catch (err) {
		log(`setClipboard error: ${err}`);
	}
}
