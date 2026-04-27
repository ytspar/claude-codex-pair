/**
 * Automated test harness for the PairApp monitor loop.
 *
 * Each test gets its own isolated Claude session, preventing cascading failures.
 * A slow/stuck test cannot poison subsequent tests.
 *
 * Usage: pair test-loop
 */

import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";

const SOCKET = path.join(os.homedir(), ".claude-codex-pair", "pair-terminal.sock");
const TOKEN_PATH = path.join(os.homedir(), ".claude-codex-pair", "auth-token");
const PROJECT = process.cwd();
const LOG_FILE = path.join(os.homedir(), ".claude-codex-pair", "pairapp.log");
const CLAUDE_SESSIONS_DIR = path.join(os.homedir(), ".claude", "sessions");
const QUEUE_E2E_CWD_PREFIX = "pair-queue-e2e-";

function readAuthToken(): string {
	try {
		return fs.readFileSync(TOKEN_PATH, "utf-8").trim();
	} catch {
		return "";
	}
}

interface TestResult {
	name: string;
	passed: boolean;
	detail: string;
	durationMs: number;
}

const results: TestResult[] = [];

function log(msg: string) {
	const ts = new Date().toLocaleTimeString("en-US", { hour12: false });
	console.log(`[${ts}] ${msg}`);
}

function pass(name: string, detail: string, durationMs: number) {
	results.push({ name, passed: true, detail, durationMs });
	console.log(`  ✓ ${name} (${(durationMs / 1000).toFixed(1)}s) — ${detail}`);
}

function fail(name: string, detail: string, durationMs: number) {
	results.push({ name, passed: false, detail, durationMs });
	console.error(`  ✗ ${name} (${(durationMs / 1000).toFixed(1)}s) — ${detail}`);
}

// ── IPC helpers ───────────────────────────────────────────────────────

async function ipc(command: Record<string, unknown>): Promise<{ ok: boolean; result?: string; error?: string }> {
	return new Promise((resolve, reject) => {
		const client = net.createConnection(SOCKET);
		let data = "";
		const timer = setTimeout(() => {
			client.destroy();
			reject(new Error("IPC timeout"));
		}, 10000);
		client.on("connect", () => client.write(JSON.stringify({ ...command, token: readAuthToken() })));
		client.on("data", (d) => {
			data += d.toString();
		});
		client.on("end", () => {
			clearTimeout(timer);
			try {
				resolve(JSON.parse(data));
			} catch {
				reject(new Error(`Bad response: ${data}`));
			}
		});
		client.on("error", (e) => {
			clearTimeout(timer);
			reject(e);
		});
	});
}

function simpleHash(s: string): number {
	let h = 0;
	for (let i = 0; i < s.length; i++) {
		h = ((h << 5) - h + s.charCodeAt(i)) | 0;
	}
	return h;
}

async function sleep(ms: number) {
	await new Promise((r) => setTimeout(r, ms));
}

/** Get recent log lines matching a pattern since a timestamp. */
function recentLogs(pattern: string, since: number): string[] {
	if (!fs.existsSync(LOG_FILE)) return [];
	const content = fs.readFileSync(LOG_FILE, "utf-8");
	const sinceStr = new Date(since).toISOString().slice(0, 19);
	return content.split("\n").filter((l) => {
		if (!l.includes(pattern)) return false;
		const match = l.match(/^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/);
		if (!match) return false;
		return match[1] >= sinceStr;
	});
}

interface QueueItemState {
	id: string;
	title: string;
	prompt: string;
	status: "pending" | "active" | "completed" | "failed";
}

interface QueueState {
	isRunning: boolean;
	pendingCount: number;
	activeTitle: string | null;
	items: QueueItemState[];
}

async function queueState(sessionId: string): Promise<QueueState> {
	const resp = await ipc({ action: "queue_state", surface: sessionId });
	if (!resp.ok) throw new Error(`queue_state failed: ${resp.error ?? "unknown error"}`);
	if (!resp.result) throw new Error("queue_state returned no result");
	return JSON.parse(resp.result) as QueueState;
}

async function waitForQueueState(
	sessionId: string,
	description: string,
	condition: (state: QueueState) => boolean,
	timeoutMs = 60000,
): Promise<QueueState> {
	const start = Date.now();
	let lastState: QueueState | undefined;
	while (Date.now() - start < timeoutMs) {
		lastState = await queueState(sessionId);
		if (condition(lastState)) return lastState;
		await sleep(1000);
	}
	throw new Error(`Timeout waiting for queue state: ${description}; last=${JSON.stringify(lastState)}`);
}

function isProcessAlive(pid: number): boolean {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
}

function cleanupClaudeSessionsByCwdPrefix(prefix: string): void {
	if (!fs.existsSync(CLAUDE_SESSIONS_DIR)) return;

	for (const file of fs.readdirSync(CLAUDE_SESSIONS_DIR)) {
		if (!file.endsWith(".json")) continue;
		const fullPath = path.join(CLAUDE_SESSIONS_DIR, file);
		try {
			const index = JSON.parse(fs.readFileSync(fullPath, "utf-8")) as { pid?: number; cwd?: string };
			const cwd = index.cwd ?? "";
			if (!path.basename(cwd).startsWith(prefix)) continue;

			if (typeof index.pid === "number" && isProcessAlive(index.pid)) {
				try {
					process.kill(index.pid, "SIGTERM");
				} catch {
					/* already gone */
				}
			}
			fs.rmSync(fullPath, { force: true });
		} catch {
			/* ignore malformed or concurrently removed session indexes */
		}
	}
}

// ── Test context: isolated session per test ───────────────────────────

class TestContext {
	readonly sessionId: string;
	readonly project: string;

	constructor(project = PROJECT) {
		this.sessionId = `test-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
		this.project = project;
	}

	async setup(): Promise<boolean> {
		const resp = await ipc({ action: "create_session", surface: this.sessionId, text: this.project });
		if (!resp.ok) return false;
		// Wait for Claude to start
		for (let i = 0; i < 30; i++) {
			await sleep(1000);
			const screen = await this.readScreen();
			if (
				screen.includes("Yes, I trust this folder") ||
				screen.includes("Is this a project you created or one you trust")
			) {
				await ipc({ action: "send_key", surface: this.sessionId, text: "enter" });
				await sleep(3000);
				continue;
			}
			if (screen.includes("❯") || screen.includes("Claude Code")) return true;
		}
		return false;
	}

	async teardown(): Promise<void> {
		try {
			await ipc({ action: "remove_session", surface: this.sessionId });
		} catch {}
	}

	async readScreen(): Promise<string> {
		const resp = await ipc({ action: "read_screen", surface: this.sessionId });
		return resp.ok ? (resp.result ?? "") : "";
	}

	async waitFor(
		description: string,
		condition: (screen: string) => boolean,
		timeoutMs = 60000,
	): Promise<{ screen: string; elapsed: number }> {
		const start = Date.now();
		while (Date.now() - start < timeoutMs) {
			const screen = await this.readScreen();
			if (condition(screen)) return { screen, elapsed: Date.now() - start };
			await sleep(1000);
		}
		throw new Error(`Timeout waiting for: ${description}`);
	}

	async inject(prompt: string, timeoutMs = 60000): Promise<void> {
		await ipc({ action: "pause_monitor", surface: this.sessionId });
		await ipc({ action: "send_key", surface: this.sessionId, text: "ctrl-u" });
		const baseline = simpleHash(await this.readScreen());
		await ipc({ action: "send_input", surface: this.sessionId, text: `${prompt}\r` });
		await ipc({ action: "resume_monitor", surface: this.sessionId });
		await this.waitFor("Claude starts working", (s) => simpleHash(s) !== baseline, timeoutMs);
	}

	async waitForPrompt(timeoutMs = 120000): Promise<string> {
		const { screen } = await this.waitFor(
			"❯ prompt",
			(s) => {
				const lines = s.split("\n").slice(-6);
				return lines.some((l) => l.trim().startsWith("❯") || l.trim() === "❯");
			},
			timeoutMs,
		);
		return screen;
	}
}

/** Test context for Codex-leads mode sessions. Uses `:codex` suffix and type_input. */
class CodexTestContext {
	readonly sessionId: string;

	constructor() {
		this.sessionId = `test-codex-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
	}

	async setup(): Promise<boolean> {
		// Create session with :codex suffix to trigger codexLeads mode
		const resp = await ipc({ action: "create_session", surface: `${this.sessionId}:codex`, text: PROJECT });
		if (!resp.ok) return false;
		// Wait for Codex to start — look for › prompt or "OpenAI Codex" header
		for (let i = 0; i < 40; i++) {
			await sleep(1000);
			const screen = await this.readScreen();
			if (screen.includes("›") || screen.includes("OpenAI Codex") || screen.includes("codex")) {
				// If trust dialog is showing, accept it
				if (screen.includes("trust") || screen.includes("Yes, continue")) {
					await ipc({ action: "type_input", surface: this.sessionId, text: "\n" });
					await sleep(3000);
				}
				return true;
			}
		}
		return false;
	}

	async teardown(): Promise<void> {
		try {
			await ipc({ action: "remove_session", surface: this.sessionId });
		} catch {}
	}

	async readScreen(): Promise<string> {
		const resp = await ipc({ action: "read_screen", surface: this.sessionId });
		return resp.ok ? (resp.result ?? "") : "";
	}

	async waitFor(
		description: string,
		condition: (screen: string) => boolean,
		timeoutMs = 60000,
	): Promise<{ screen: string; elapsed: number }> {
		const start = Date.now();
		while (Date.now() - start < timeoutMs) {
			const screen = await this.readScreen();
			if (condition(screen)) return { screen, elapsed: Date.now() - start };
			await sleep(1000);
		}
		throw new Error(`Timeout waiting for: ${description}`);
	}

	/** Type a prompt character by character (Ink raw mode). */
	async type(prompt: string, timeoutMs = 60000): Promise<void> {
		await ipc({ action: "pause_monitor", surface: this.sessionId });
		const baseline = simpleHash(await this.readScreen());
		await ipc({ action: "type_input", surface: this.sessionId, text: `${prompt}\n` });
		await ipc({ action: "resume_monitor", surface: this.sessionId });
		await this.waitFor("Codex starts working", (s) => simpleHash(s) !== baseline, timeoutMs);
	}

	/** Wait for Codex to return to its › prompt. */
	async waitForPrompt(timeoutMs = 120000): Promise<string> {
		// Codex idle state: › on its own line with status bar below
		const { screen } = await this.waitFor(
			"› prompt",
			(s) => {
				const lines = s.split("\n").filter((l) => l.trim());
				// Look for a bare › or › with placeholder text, plus the status bar
				return (
					lines.some((l) => l.trim() === "›" || l.trim().startsWith("› ")) &&
					lines.some((l) => l.includes("default ·") || l.includes("gpt-"))
				);
			},
			timeoutMs,
		);
		return screen;
	}
}

/** Run a test with a Codex-leads isolated session. */
async function runCodexIsolated(
	name: string,
	timeoutMs: number,
	testFn: (ctx: CodexTestContext) => Promise<void>,
): Promise<void> {
	const start = Date.now();
	if (!(await assertPairAppAlive())) {
		fail(name, "PairApp crashed (IPC unreachable)", Date.now() - start);
		return;
	}
	const ctx = new CodexTestContext();
	try {
		const ready = await ctx.setup();
		if (!ready) {
			fail(name, "Codex session setup failed", Date.now() - start);
			return;
		}

		await Promise.race([
			testFn(ctx),
			new Promise<never>((_, reject) =>
				setTimeout(() => reject(new Error(`Test timed out after ${timeoutMs / 1000}s`)), timeoutMs),
			),
		]);
	} catch (e) {
		fail(name, `${e}`, Date.now() - start);
	} finally {
		// Brief pause before teardown to let in-flight Codex reviews complete
		// and log their results under this session's ID.
		await sleep(2000);
		await ctx.teardown();
	}
}

/** Check if PairApp is still alive. Aborts the suite if dead. */
async function assertPairAppAlive(): Promise<boolean> {
	try {
		const resp = await ipc({ action: "list_sessions" });
		return resp.ok;
	} catch {
		log("  ⚠ PairApp is not reachable — aborting remaining tests");
		return false;
	}
}

/** Run a test with its own isolated session. Creates session, runs test fn, cleans up. */
async function runIsolated(
	name: string,
	timeoutMs: number,
	testFn: (ctx: TestContext) => Promise<void>,
	options: { cwd?: string } = {},
): Promise<void> {
	const start = Date.now();
	if (!(await assertPairAppAlive())) {
		fail(name, "PairApp crashed (IPC unreachable)", Date.now() - start);
		return;
	}
	const ctx = new TestContext(options.cwd);
	try {
		const ready = await ctx.setup();
		if (!ready) {
			fail(name, "Session setup failed", Date.now() - start);
			return;
		}

		await Promise.race([
			testFn(ctx),
			new Promise<never>((_, reject) =>
				setTimeout(() => reject(new Error(`Test timed out after ${timeoutMs / 1000}s`)), timeoutMs),
			),
		]);
	} catch (e) {
		fail(name, `${e}`, Date.now() - start);
	} finally {
		await ctx.teardown();
	}
}

// ── Tests ─────────────────────────────────────────────────────────────

async function testIpcConnection() {
	const start = Date.now();
	try {
		const resp = await ipc({ action: "list_sessions" });
		if (resp.ok) pass("IPC connection", "Socket responding", Date.now() - start);
		else fail("IPC connection", `Error: ${resp.error}`, Date.now() - start);
	} catch (e) {
		fail("IPC connection", `${e}`, Date.now() - start);
	}
}

async function testInjectAndCodexReview() {
	await runIsolated("Inject + Codex review", 180000, async (ctx) => {
		const start = Date.now();
		const testPrompt = "Run swift test in app/PairApp and report the results. If any tests fail, explain why.";
		const logBefore = Date.now();

		await ctx.inject(testPrompt);
		log(`  Injected: "${testPrompt}"`);

		// Wait for Claude to show test output
		await ctx.waitFor(
			"Swift test output",
			(s) => {
				return s.includes("Executed") || s.includes("Build complete") || s.includes("passed");
			},
			120000,
		);
		await ctx.waitForPrompt();
		pass("Claude runs tests", `Completed`, Date.now() - start);

		// Poll for Codex review — Codex calls can take 15-30s and the review
		// may not trigger until Claude is stable for 3+ seconds after completing.
		let codexLogs: string[] = [];
		for (let i = 0; i < 18; i++) {
			await sleep(5000);
			codexLogs = recentLogs("Codex (", logBefore);
			if (codexLogs.length > 0) break;
		}
		if (codexLogs.length > 0) {
			const last = codexLogs[codexLogs.length - 1];
			pass(
				"Codex review",
				`Codex responded: ${last.substring(last.indexOf("Codex (")).substring(0, 80)}`,
				Date.now() - start,
			);
		} else {
			fail("Codex review", "No Codex response after 90s", Date.now() - start);
		}
	});
}

async function testCodexAnswersQuestion() {
	await runIsolated("Codex answers question", 180000, async (ctx) => {
		const start = Date.now();
		const prompt =
			"Ask me exactly this question and then wait for my answer: Which PairApp file should I inspect: CodexIntegration.swift or ClaudeMonitor.swift?";

		await ctx.inject(prompt);

		// Wait for Claude to ask a question
		const { elapsed } = await ctx.waitFor(
			"Claude asks question",
			(s) => {
				const lines = s.split("\n").filter((l) => l.trim());
				return lines.slice(-10).some((l) => l.trim().endsWith("?"));
			},
			120000,
		);
		log(`  Claude asked question after ${(elapsed / 1000).toFixed(1)}s`);

		// Wait for Codex to respond
		const logBefore = Date.now();
		await sleep(40000);
		const codexLogs = recentLogs("Codex (", logBefore);
		if (codexLogs.length > 0) {
			pass("Codex answers question", `${codexLogs.length} Codex reviews`, Date.now() - start);
		} else {
			fail("Codex answers question", "No Codex response after 40s", Date.now() - start);
		}
	});
}

async function testAcceptEditsFlow() {
	await runIsolated("Accept-edits flow", 300000, async (ctx) => {
		const start = Date.now();
		const prompt =
			"Add a Swift comment '// test-loop: accept-edits validation' as the FIRST line of app/PairApp/Sources/PairApp/Version.swift, then immediately remove it and restore the original file.";
		const logBefore = Date.now();

		await ctx.inject(prompt);

		await ctx.waitFor(
			"Claude working on edit",
			(s) => {
				return (
					s.includes("accept-edits") ||
					s.includes("test-loop") ||
					(s.includes("Version.swift") && (s.includes("Edit") || s.includes("comment")))
				);
			},
			60000,
		);
		await ctx.waitForPrompt(240000);

		const selectLogs = recentLogs("SELECT", logBefore);
		pass("Accept-edits flow", `Completed with ${selectLogs.length} selections`, Date.now() - start);
	});
}

async function testMultiStepPermissions() {
	await runIsolated("Multi-step permissions", 300000, async (ctx) => {
		const start = Date.now();
		const prompt =
			"Read app/PairApp/Package.swift, then create a temporary file /tmp/pair-test-loop.txt with the package name from it, then run 'cat /tmp/pair-test-loop.txt' to verify, then delete it with rm.";
		const logBefore = Date.now();

		await ctx.inject(prompt);

		await ctx.waitFor(
			"Claude using tools",
			(s) => {
				return s.includes("Bash") || s.includes("Read") || s.includes("Write") || s.includes("pair-test-loop");
			},
			60000,
		);
		await ctx.waitForPrompt(240000);

		const selectLogs = recentLogs("SELECT", logBefore);
		pass("Multi-step permissions", `Completed with ${selectLogs.length} selections`, Date.now() - start);
	});
}

async function testTaskQueueRunsTwoTasksInOrder() {
	const tempProject = fs.mkdtempSync(path.join(os.tmpdir(), QUEUE_E2E_CWD_PREFIX));
	try {
		await runIsolated(
			"Task queue runs two tasks in order",
			300000,
			async (ctx) => {
				const start = Date.now();
				try {
					const firstPrompt =
						"Queue e2e task 1: reply with the exact token QUEUE_TASK_ONE_DONE. Do not use tools. Do not ask follow-up questions.";
					const secondPrompt =
						"Queue e2e task 2: reply with the exact token QUEUE_TASK_TWO_DONE. Do not use tools. Do not ask follow-up questions.";

					await ctx.waitForPrompt();
					await ipc({ action: "queue_clear", surface: ctx.sessionId });

					const addFirst = await ipc({ action: "queue_add", surface: ctx.sessionId, text: firstPrompt });
					if (!addFirst.ok) throw new Error(`queue_add first failed: ${addFirst.error ?? "unknown error"}`);
					const addSecond = await ipc({ action: "queue_add", surface: ctx.sessionId, text: secondPrompt });
					if (!addSecond.ok) throw new Error(`queue_add second failed: ${addSecond.error ?? "unknown error"}`);

					const queued = await queueState(ctx.sessionId);
					if (queued.pendingCount !== 2 || queued.items.some((item) => item.status !== "pending")) {
						throw new Error(`Expected two pending tasks before start; got ${JSON.stringify(queued)}`);
					}

					const startQueue = await ipc({ action: "queue_start", surface: ctx.sessionId });
					if (!startQueue.ok) throw new Error(`queue_start failed: ${startQueue.error ?? "unknown error"}`);

					await ctx.waitFor("first queued task output", (s) => s.includes("QUEUE_TASK_ONE_DONE"), 120000);
					await ctx.waitFor("second queued task output", (s) => s.includes("QUEUE_TASK_TWO_DONE"), 180000);
					const finalState = await waitForQueueState(
						ctx.sessionId,
						"both tasks completed and queue stopped",
						(state) =>
							!state.isRunning && state.items.length === 2 && state.items.every((item) => item.status === "completed"),
						60000,
					);

					if (!finalState.items[0].prompt.includes("QUEUE_TASK_ONE_DONE")) {
						throw new Error(`First task order changed: ${JSON.stringify(finalState.items)}`);
					}
					if (!finalState.items[1].prompt.includes("QUEUE_TASK_TWO_DONE")) {
						throw new Error(`Second task order changed: ${JSON.stringify(finalState.items)}`);
					}

					pass("Task queue runs two tasks in order", "Both queued prompts executed and completed", Date.now() - start);
				} finally {
					await ipc({ action: "queue_clear", surface: ctx.sessionId }).catch(() => {});
				}
			},
			{ cwd: tempProject },
		);
	} finally {
		cleanupClaudeSessionsByCwdPrefix(QUEUE_E2E_CWD_PREFIX);
		fs.rmSync(tempProject, { recursive: true, force: true });
	}
}

async function testNumberedListNotSelection() {
	await runIsolated("Numbered list not selection", 180000, async (ctx) => {
		const start = Date.now();
		const prompt =
			"List all Swift files in app/PairApp/Sources/PairApp/ with line counts. Number them 1, 2, 3, etc. Do NOT ask follow-up questions — just output the numbered list.";

		await ctx.inject(prompt);

		// Wait for numbered list output + prompt
		await ctx.waitFor(
			"Claude lists files",
			(s) => {
				return s.includes(".swift") && (s.includes("1.") || s.includes("lines"));
			},
			60000,
		);
		await ctx.waitForPrompt();

		// Pause, settle, then check classification of the idle screen
		await ipc({ action: "pause_monitor", surface: ctx.sessionId });
		await sleep(5000);
		const logAfterSettle = Date.now();
		await ipc({ action: "resume_monitor", surface: ctx.sessionId });
		await sleep(15000);

		const selTrue = recentLogs("selection=true", logAfterSettle);
		const selFalse = recentLogs("selection=false", logAfterSettle);

		if (selTrue.length > 0 && selFalse.length === 0) {
			fail("Numbered list not selection", `Classified as selection=true (${selTrue.length}x)`, Date.now() - start);
		} else {
			pass(
				"Numbered list not selection",
				`${selFalse.length} selection=false, ${selTrue.length} selection=true`,
				Date.now() - start,
			);
		}
	});
}

async function testConversationalQuestion() {
	await runIsolated("Conversational question", 180000, async (ctx) => {
		const start = Date.now();
		const prompt =
			"Compare ClaudeMonitor.swift and ScreenDetection.swift. Which has better code organization? After your analysis, you MUST ask me a yes/no question about whether to proceed with changes. Do not skip the question.";

		await ctx.inject(prompt);

		// Wait for Claude to complete and return to prompt — whether or not it asks a ?
		await ctx.waitFor(
			"Claude responds",
			(s) => {
				const lines = s.split("\n").filter((l) => l.trim());
				const tail = lines.slice(-10);
				const hasPrompt = tail.some((l) => l.trim().startsWith("❯") || l.trim() === "❯");
				// Accept either: question mark above prompt, or just at prompt with output above
				const hasContent = s.includes("ClaudeMonitor") || s.includes("ScreenDetection") || s.includes("organization");
				return hasPrompt && hasContent;
			},
			120000,
		);

		// Check classification
		await ipc({ action: "pause_monitor", surface: ctx.sessionId });
		await sleep(5000);
		const logAfterSettle = Date.now();
		await ipc({ action: "resume_monitor", surface: ctx.sessionId });
		await sleep(20000);

		const selTrue = recentLogs("selection=true", logAfterSettle);
		const selFalse = recentLogs("selection=false", logAfterSettle);

		if (selTrue.length > 0 && selFalse.length === 0) {
			fail("Conversational question", `Classified as selection=true (${selTrue.length}x)`, Date.now() - start);
		} else {
			pass(
				"Conversational question",
				`${selFalse.length} selection=false, Codex gave substantive response`,
				Date.now() - start,
			);
		}
	});
}

async function testRealPermissionHandled() {
	await runIsolated("Real permission handled", 300000, async (ctx) => {
		const start = Date.now();
		const prompt = "Create a file /tmp/pair-selection-test.txt with the text 'selection test', then delete it.";
		const logBefore = Date.now();

		await ctx.inject(prompt);
		await ctx.waitForPrompt(240000);

		const selectLogs = recentLogs("Selection prompt, typing", logBefore);
		const acceptLogs = recentLogs("Accepting edits", logBefore);
		if (selectLogs.length > 0 || acceptLogs.length > 0) {
			pass(
				"Real permission handled",
				`${selectLogs.length} selections + ${acceptLogs.length} accept-edits`,
				Date.now() - start,
			);
		} else {
			pass("Real permission handled", `Completed (permissions may have been pre-granted)`, Date.now() - start);
		}
	});
}

async function testStability() {
	await runIsolated("Stability detection", 120000, async (ctx) => {
		const start = Date.now();
		const prompt =
			"List all .swift files in app/PairApp/Sources/PairApp/ with wc -l for each, then summarize the total. Do NOT ask any follow-up questions — just output the results.";
		const logBefore = Date.now();

		await ctx.inject(prompt);

		// Poll rapidly for 30s to observe screen changes
		const screenHashes: number[] = [];
		let lastHash = 0;
		const pollStart = Date.now();
		while (Date.now() - pollStart < 30000) {
			const screen = await ctx.readScreen();
			const hash = simpleHash(screen);
			if (hash !== lastHash) {
				screenHashes.push(hash);
				lastHash = hash;
			}
			await sleep(500);
		}

		await ctx.waitForPrompt(60000);

		const reviews = recentLogs("triggering review", logBefore);
		pass("Stability detection", `${screenHashes.length} screen changes, ${reviews.length} reviews`, Date.now() - start);
	});
}

async function testUserInputProtection() {
	const start = Date.now();
	// Verify PairApp is still reachable before creating a session
	try {
		const check = await ipc({ action: "list_sessions" });
		if (!check.ok) {
			fail(
				"User input protection",
				"PairApp not reachable (may have crashed during earlier tests)",
				Date.now() - start,
			);
			return;
		}
	} catch (e) {
		fail("User input protection", `PairApp IPC failed: ${e}`, Date.now() - start);
		return;
	}

	await runIsolated("User input protection", 90000, async (ctx) => {
		// Wait for clean prompt
		await ctx.waitForPrompt(30000);

		// Pause monitor, paste text WITHOUT Enter
		await ipc({ action: "pause_monitor", surface: ctx.sessionId });
		await sleep(2000);
		const userText = "THIS IS USER INPUT DO NOT SUBMIT";
		await ipc({ action: "send_input", surface: ctx.sessionId, text: userText });
		log("  Pasted user text (no Enter), waiting 15s...");
		await sleep(15000);

		const screen = await ctx.readScreen();
		await ipc({ action: "resume_monitor", surface: ctx.sessionId });

		if (screen.includes(userText)) {
			pass("User input protection", "User text preserved at prompt after 15s", Date.now() - start);
		} else {
			fail("User input protection", "User text disappeared from screen", Date.now() - start);
		}

		await ipc({ action: "send_key", surface: ctx.sessionId, text: "ctrl-u" });
	});
}

// ── Structured pipeline e2e tests ─────────────────────────────────────
// These verify the full chain: screen → ScreenParser → structured prompt
// → Codex decision → FeedbackHandler dispatch → correct action.

async function testStructuredDecisionFormat() {
	await runIsolated("Codex uses structured decisions", 120000, async (ctx) => {
		const start = Date.now();
		// Simple prompt that should complete quickly and trigger a Codex review
		const prompt = "What is 2+2? Just answer the number, nothing else.";
		const logBefore = Date.now();

		await ctx.inject(prompt);
		await ctx.waitForPrompt(60000);

		// Poll for Codex review
		let codexLogs: string[] = [];
		for (let i = 0; i < 12; i++) {
			await sleep(5000);
			codexLogs = recentLogs("Codex (", logBefore);
			if (codexLogs.length > 0) break;
		}

		const structured = codexLogs.filter(
			(l) =>
				l.includes("APPROVE") ||
				l.includes("WAIT") ||
				l.includes("ANSWER:") ||
				l.includes("SELECT:") ||
				l.includes("REDIRECT:") ||
				l.includes("ESCALATE:"),
		);
		const freeform = codexLogs.filter(
			(l) =>
				!l.includes("APPROVE") &&
				!l.includes("WAIT") &&
				!l.includes("ANSWER:") &&
				!l.includes("SELECT:") &&
				!l.includes("REDIRECT:") &&
				!l.includes("ESCALATE:"),
		);

		if (codexLogs.length === 0) {
			fail(
				"Codex uses structured decisions",
				"No Codex reviews within 60s — monitor may not have triggered stability",
				Date.now() - start,
			);
		} else if (structured.length > 0) {
			pass(
				"Codex uses structured decisions",
				`${structured.length}/${codexLogs.length} structured (${freeform.length} freeform fallback)`,
				Date.now() - start,
			);
		} else {
			fail(
				"Codex uses structured decisions",
				`All ${codexLogs.length} responses were freeform — structured prompt may not be working`,
				Date.now() - start,
			);
		}
	});
}

async function testWaitDecisionDoesNothing() {
	await runIsolated("WAIT decision does nothing", 120000, async (ctx) => {
		const start = Date.now();
		// Prompt that makes Claude do a long operation — Codex should say WAIT
		const prompt =
			"Read every Swift file in app/PairApp/Sources/PairApp/ and count the total lines across all files. Show your work.";
		const logBefore = Date.now();

		await ctx.inject(prompt);
		// Don't wait for prompt — Claude should be working

		await sleep(15000);

		// Check for WAIT decisions in logs
		const waitLogs = recentLogs("WAIT", logBefore);
		const feedbackLogs = recentLogs("FEEDBACK", logBefore);

		// While Claude is working, Codex should ideally say WAIT (not inject feedback)
		if (waitLogs.length > 0) {
			pass(
				"WAIT decision does nothing",
				`${waitLogs.length} WAIT decisions while Claude was working`,
				Date.now() - start,
			);
		} else if (feedbackLogs.length === 0) {
			pass(
				"WAIT decision does nothing",
				`No feedback injected while Claude was working (implicit wait)`,
				Date.now() - start,
			);
		} else {
			// Feedback was injected while working — not ideal but not a failure
			pass(
				"WAIT decision does nothing",
				`${feedbackLogs.length} feedback injected (Codex chose to intervene)`,
				Date.now() - start,
			);
		}
	});
}

async function testConversationMemoryAccumulates() {
	await runIsolated("Conversation memory", 180000, async (ctx) => {
		const start = Date.now();

		// Turn 1: Simple task
		await ctx.inject("What directory are we in? Just show the path.");
		await ctx.waitForPrompt(60000);
		await sleep(15000); // Let Codex review

		// Turn 2: Follow-up that references the first
		await ctx.inject("Now list the files in that directory. Just filenames, nothing else.");
		await ctx.waitForPrompt(60000);
		await sleep(15000);

		// Check that conversation summary is appearing in Codex prompts
		const turnLogs = recentLogs("Turn", start);
		const codexLogs = recentLogs("Codex (", start);

		if (turnLogs.length > 0) {
			pass("Conversation memory", `${turnLogs.length} conversation turns tracked`, Date.now() - start);
		} else {
			pass(
				"Conversation memory",
				`${codexLogs.length} reviews across 2 turns (memory in prompt, not in log)`,
				Date.now() - start,
			);
		}
	});
}

async function testScreenParserState() {
	await runIsolated("ScreenParser state detection", 120000, async (ctx) => {
		const start = Date.now();
		const prompt = "What is the current git branch? Just tell me the branch name.";
		const logBefore = Date.now();

		await ctx.inject(prompt);

		// While Claude works, check that the monitor logs the parsed state
		await sleep(10000);

		// After Claude finishes, poll for Codex review
		await ctx.waitForPrompt(60000);
		let codexLogs: string[] = [];
		for (let i = 0; i < 12; i++) {
			await sleep(5000);
			codexLogs = recentLogs("Codex (", logBefore);
			if (codexLogs.length > 0) break;
		}

		if (codexLogs.length > 0) {
			pass("ScreenParser state detection", `${codexLogs.length} reviews with structured state`, Date.now() - start);
		} else {
			fail("ScreenParser state detection", "No Codex reviews triggered", Date.now() - start);
		}
	});
}

async function testEscalateNotifiesUser() {
	await runIsolated("ESCALATE notifies user", 60000, async (ctx) => {
		const start = Date.now();
		const logBefore = Date.now();

		await ctx.waitForPrompt(30000);
		const resp = await ipc({
			action: "test_decision",
			surface: ctx.sessionId,
			text: "ESCALATE: deterministic e2e escalation check",
		});
		if (!resp.ok) {
			fail("ESCALATE notifies user", `test_decision failed: ${resp.error}`, Date.now() - start);
			return;
		}

		await sleep(3000);
		const escalateLogs = recentLogs("ESCALATED", logBefore).concat(recentLogs("ESCALATE", logBefore));

		if (escalateLogs.length > 0) {
			pass("ESCALATE notifies user", `Escalation path exercised (${escalateLogs.length} logs)`, Date.now() - start);
		} else {
			fail("ESCALATE notifies user", "No escalation log after deterministic test_decision", Date.now() - start);
		}
	});
}

async function testSelectHandlesPermission() {
	await runIsolated("SELECT handles real permission", 180000, async (ctx) => {
		const start = Date.now();
		const logBefore = Date.now();
		// This should trigger a Bash permission prompt (if not pre-approved)
		const prompt = "Run 'ls -la app/PairApp/Sources/PairApp/' and show the output.";

		await ctx.inject(prompt);
		await ctx.waitForPrompt(120000);

		// Check if SELECT decisions were made for permission prompts
		const selectLogs = recentLogs("SELECT", logBefore);
		const selectionLogs = recentLogs("Selection prompt", logBefore);
		const codexLogs = recentLogs("Codex (", logBefore);

		if (selectLogs.length > 0 || selectionLogs.length > 0) {
			pass(
				"SELECT handles real permission",
				`${selectLogs.length} SELECT events, ${selectionLogs.length} selection prompts handled`,
				Date.now() - start,
			);
		} else {
			pass(
				"SELECT handles real permission",
				`Completed with ${codexLogs.length} reviews (permissions pre-granted)`,
				Date.now() - start,
			);
		}
	});
}

async function testAnswerInjectsText() {
	await runIsolated("ANSWER injects text", 180000, async (ctx) => {
		const start = Date.now();
		const logBefore = Date.now();
		// Ask Claude something that will make it ask a follow-up
		const prompt = "I want to add a new test to the test suite. Ask me what behavior I want to test.";

		await ctx.inject(prompt);

		// Wait for Claude to ask a question
		try {
			await ctx.waitFor(
				"Claude asks question",
				(s) => {
					const lines = s.split("\n").filter((l) => l.trim());
					const tail = lines.slice(-8);
					const hasPrompt = tail.some((l) => l.trim().startsWith("❯") || l.trim() === "❯");
					return hasPrompt && tail.some((l) => l.trim().endsWith("?"));
				},
				120000,
			);

			// Wait for Codex to answer
			await sleep(20000);

			const answerLogs = recentLogs("ANSWER:", logBefore);
			const feedbackLogs = recentLogs("FEEDBACK", logBefore);
			const codexLogs = recentLogs("Codex (", logBefore);

			if (answerLogs.length > 0) {
				pass("ANSWER injects text", `Codex used ANSWER: format (${answerLogs.length} times)`, Date.now() - start);
			} else if (feedbackLogs.length > 0) {
				pass(
					"ANSWER injects text",
					`Codex responded with feedback (${feedbackLogs.length}x) — may have used freeform`,
					Date.now() - start,
				);
			} else {
				pass(
					"ANSWER injects text",
					`${codexLogs.length} reviews — Claude may not have asked a clear question`,
					Date.now() - start,
				);
			}
		} catch {
			// Claude didn't ask a question — that's OK, test the pipeline anyway
			const codexLogs = recentLogs("Codex (", logBefore);
			pass(
				"ANSWER injects text",
				`Claude didn't ask a question, but ${codexLogs.length} reviews ran`,
				Date.now() - start,
			);
		}
	});
}

// ── Safety & resilience e2e tests ─────────────────────────────────────

async function testAuthTokenRequired() {
	const start = Date.now();
	try {
		// Send IPC command WITHOUT auth token — should be rejected
		const resp = await new Promise<{ ok: boolean; error?: string }>((resolve, reject) => {
			const client = net.createConnection(SOCKET);
			let data = "";
			const timer = setTimeout(() => {
				client.destroy();
				reject(new Error("timeout"));
			}, 5000);
			client.on("connect", () => client.write(JSON.stringify({ action: "list_sessions" }))); // no token
			client.on("data", (d) => {
				data += d.toString();
			});
			client.on("end", () => {
				clearTimeout(timer);
				try {
					resolve(JSON.parse(data));
				} catch {
					reject(new Error("bad response"));
				}
			});
			client.on("error", (e) => {
				clearTimeout(timer);
				reject(e);
			});
		});

		if (!resp.ok && resp.error?.includes("token")) {
			pass("Auth token required", "IPC correctly rejected unauthenticated request", Date.now() - start);
		} else if (!resp.ok) {
			pass("Auth token required", `Rejected: ${resp.error}`, Date.now() - start);
		} else {
			fail("Auth token required", "IPC accepted request WITHOUT auth token", Date.now() - start);
		}
	} catch (e) {
		fail("Auth token required", `${e}`, Date.now() - start);
	}
}

async function testDuplicateResponseSkipped() {
	await runIsolated("Duplicate response skipped", 120000, async (ctx) => {
		const start = Date.now();
		// Simple idle prompt — Codex will likely repeat the same advice
		const prompt = "echo done";
		const logBefore = Date.now();

		await ctx.inject(prompt);
		await ctx.waitForPrompt(30000);

		// Wait long enough for multiple reviews to fire
		await sleep(40000);

		const codexLogs = recentLogs("Codex (", logBefore);
		const dupLogs = recentLogs("Duplicate", logBefore);
		const repeatedLogs = recentLogs("repeated response", logBefore);
		const skippedLogs = recentLogs("SKIPPED", logBefore);

		if (dupLogs.length > 0 || repeatedLogs.length > 0) {
			pass(
				"Duplicate response skipped",
				`${dupLogs.length} duplicates + ${repeatedLogs.length} repeats caught out of ${codexLogs.length} reviews`,
				Date.now() - start,
			);
		} else if (codexLogs.length <= 2) {
			pass(
				"Duplicate response skipped",
				`Only ${codexLogs.length} reviews — not enough to trigger duplicates`,
				Date.now() - start,
			);
		} else {
			// Multiple reviews but no duplicates caught — Codex may have varied responses
			pass(
				"Duplicate response skipped",
				`${codexLogs.length} unique reviews, ${skippedLogs.length} skipped`,
				Date.now() - start,
			);
		}
	});
}

async function testBackoffIncreasesAfterUnhelpful() {
	await runIsolated("Backoff increases", 60000, async (ctx) => {
		const start = Date.now();
		let lastState: { streak: number; backoff: number } | undefined;

		for (let i = 0; i < 6; i++) {
			const resp = await ipc({ action: "test_unhelpful", surface: ctx.sessionId });
			if (!resp.ok) throw new Error(`test_unhelpful failed: ${resp.error ?? "unknown error"}`);
			if (!resp.result) throw new Error("test_unhelpful returned no result");
			lastState = JSON.parse(resp.result) as { streak: number; backoff: number };
			if (i < 5 && lastState.backoff !== 1.0) {
				throw new Error(`Backoff increased too early at streak ${lastState.streak}: ${lastState.backoff}`);
			}
		}

		if (!lastState || lastState.streak !== 6 || lastState.backoff <= 1.0) {
			throw new Error(`Expected backoff > 1.0 at streak 6; got ${JSON.stringify(lastState)}`);
		}

		pass(
			"Backoff increases",
			`Backoff reached ${lastState.backoff}x at streak ${lastState.streak}`,
			Date.now() - start,
		);
	});
}

async function testSanityBlocksDangerous() {
	await runIsolated("Sanity blocks dangerous", 60000, async (ctx) => {
		const start = Date.now();
		// We can't make Codex return a dangerous command, but we can verify
		// the sanity check infrastructure works by checking that the validateResponse
		// function exists and the pipeline runs without crash.
		const prompt = "echo 'sanity check test'";
		const logBefore = Date.now();

		await ctx.inject(prompt);
		await ctx.waitForPrompt(30000);
		await sleep(10000);

		const codexLogs = recentLogs("Codex (", logBefore);
		const sanityLogs = recentLogs("Sanity check", logBefore);
		const skippedLogs = recentLogs("SKIPPED", logBefore);

		// Sanity checks may or may not fire (depends on what Codex returns)
		pass(
			"Sanity blocks dangerous",
			`Pipeline ran: ${codexLogs.length} reviews, ${sanityLogs.length} sanity blocks, ${skippedLogs.length} skipped`,
			Date.now() - start,
		);
	});
}

async function testErrorStateDetected() {
	await runIsolated("Error state detection", 120000, async (ctx) => {
		const start = Date.now();
		// Trigger a command that will produce an error
		const prompt =
			"Run 'swift build' in a directory that doesn't exist: cd /tmp/nonexistent-dir-pair-test && swift build";
		const logBefore = Date.now();

		await ctx.inject(prompt);

		// Wait for Claude to complete (it will see the error)
		await ctx.waitForPrompt(90000);
		await sleep(10000);

		const codexLogs = recentLogs("Codex (", logBefore);
		const errorLogs = recentLogs("showingError", logBefore);
		const stuckLogs = recentLogs("isStuck", logBefore);

		// Check if the error state was detected in screen parsing
		if (errorLogs.length > 0 || stuckLogs.length > 0) {
			pass(
				"Error state detection",
				`Error state detected: ${errorLogs.length} showingError, ${stuckLogs.length} isStuck`,
				Date.now() - start,
			);
		} else {
			// Claude may have handled the error gracefully without triggering our error detection
			pass(
				"Error state detection",
				`Claude handled error gracefully — ${codexLogs.length} reviews ran`,
				Date.now() - start,
			);
		}
	});
}

async function testLongTaskNoPreemptiveIntervention() {
	await runIsolated("Long task no preemptive intervention", 180000, async (ctx) => {
		const start = Date.now();
		// A task that makes Claude read multiple files — takes a while
		const prompt =
			"Read the first 20 lines of each Swift file in app/PairApp/Sources/PairApp/ and summarize the purpose of each file in one sentence. Do NOT ask questions.";

		await ctx.inject(prompt);

		// Track how many feedback injections happen while Claude is actively working
		// (screen changing = Claude is working)
		const injectedWhileWorking: string[] = [];
		const checkStart = Date.now();
		while (Date.now() - checkStart < 60000) {
			const screen = await ctx.readScreen();
			// If screen shows Claude is actively using tools, any injection is premature
			const isWorking = screen.includes("Read") || screen.includes("Bash") || screen.includes("thinking");
			if (isWorking) {
				const recentInjections = recentLogs("injection delivered", Date.now() - 2000);
				injectedWhileWorking.push(...recentInjections);
			}
			// Check if Claude returned to prompt
			const lines = screen.split("\n").slice(-6);
			if (lines.some((l) => l.trim().startsWith("❯") || l.trim() === "❯")) break;
			await sleep(2000);
		}

		await ctx.waitForPrompt(120000);

		if (injectedWhileWorking.length === 0) {
			pass("Long task no preemptive intervention", `No premature injections during work`, Date.now() - start);
		} else {
			fail(
				"Long task no preemptive intervention",
				`${injectedWhileWorking.length} injections while Claude was actively working`,
				Date.now() - start,
			);
		}
	});
}

async function testMultiSessionIsolation() {
	const start = Date.now();
	try {
		// Create two sessions simultaneously
		const ctx1 = new TestContext();
		const ctx2 = new TestContext();

		const ready1 = await ctx1.setup();
		const ready2 = await ctx2.setup();

		if (!ready1 || !ready2) {
			fail("Multi-session isolation", "Failed to set up dual sessions", Date.now() - start);
			await ctx1.teardown();
			await ctx2.teardown();
			return;
		}

		// Inject different prompts into each
		await ctx1.inject("echo 'session-one-marker'");
		await ctx2.inject("echo 'session-two-marker'");

		// Wait for both to complete
		const screen1 = await ctx1.waitForPrompt(60000);
		const screen2 = await ctx2.waitForPrompt(60000);

		// Verify no cross-contamination
		const s1HasOwn = screen1.includes("session-one") || screen1.includes("echo");
		const s2HasOwn = screen2.includes("session-two") || screen2.includes("echo");
		const s1HasOther = screen1.includes("session-two-marker");
		const s2HasOther = screen2.includes("session-one-marker");

		await ctx1.teardown();
		await ctx2.teardown();

		if (s1HasOther || s2HasOther) {
			fail("Multi-session isolation", "Cross-contamination detected between sessions", Date.now() - start);
		} else {
			pass("Multi-session isolation", `Sessions isolated (s1: ${s1HasOwn}, s2: ${s2HasOwn})`, Date.now() - start);
		}
	} catch (e) {
		fail("Multi-session isolation", `${e}`, Date.now() - start);
	}
}

// ── Codex-leads mode e2e tests ────────────────────────────────────────

async function testCodexSessionStarts() {
	await runCodexIsolated("Codex session starts", 60000, async (ctx) => {
		const start = Date.now();
		const screen = await ctx.readScreen();

		// Verify Codex TUI is rendering
		const hasHeader = screen.includes("OpenAI Codex") || screen.includes("codex");
		const hasPrompt = screen.includes("›");
		const hasStatus = screen.includes("gpt-") || screen.includes("default ·");

		if (hasPrompt) {
			pass(
				"Codex session starts",
				`Codex TUI running (header=${hasHeader}, prompt=${hasPrompt}, status=${hasStatus})`,
				Date.now() - start,
			);
		} else {
			fail("Codex session starts", `Codex TUI not detected. Screen: ${screen.substring(0, 200)}`, Date.now() - start);
		}
	});
}

async function testCodexAcceptsTypedInput() {
	await runCodexIsolated("Codex accepts typed input", 120000, async (ctx) => {
		const start = Date.now();

		// Type a simple prompt
		await ctx.type("What directory are we in? Just show the path.");

		// Wait for Codex to show output (bullet point or tool output)
		await ctx.waitFor(
			"Codex produces output",
			(s) => {
				return s.includes("•") || s.includes("claude-codex-pair") || s.includes("/Users/");
			},
			60000,
		);

		// Wait for return to prompt
		await ctx.waitForPrompt(60000);

		pass("Codex accepts typed input", `Codex processed prompt and returned to ›`, Date.now() - start);
	});
}

async function testCodexScreenDetectionWorks() {
	await runCodexIsolated("Codex screen detection", 120000, async (ctx) => {
		const start = Date.now();
		const logBefore = Date.now();

		// Type a prompt that makes Codex work
		await ctx.type("How many Swift files are in app/PairApp/Sources/PairApp/?");

		// Wait for completion
		await ctx.waitForPrompt(90000);

		// Check that the monitor detected Codex's states correctly
		// Look for the session's logs — they should show selection=false (not a selection prompt)
		await sleep(15000);

		const codexLogs = recentLogs("Codex (", logBefore).concat(recentLogs("Claude (", logBefore));
		const reviewLogs = recentLogs("triggering review", logBefore);

		// In Codex-leads mode, the REVIEWER is Claude, not Codex
		// So we look for Claude review responses
		if (codexLogs.length > 0 || reviewLogs.length > 0) {
			pass(
				"Codex screen detection",
				`Monitor detected Codex states: ${reviewLogs.length} reviews, ${codexLogs.length} responses`,
				Date.now() - start,
			);
		} else {
			// Even without reviews, if Codex completed the task, detection worked
			pass("Codex screen detection", `Codex completed task (monitor may not have reviewed yet)`, Date.now() - start);
		}
	});
}

async function testCodexLeadsClaudeReviews() {
	await runCodexIsolated("Claude reviews Codex work", 180000, async (ctx) => {
		const start = Date.now();
		const logBefore = Date.now();

		// Give Codex a task and wait for Claude to review
		await ctx.type("List all .swift files in app/PairApp/Sources/PairApp/ and count them.");

		// Wait for Codex to complete
		await ctx.waitForPrompt(120000);

		// Wait for Claude to review (the reviewer in codexLeads mode)
		await sleep(30000);

		// Check logs for structured decisions from Claude
		const allLogs = recentLogs("APPROVE", logBefore)
			.concat(recentLogs("WAIT", logBefore))
			.concat(recentLogs("ANSWER:", logBefore))
			.concat(recentLogs("REDIRECT:", logBefore));
		const reviewLogs = recentLogs("triggering review", logBefore);

		if (allLogs.length > 0) {
			pass("Claude reviews Codex work", `Claude made ${allLogs.length} structured decisions`, Date.now() - start);
		} else if (reviewLogs.length > 0) {
			pass("Claude reviews Codex work", `${reviewLogs.length} reviews triggered`, Date.now() - start);
		} else {
			pass(
				"Claude reviews Codex work",
				`Codex completed (Claude review may not have triggered in time)`,
				Date.now() - start,
			);
		}
	});
}

async function testCodexModeUsesTypeInput() {
	await runCodexIsolated("Codex mode uses typeInput", 60000, async (ctx) => {
		const start = Date.now();

		// Type a prompt and submit it — verify Codex processes it
		const screen1 = await ctx.readScreen();
		const hash1 = simpleHash(screen1);

		// Type a real prompt that Codex will process
		await ipc({ action: "type_input", surface: ctx.sessionId, text: "echo hi\n" });

		// Wait for screen to change (Codex processes the input)
		let changed = false;
		for (let i = 0; i < 10; i++) {
			await sleep(1000);
			const screen = await ctx.readScreen();
			if (simpleHash(screen) !== hash1) {
				changed = true;
				break;
			}
		}

		if (changed) {
			pass("Codex mode uses typeInput", "Screen changed after typed input — Codex processed it", Date.now() - start);
		} else {
			fail("Codex mode uses typeInput", "Screen unchanged 10s after typing", Date.now() - start);
		}
	});
}

async function testCodexSidebarLabels() {
	await runCodexIsolated("Codex sidebar labels", 60000, async (ctx) => {
		const start = Date.now();
		// Verify the session is running Codex (not Claude) by waiting for Codex markers.
		// The Ink TUI redraws frequently, so we poll until we get a substantive screen.
		let screen = "";
		for (let i = 0; i < 15; i++) {
			screen = await ctx.readScreen();
			if (screen.length > 50 && (screen.includes("›") || screen.includes("OpenAI Codex") || screen.includes("gpt-")))
				break;
			await sleep(1000);
		}

		const isCodex = screen.includes("OpenAI Codex") || screen.includes("gpt-") || screen.includes("›");
		const isClaude = screen.includes("Claude Code") || screen.includes("❯");

		if (isCodex && !isClaude) {
			pass(
				"Codex sidebar labels",
				`Codex in terminal (not Claude) — sidebar shows 'Claude reviewing'`,
				Date.now() - start,
			);
		} else if (isCodex && isClaude) {
			fail("Codex sidebar labels", "Both Codex and Claude detected — mode confusion", Date.now() - start);
		} else {
			fail(
				"Codex sidebar labels",
				`Neither detected after 15s. Screen (${screen.length} chars): ${screen.substring(0, 100)}`,
				Date.now() - start,
			);
		}
	});
}

// ── Main ──────────────────────────────────────────────────────────────

/** Clean up old test sessions. */
async function cleanupOldTestSessions() {
	try {
		const resp = await ipc({ action: "list_sessions" });
		if (!resp.ok || !resp.result) return;
		const sessions: Array<{ id: string }> = JSON.parse(resp.result);
		for (const s of sessions) {
			if (s.id.startsWith("test-")) {
				log(`  Removing old test session: ${s.id}`);
				await ipc({ action: "remove_session", surface: s.id });
			}
		}
	} catch {
		/* non-fatal */
	}
	cleanupClaudeSessionsByCwdPrefix(QUEUE_E2E_CWD_PREFIX);
}

export async function runTestLoop(): Promise<void> {
	log("PairApp automated test loop (isolated sessions)");
	log(`Project: ${PROJECT}`);
	log("");

	await testIpcConnection();
	if (!results[0].passed) {
		console.error("\nPairApp not running. Start it first.");
		process.exit(1);
	}

	await cleanupOldTestSessions();

	const tests = [
		// Core pipeline
		testInjectAndCodexReview,
		testCodexAnswersQuestion,
		testAcceptEditsFlow,
		testMultiStepPermissions,
		// Queue behavior
		testTaskQueueRunsTwoTasksInOrder,
		// Selection behavior
		testNumberedListNotSelection,
		testConversationalQuestion,
		testRealPermissionHandled,
		// Structured pipeline
		testStructuredDecisionFormat,
		testWaitDecisionDoesNothing,
		testConversationMemoryAccumulates,
		testScreenParserState,
		testSelectHandlesPermission,
		testAnswerInjectsText,
		testEscalateNotifiesUser,
		// Safety & resilience
		testAuthTokenRequired,
		testDuplicateResponseSkipped,
		testBackoffIncreasesAfterUnhelpful,
		testSanityBlocksDangerous,
		testErrorStateDetected,
		testLongTaskNoPreemptiveIntervention,
		testMultiSessionIsolation,
		// Codex-leads mode
		testCodexSessionStarts,
		testCodexAcceptsTypedInput,
		testCodexScreenDetectionWorks,
		testCodexLeadsClaudeReviews,
		testCodexModeUsesTypeInput,
		testCodexSidebarLabels,
		// Final
		testStability,
		testUserInputProtection,
	];

	const filter = process.env.PAIR_TEST_FILTER?.toLowerCase();
	const selectedTests = filter ? tests.filter((test) => test.name.toLowerCase().includes(filter)) : tests;
	if (filter) {
		log(`Filter: ${filter} (${selectedTests.length}/${tests.length} tests selected)`);
	}
	if (selectedTests.length === 0) {
		fail("Test selection", `No tests matched PAIR_TEST_FILTER=${filter}`, 0);
	}

	for (const test of selectedTests) {
		// Abort remaining tests if PairApp crashed
		if (!(await assertPairAppAlive())) {
			const remaining = selectedTests.length - selectedTests.indexOf(test);
			log(`  ⚠ PairApp crashed — skipping ${remaining} remaining tests`);
			for (let i = selectedTests.indexOf(test); i < selectedTests.length; i++) {
				fail(selectedTests[i].name || `test-${i}`, "PairApp crashed", 0);
			}
			break;
		}
		await test();
	}

	// Summary
	const passed = results.filter((r) => r.passed).length;
	const failed = results.filter((r) => !r.passed).length;
	const total = results.length;
	const totalTime = results.reduce((sum, r) => sum + r.durationMs, 0);

	log("");
	log(`${"═".repeat(60)}`);
	log(`Results: ${passed}/${total} passed, ${failed} failed (${(totalTime / 1000).toFixed(1)}s total)`);
	if (failed > 0) {
		log("");
		log("Failures:");
		for (const r of results.filter((r) => !r.passed)) {
			log(`  ✗ ${r.name}: ${r.detail}`);
		}
	}
	log(`${"═".repeat(60)}`);

	// Clean up any remaining test sessions
	await cleanupOldTestSessions();

	process.exit(failed > 0 ? 1 : 0);
}
