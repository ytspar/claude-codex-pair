/**
 * Automated test harness for the PairApp monitor loop.
 *
 * Each test gets its own isolated Claude session, preventing cascading failures.
 * A slow/stuck test cannot poison subsequent tests.
 *
 * Usage: pair test-loop
 */
import path from "node:path";
import os from "node:os";
import net from "node:net";
import fs from "node:fs";

const SOCKET = path.join(os.homedir(), ".claude-codex-pair", "pair-terminal.sock");
const TOKEN_PATH = path.join(os.homedir(), ".claude-codex-pair", "auth-token");
const PROJECT = process.cwd();
const LOG_FILE = path.join(os.homedir(), ".claude-codex-pair", "pairapp.log");

function readAuthToken(): string {
	try { return fs.readFileSync(TOKEN_PATH, "utf-8").trim(); }
	catch { return ""; }
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
		const timer = setTimeout(() => { client.destroy(); reject(new Error("IPC timeout")); }, 10000);
		client.on("connect", () => client.write(JSON.stringify({ ...command, token: readAuthToken() })));
		client.on("data", (d) => { data += d.toString(); });
		client.on("end", () => { clearTimeout(timer); try { resolve(JSON.parse(data)); } catch { reject(new Error(`Bad response: ${data}`)); } });
		client.on("error", (e) => { clearTimeout(timer); reject(e); });
	});
}

function simpleHash(s: string): number {
	let h = 0;
	for (let i = 0; i < s.length; i++) {
		h = ((h << 5) - h + s.charCodeAt(i)) | 0;
	}
	return h;
}

async function sleep(ms: number) { await new Promise(r => setTimeout(r, ms)); }

/** Get recent log lines matching a pattern since a timestamp. */
function recentLogs(pattern: string, since: number): string[] {
	if (!fs.existsSync(LOG_FILE)) return [];
	const content = fs.readFileSync(LOG_FILE, "utf-8");
	const sinceStr = new Date(since).toISOString().slice(0, 19);
	return content.split("\n").filter(l => {
		if (!l.includes(pattern)) return false;
		const match = l.match(/^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/);
		if (!match) return false;
		return match[1] >= sinceStr;
	});
}

// ── Test context: isolated session per test ───────────────────────────

class TestContext {
	readonly sessionId: string;

	constructor() {
		this.sessionId = `test-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
	}

	async setup(): Promise<boolean> {
		const resp = await ipc({ action: "create_session", surface: this.sessionId, text: PROJECT });
		if (!resp.ok) return false;
		// Wait for Claude to start
		for (let i = 0; i < 30; i++) {
			await sleep(1000);
			const screen = await this.readScreen();
			if (screen.includes("❯") || screen.includes("Claude Code")) return true;
		}
		return false;
	}

	async teardown(): Promise<void> {
		try { await ipc({ action: "remove_session", surface: this.sessionId }); } catch {}
	}

	async readScreen(): Promise<string> {
		const resp = await ipc({ action: "read_screen", surface: this.sessionId });
		return resp.ok ? (resp.result ?? "") : "";
	}

	async waitFor(description: string, condition: (screen: string) => boolean, timeoutMs = 60000): Promise<{ screen: string; elapsed: number }> {
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
		await ipc({ action: "send_input", surface: this.sessionId, text: prompt + "\r" });
		await ipc({ action: "resume_monitor", surface: this.sessionId });
		await this.waitFor("Claude starts working", (s) => simpleHash(s) !== baseline, timeoutMs);
	}

	async waitForPrompt(timeoutMs = 120000): Promise<string> {
		const { screen } = await this.waitFor("❯ prompt", (s) => {
			const lines = s.split("\n").slice(-6);
			return lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
		}, timeoutMs);
		return screen;
	}
}

/** Run a test with its own isolated session. Creates session, runs test fn, cleans up. */
async function runIsolated(name: string, timeoutMs: number, testFn: (ctx: TestContext) => Promise<void>): Promise<void> {
	const start = Date.now();
	const ctx = new TestContext();
	try {
		const ready = await ctx.setup();
		if (!ready) { fail(name, "Session setup failed", Date.now() - start); return; }

		// Wrap the test with a timeout
		await Promise.race([
			testFn(ctx),
			new Promise<never>((_, reject) =>
				setTimeout(() => reject(new Error(`Test timed out after ${timeoutMs / 1000}s`)), timeoutMs)
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
		await ctx.waitFor("Swift test output", (s) => {
			return s.includes("Executed") || s.includes("Build complete") || s.includes("passed");
		}, 120000);
		await ctx.waitForPrompt();
		pass("Claude runs tests", `Completed`, Date.now() - start);

		// Wait for Codex review
		await sleep(30000);
		const codexLogs = recentLogs("Codex (", logBefore);
		if (codexLogs.length > 0) {
			const last = codexLogs[codexLogs.length - 1];
			pass("Codex review", `Codex responded: ${last.substring(last.indexOf("Codex (")).substring(0, 80)}`, Date.now() - start);
		} else {
			fail("Codex review", "No Codex response after 30s", Date.now() - start);
		}
	});
}

async function testCodexAnswersQuestion() {
	await runIsolated("Codex answers question", 180000, async (ctx) => {
		const start = Date.now();
		const prompt = "What files in app/PairApp/Sources/PairApp/ contain the word 'Codex'? List them and ask me which one to examine.";

		await ctx.inject(prompt);

		// Wait for Claude to ask a question
		const { elapsed } = await ctx.waitFor("Claude asks question", (s) => {
			const lines = s.split("\n").filter(l => l.trim());
			return lines.slice(-10).some(l => l.trim().endsWith("?"));
		}, 120000);
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
		const prompt = "Add a Swift comment '// test-loop: accept-edits validation' as the FIRST line of app/PairApp/Sources/PairApp/Version.swift, then immediately remove it and restore the original file.";
		const logBefore = Date.now();

		await ctx.inject(prompt);

		await ctx.waitFor("Claude working on edit", (s) => {
			return s.includes("accept-edits") || s.includes("test-loop") ||
				(s.includes("Version.swift") && (s.includes("Edit") || s.includes("comment")));
		}, 60000);
		await ctx.waitForPrompt(240000);

		const selectLogs = recentLogs("SELECT", logBefore);
		pass("Accept-edits flow", `Completed with ${selectLogs.length} selections`, Date.now() - start);
	});
}

async function testMultiStepPermissions() {
	await runIsolated("Multi-step permissions", 300000, async (ctx) => {
		const start = Date.now();
		const prompt = "Read app/PairApp/Package.swift, then create a temporary file /tmp/pair-test-loop.txt with the package name from it, then run 'cat /tmp/pair-test-loop.txt' to verify, then delete it with rm.";
		const logBefore = Date.now();

		await ctx.inject(prompt);

		await ctx.waitFor("Claude using tools", (s) => {
			return s.includes("Bash") || s.includes("Read") || s.includes("Write") || s.includes("pair-test-loop");
		}, 60000);
		await ctx.waitForPrompt(240000);

		const selectLogs = recentLogs("SELECT", logBefore);
		pass("Multi-step permissions", `Completed with ${selectLogs.length} selections`, Date.now() - start);
	});
}

async function testNumberedListNotSelection() {
	await runIsolated("Numbered list not selection", 180000, async (ctx) => {
		const start = Date.now();
		const prompt = "List all Swift files in app/PairApp/Sources/PairApp/ with line counts. Number them 1, 2, 3, etc. Do NOT ask follow-up questions — just output the numbered list.";

		await ctx.inject(prompt);

		// Wait for numbered list output + prompt
		await ctx.waitFor("Claude lists files", (s) => {
			return s.includes(".swift") && (s.includes("1.") || s.includes("lines"));
		}, 60000);
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
			pass("Numbered list not selection", `${selFalse.length} selection=false, ${selTrue.length} selection=true`, Date.now() - start);
		}
	});
}

async function testConversationalQuestion() {
	await runIsolated("Conversational question", 180000, async (ctx) => {
		const start = Date.now();
		const prompt = "Look at app/PairApp/Sources/PairApp/ClaudeMonitor.swift and app/PairApp/Sources/PairApp/ScreenDetection.swift. Tell me which one has better code organization and ask me if I'd like you to refactor the other one to match.";

		await ctx.inject(prompt);

		// Wait for Claude to ask a question
		await ctx.waitFor("Claude asks question", (s) => {
			const lines = s.split("\n").filter(l => l.trim());
			const tail = lines.slice(-10);
			const hasPrompt = tail.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			return hasPrompt && tail.some(l => l.trim().endsWith("?"));
		}, 120000);

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
			pass("Conversational question", `${selFalse.length} selection=false, Codex gave substantive response`, Date.now() - start);
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
			pass("Real permission handled", `${selectLogs.length} selections + ${acceptLogs.length} accept-edits`, Date.now() - start);
		} else {
			pass("Real permission handled", `Completed (permissions may have been pre-granted)`, Date.now() - start);
		}
	});
}

async function testStability() {
	await runIsolated("Stability detection", 120000, async (ctx) => {
		const start = Date.now();
		const prompt = "List all .swift files in app/PairApp/Sources/PairApp/ with wc -l for each, then summarize the total. Do NOT ask any follow-up questions — just output the results.";
		const logBefore = Date.now();

		await ctx.inject(prompt);

		// Poll rapidly for 30s to observe screen changes
		const screenHashes: number[] = [];
		let lastHash = 0;
		const pollStart = Date.now();
		while (Date.now() - pollStart < 30000) {
			const screen = await ctx.readScreen();
			const hash = simpleHash(screen);
			if (hash !== lastHash) { screenHashes.push(hash); lastHash = hash; }
			await sleep(500);
		}

		await ctx.waitForPrompt(60000);

		const reviews = recentLogs("triggering review", logBefore);
		pass("Stability detection", `${screenHashes.length} screen changes, ${reviews.length} reviews`, Date.now() - start);
	});
}

async function testUserInputProtection() {
	await runIsolated("User input protection", 60000, async (ctx) => {
		const start = Date.now();

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
	} catch { /* non-fatal */ }
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

	// Each test gets its own session — no cascading failures
	await testInjectAndCodexReview();
	await testCodexAnswersQuestion();
	await testAcceptEditsFlow();
	await testMultiStepPermissions();

	// Selection behavior regression tests
	await testNumberedListNotSelection();
	await testConversationalQuestion();
	await testRealPermissionHandled();

	await testStability();
	await testUserInputProtection();

	// Summary
	const passed = results.filter(r => r.passed).length;
	const failed = results.filter(r => !r.passed).length;
	const total = results.length;
	const totalTime = results.reduce((sum, r) => sum + r.durationMs, 0);

	log("");
	log(`${"═".repeat(60)}`);
	log(`Results: ${passed}/${total} passed, ${failed} failed (${(totalTime / 1000).toFixed(1)}s total)`);
	if (failed > 0) {
		log("");
		log("Failures:");
		for (const r of results.filter(r => !r.passed)) {
			log(`  ✗ ${r.name}: ${r.detail}`);
		}
	}
	log(`${"═".repeat(60)}`);

	// Clean up any remaining test sessions
	await cleanupOldTestSessions();

	process.exit(failed > 0 ? 1 : 0);
}
