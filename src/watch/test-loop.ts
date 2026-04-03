/**
 * Automated test harness for the PairApp monitor loop.
 *
 * Creates a real session, injects tasks, and verifies the full cycle:
 * inject → Claude works → Codex reviews → next task dequeued.
 *
 * Usage: pair test-loop
 */
import path from "node:path";
import os from "node:os";
import net from "node:net";
import fs from "node:fs";

const SOCKET = path.join(os.homedir(), ".claude-codex-pair", "pair-terminal.sock");
const PROJECT = process.cwd();
const SESSION_ID = `test-${Date.now().toString(36)}`;
const LOG_FILE = path.join(os.homedir(), ".claude-codex-pair", "pairapp.log");

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

async function ipc(command: Record<string, unknown>): Promise<{ ok: boolean; result?: string; error?: string }> {
	return new Promise((resolve, reject) => {
		const client = net.createConnection(SOCKET);
		let data = "";
		const timer = setTimeout(() => { client.destroy(); reject(new Error("IPC timeout")); }, 10000);
		client.on("connect", () => client.write(JSON.stringify(command)));
		client.on("data", (d) => { data += d.toString(); });
		client.on("end", () => { clearTimeout(timer); try { resolve(JSON.parse(data)); } catch { reject(new Error(`Bad response: ${data}`)); } });
		client.on("error", (e) => { clearTimeout(timer); reject(e); });
	});
}

async function readScreen(): Promise<string> {
	const resp = await ipc({ action: "read_screen", surface: SESSION_ID });
	return resp.ok ? (resp.result ?? "") : "";
}

async function sleep(ms: number) {
	await new Promise(r => setTimeout(r, ms));
}

/** Wait for a condition on the screen, polling every 1s. */
async function waitFor(
	description: string,
	condition: (screen: string) => boolean,
	timeoutMs = 60000,
): Promise<{ screen: string; elapsed: number }> {
	const start = Date.now();
	while (Date.now() - start < timeoutMs) {
		const screen = await readScreen();
		if (condition(screen)) return { screen, elapsed: Date.now() - start };
		await sleep(1000);
	}
	throw new Error(`Timeout waiting for: ${description}`);
}

/** Get recent log lines matching a pattern. */
function recentLogs(pattern: string, since: number): string[] {
	if (!fs.existsSync(LOG_FILE)) return [];
	const content = fs.readFileSync(LOG_FILE, "utf-8");
	const sinceStr = new Date(since).toISOString().slice(0, 19);
	return content.split("\n").filter(l => l >= sinceStr && l.includes(pattern));
}

// ── Tests ──────────────────────────────────────────────────────────────

async function testIpcConnection() {
	const start = Date.now();
	try {
		const resp = await ipc({ action: "list_sessions" });
		if (resp.ok) {
			pass("IPC connection", "Socket responding", Date.now() - start);
		} else {
			fail("IPC connection", `Error: ${resp.error}`, Date.now() - start);
		}
	} catch (e) {
		fail("IPC connection", `${e}`, Date.now() - start);
	}
}

async function testCreateSession() {
	const start = Date.now();
	try {
		const resp = await ipc({ action: "create_session", surface: SESSION_ID, text: PROJECT });
		if (resp.ok) {
			pass("Create session", `${SESSION_ID} in ${PROJECT}`, Date.now() - start);
		} else {
			fail("Create session", `${resp.error}`, Date.now() - start);
		}
	} catch (e) {
		fail("Create session", `${e}`, Date.now() - start);
	}
}

async function testClaudeStartup() {
	const start = Date.now();
	try {
		const { screen, elapsed } = await waitFor(
			"Claude prompt (❯)",
			(s) => s.includes("❯") || s.includes("Claude Code"),
			30000,
		);
		const hasPrompt = screen.includes("❯");
		const hasClaude = screen.includes("Claude Code");
		if (hasPrompt || hasClaude) {
			pass("Claude startup", `Prompt visible after ${(elapsed / 1000).toFixed(1)}s`, Date.now() - start);
		} else {
			fail("Claude startup", "Neither ❯ nor Claude Code visible", Date.now() - start);
		}
	} catch (e) {
		fail("Claude startup", `${e}`, Date.now() - start);
	}
}

async function testPromptDetection() {
	const start = Date.now();
	try {
		const screen = await readScreen();
		const lines = screen.split("\n");
		const hasPrompt = lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
		const lastNonEmpty = lines.filter(l => l.trim()).pop() ?? "";
		// Check if isPromptEmpty would work
		const promptLine = lines.find(l => l.includes("❯"));
		const afterPrompt = promptLine ? promptLine.split("❯")[1]?.trim() ?? "" : "";
		const isEmpty = afterPrompt === "" || afterPrompt.length === 0;

		if (hasPrompt) {
			pass("Prompt detection", `Found ❯, empty=${isEmpty}, lastLine="${lastNonEmpty.trim().substring(0, 40)}"`, Date.now() - start);
		} else {
			fail("Prompt detection", `No ❯ found. Last line: "${lastNonEmpty.trim().substring(0, 60)}"`, Date.now() - start);
		}
	} catch (e) {
		fail("Prompt detection", `${e}`, Date.now() - start);
	}
}

async function testInjectAndRespond() {
	const start = Date.now();
	// Use a real, useful prompt that dogfoods the project
	const testPrompt = "Run swift test in app/PairApp and report the results. If any tests fail, explain why.";

	try {
		const resp = await ipc({ action: "send_input", surface: SESSION_ID, text: testPrompt + "\r" });
		if (!resp.ok) {
			fail("Inject prompt", `IPC error: ${resp.error}`, Date.now() - start);
			return;
		}
		log(`  Injected: "${testPrompt}"`);
		log("  Waiting for Claude to start working...");

		// Wait for Claude to start (screen changes from just prompt)
		const { elapsed: startElapsed } = await waitFor(
			"Claude starts working",
			(s) => s.includes("Bash") || s.includes("swift test") || s.includes("thinking") || s.includes("Sprouting") || s.includes("Read"),
			30000,
		);
		pass("Claude starts", `Working after ${(startElapsed / 1000).toFixed(1)}s`, Date.now() - start);

		// Wait for Claude to finish (return to prompt)
		log("  Waiting for Claude to finish...");
		const { screen, elapsed: finishElapsed } = await waitFor(
			"Claude returns to ❯ prompt",
			(s) => {
				const lines = s.split("\n");
				// Look for ❯ in the last 6 lines (after work output)
				const tail = lines.slice(-6);
				return tail.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			},
			180000, // 3 min — tests take a while
		);

		// Check if tests were mentioned in output
		const hasTestOutput = screen.includes("Executed") || screen.includes("tests") || screen.includes("passed") || screen.includes("failed");
		pass("Claude completes", `Finished after ${(finishElapsed / 1000).toFixed(1)}s, test output: ${hasTestOutput}`, Date.now() - start);

	} catch (e) {
		fail("Inject and respond", `${e}`, Date.now() - start);
	}
}

async function testCodexReview() {
	const start = Date.now();
	const logStart = Date.now();

	try {
		// Wait for Codex to trigger a review (should happen within ~10s of Claude finishing)
		log("  Waiting for Codex review...");

		await sleep(15000); // Give monitor time to detect stability and call Codex

		const codexLogs = recentLogs("Codex (", logStart);
		const reviewLogs = recentLogs("triggering review", logStart);
		const feedbackLogs = recentLogs("feedback", logStart);

		if (codexLogs.length > 0) {
			const lastCodex = codexLogs[codexLogs.length - 1];
			pass("Codex review", `Codex responded: ${lastCodex.substring(lastCodex.indexOf("Codex (")).substring(0, 80)}`, Date.now() - start);
		} else if (reviewLogs.length > 0) {
			fail("Codex review", `Review triggered but no Codex response. Reviews: ${reviewLogs.length}`, Date.now() - start);
		} else {
			fail("Codex review", "No review triggered", Date.now() - start);
		}
	} catch (e) {
		fail("Codex review", `${e}`, Date.now() - start);
	}
}

async function testUserInputProtection() {
	const start = Date.now();

	try {
		// Wait for prompt
		await waitFor("Empty prompt", (s) => s.includes("❯"), 30000);

		// Simulate user typing (paste text WITHOUT submitting — no \r)
		const userText = "THIS IS USER INPUT DO NOT SUBMIT";
		await ipc({ action: "send_input", surface: SESSION_ID, text: userText });
		log("  Pasted user text (no Enter), waiting 10s...");

		await sleep(10000);

		// Read screen — the user text should still be there, NOT submitted
		const screen = await readScreen();
		const lines = screen.split("\n");
		const promptLine = lines.find(l => l.includes("❯") && l.includes(userText));

		if (promptLine) {
			pass("User input protection", "User text preserved at prompt after 10s", Date.now() - start);
		} else if (screen.includes(userText)) {
			// Text is on screen but maybe Claude processed it (was submitted)
			const claudeWorking = screen.includes("Sprouting") || screen.includes("thinking") || screen.includes("Read");
			if (claudeWorking) {
				fail("User input protection", "SYSTEM SUBMITTED USER INPUT — Claude is processing it", Date.now() - start);
			} else {
				pass("User input protection", "User text visible on screen (not at prompt but not submitted)", Date.now() - start);
			}
		} else {
			fail("User input protection", "User text disappeared from screen", Date.now() - start);
		}

		// Clean up: send Ctrl+U to clear the line, then Escape
		await ipc({ action: "send_key", surface: SESSION_ID, text: "ctrl-u" });
		await ipc({ action: "send_key", surface: SESSION_ID, text: "escape" });

	} catch (e) {
		fail("User input protection", `${e}`, Date.now() - start);
	}
}

// ── Main ───────────────────────────────────────────────────────────────

export async function runTestLoop() {
	log("PairApp automated test loop");
	log(`Project: ${PROJECT}`);
	log(`Session: ${SESSION_ID}`);
	log("");

	await testIpcConnection();
	if (!results[0].passed) {
		console.error("\nPairApp not running. Start it first.");
		process.exit(1);
	}

	await testCreateSession();
	await sleep(3000); // Let Claude Code start

	await testClaudeStartup();
	await testPromptDetection();
	await testInjectAndRespond();
	await testCodexReview();
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

	process.exit(failed > 0 ? 1 : 0);
}
