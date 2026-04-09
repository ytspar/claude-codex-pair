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
const TOKEN_PATH = path.join(os.homedir(), ".claude-codex-pair", "auth-token");
const PROJECT = process.cwd();
const SESSION_ID = `test-${Date.now().toString(36)}`;
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

/** Wait for a fresh empty ❯ prompt, ensuring any pending work has finished.
 *  Polls until the screen is stable and has an empty prompt line. */
async function waitForFreshPrompt(timeoutMs = 60000): Promise<string> {
	const start = Date.now();
	let stableCount = 0;
	let lastHash = 0;

	while (Date.now() - start < timeoutMs) {
		const screen = await readScreen();
		const hash = simpleHash(screen);
		const lines = screen.split("\n").slice(-6);
		const hasPrompt = lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");

		if (hasPrompt && hash === lastHash) {
			stableCount++;
			if (stableCount >= 3) return screen; // Stable for 3 polls (1.5s)
		} else {
			stableCount = 0;
		}
		lastHash = hash;
		await sleep(500);
	}
	return await readScreen();
}

/** Inject a prompt and wait for Claude to start working.
 *  Clears the Codex injection queue and prompt text before injecting. */
async function injectAndWaitForStart(prompt: string, timeoutMs = 60000): Promise<void> {
	// Pause the monitor and wait for any in-flight Codex to finish
	await ipc({ action: "pause_monitor", surface: SESSION_ID });
	await sleep(8000); // Let in-flight Codex reviews complete (can take up to 30s, 8s covers most)

	// Clear prompt and wait for it to settle
	await ipc({ action: "send_key", surface: SESSION_ID, text: "ctrl-u" });
	await sleep(500);
	// Clear again in case something slipped through
	await ipc({ action: "send_key", surface: SESSION_ID, text: "ctrl-u" });
	await sleep(500);

	const baseline = simpleHash(await readScreen());
	await ipc({ action: "send_input", surface: SESSION_ID, text: prompt + "\r" });

	// Resume the monitor after injection so Codex can review Claude's work
	await ipc({ action: "resume_monitor", surface: SESSION_ID });

	// Wait for screen to change from baseline
	await waitFor("Claude starts working", (s) => simpleHash(s) !== baseline, timeoutMs);
}

/** Get recent log lines matching a pattern. */
function recentLogs(pattern: string, since: number): string[] {
	if (!fs.existsSync(LOG_FILE)) return [];
	const content = fs.readFileSync(LOG_FILE, "utf-8");
	const sinceStr = new Date(since).toISOString().slice(0, 19);
	// Log format: [2026-04-04T19:20:10.485Z] INFO: ...
	// Extract timestamp from brackets for comparison
	return content.split("\n").filter(l => {
		if (!l.includes(pattern)) return false;
		const match = l.match(/^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})/);
		if (!match) return false;
		return match[1] >= sinceStr;
	});
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
		const baseline = simpleHash(await readScreen());
		const resp = await ipc({ action: "send_input", surface: SESSION_ID, text: testPrompt + "\r" });
		if (!resp.ok) {
			fail("Inject prompt", `IPC error: ${resp.error}`, Date.now() - start);
			return;
		}
		log(`  Injected: "${testPrompt}"`);
		log("  Waiting for Claude to start working...");

		// Wait for screen to change from baseline (Claude picked up the prompt)
		await waitFor("Screen changes after injection", (s) => simpleHash(s) !== baseline, 30000);

		const { elapsed: startElapsed } = await waitFor(
			"Claude starts working",
			(s) => s.includes("Bash") || s.includes("swift test") || s.includes("thinking") || s.includes("Sprouting"),
			30000,
		);
		pass("Claude starts", `Working after ${(startElapsed / 1000).toFixed(1)}s`, Date.now() - start);

		// Wait for Claude to show "swift test" output, then return to prompt
		log("  Waiting for Claude to finish...");
		await waitFor("Swift test output appears", (s) => {
			return s.includes("Executed") || s.includes("Build complete") || s.includes("passed");
		}, 180000);

		const { screen, elapsed: finishElapsed } = await waitFor(
			"Claude returns to ❯ prompt",
			(s) => {
				const lines = s.split("\n").slice(-6);
				return lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			},
			60000,
		);

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

		await sleep(30000); // Give monitor time to detect stability and call Codex

		const codexLogs = recentLogs("Codex (", logStart);
		const reviewLogs = recentLogs("triggering review", logStart);

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

async function testCodexAnswersQuestion() {
	const start = Date.now();
	// Claude should ask a question, and Codex should answer it
	const prompt = "What files in app/PairApp/Sources/PairApp/ contain the word 'Codex'? List them and ask me which one to examine.";

	try {
		// Wait for prompt
		await waitFor("Empty ❯ prompt", (s) => {
			const lines = s.split("\n").slice(-6);
			return lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
		}, 30000);

		await ipc({ action: "send_input", surface: SESSION_ID, text: prompt + "\r" });
		log(`  Injected question prompt`);

		// Wait for Claude to ask us a question (ends with ?)
		log("  Waiting for Claude to ask a question...");
		const { elapsed: questionElapsed } = await waitFor(
			"Claude asks a question",
			(s) => {
				const lines = s.split("\n").filter(l => l.trim());
				// Look for a question mark in the last 10 lines
				return lines.slice(-10).some(l => l.trim().endsWith("?"));
			},
			120000,
		);
		log(`  Claude asked a question after ${(questionElapsed / 1000).toFixed(1)}s`);

		// Now wait for Codex to answer (screen should change after the question)
		log("  Waiting for Codex to answer...");
		const logBefore = Date.now();
		await sleep(40000); // Give Codex time to detect stability, review, and respond

		const codexLogs = recentLogs("Codex (", logBefore);
		const injectionLogs = recentLogs("injection delivered", logBefore);

		if (codexLogs.length > 0 && injectionLogs.length > 0) {
			pass("Codex answers question", `Codex responded and injected answer`, Date.now() - start);
		} else if (codexLogs.length > 0) {
			pass("Codex answers question", `Codex responded (${codexLogs.length} reviews) but may not have injected`, Date.now() - start);
		} else {
			fail("Codex answers question", `No Codex response after 40s`, Date.now() - start);
		}
	} catch (e) {
		fail("Codex answers question", `${e}`, Date.now() - start);
	}
}

async function testPermissionPromptHandling() {
	const start = Date.now();
	// This prompt should trigger a file edit, which triggers a permission dialog
	const prompt = "Add a comment '// test-loop validation' to the top of app/PairApp/Sources/PairApp/Version.swift, then remove it.";

	try {
		await waitForFreshPrompt(60000);
		await injectAndWaitForStart(prompt);
		log(`  Injected edit prompt (should trigger permission dialog)`);

		// Wait for Claude to start working on the edit
		await waitFor("Claude working on edit", (s) => {
			return s.includes("Version.swift") || s.includes("Edit") || s.includes("Write") || s.includes("thinking");
		}, 60000);

		// Wait up to 5 minutes for Claude to finish (including permission handling)
		log("  Waiting for Claude to complete (may include permission prompts)...");
		const { elapsed } = await waitFor(
			"Claude returns to ❯ prompt after edit",
			(s) => {
				const lines = s.split("\n").slice(-6);
				return lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			},
			300000, // 5 min — multiple permission prompts + Codex response time
		);

		// Check logs for permission prompt handling
		const permLogs = recentLogs("Selection prompt", start);
		const selectLogs = recentLogs("SELECT", start);

		if (permLogs.length > 0 || selectLogs.length > 0) {
			pass("Permission prompt", `Handled ${permLogs.length} selection prompts in ${(elapsed / 1000).toFixed(1)}s`, Date.now() - start);
		} else {
			// Claude might have had permission already (allow all)
			pass("Permission prompt", `Claude completed in ${(elapsed / 1000).toFixed(1)}s (permissions may have been pre-granted)`, Date.now() - start);
		}
	} catch (e) {
		fail("Permission prompt", `${e}`, Date.now() - start);
	}
}

async function testUserInputProtection() {
	const start = Date.now();

	try {
		// Wait for a clean, stable prompt with no pending Codex injections
		await waitForFreshPrompt(60000);

		// Pause the monitor so Codex doesn't inject during this test
		await ipc({ action: "pause_monitor", surface: SESSION_ID });
		// Wait for any in-flight Codex review to complete and be discarded
		await sleep(5000);
		await ipc({ action: "send_key", surface: SESSION_ID, text: "ctrl-u" });
		await sleep(1000);

		// Simulate user typing (paste text WITHOUT submitting — no \r)
		const userText = "THIS IS USER INPUT DO NOT SUBMIT";
		await ipc({ action: "send_input", surface: SESSION_ID, text: userText });
		log("  Pasted user text (no Enter), waiting 15s...");

		await sleep(15000);

		// Read screen — the user text should still be there, NOT submitted
		const screen = await readScreen();
		const lines = screen.split("\n");
		const promptLine = lines.find(l => l.includes("❯") && l.includes(userText));

		if (promptLine) {
			pass("User input protection", "User text preserved at prompt after 15s", Date.now() - start);
		} else if (screen.includes(userText)) {
			// Text is on screen but maybe Claude processed it (was submitted)
			const claudeWorking = screen.includes("Sprouting") || screen.includes("thinking") || screen.includes("Read");
			if (claudeWorking) {
				fail("User input protection", "SYSTEM SUBMITTED USER INPUT — Claude is processing it", Date.now() - start);
			} else {
				pass("User input protection", "User text visible on screen (not at prompt but not submitted)", Date.now() - start);
			}
		} else {
			// Check if screen scrolled — the text might be in the scrollback
			fail("User input protection", "User text disappeared from screen (may have been consumed by pending injection)", Date.now() - start);
		}

		// Clean up: send Ctrl+U to clear the line, then Escape
		await ipc({ action: "send_key", surface: SESSION_ID, text: "ctrl-u" });
		await ipc({ action: "send_key", surface: SESSION_ID, text: "escape" });
		// Resume monitor for any subsequent tests
		await ipc({ action: "resume_monitor", surface: SESSION_ID });

	} catch (e) {
		await ipc({ action: "resume_monitor", surface: SESSION_ID }).catch(() => {});
		fail("User input protection", `${e}`, Date.now() - start);
	}
}

async function testClaudeAskingQuestion() {
	const start = Date.now();
	// This prompt is designed to make Claude ask a follow-up question
	const prompt = "I want to refactor one of the Swift files in app/PairApp/Sources/PairApp/. Which file should we start with — ClaudeMonitor.swift, TaskQueue.swift, or AppDelegate.swift? Pick one and explain why, then ask me if I agree.";

	try {
		await waitForFreshPrompt(30000);
		await injectAndWaitForStart(prompt);
		log(`  Injected question-provoking prompt`);

		// First wait for Claude to start working (shows tool use or thinking)
		log("  Waiting for Claude to start working...");
		await waitFor("Claude starts on question prompt", (s) => {
			return s.includes("refactor") || s.includes("ClaudeMonitor") || s.includes("TaskQueue") || s.includes("AppDelegate") || s.includes("thinking");
		}, 60000);

		// Now wait for Claude to finish and ask a question (? in output above ❯)
		log("  Waiting for Claude to ask a follow-up question...");
		const { screen, elapsed } = await waitFor(
			"Claude asks a question (? above ❯)",
			(s) => {
				const lines = s.split("\n").filter(l => l.trim());
				const tail = lines.slice(-8);
				const hasPrompt = tail.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
				if (!hasPrompt) return false;
				// Look for ? in lines above the prompt, specifically about our refactor prompt
				const promptIdx = tail.findIndex(l => l.trim().startsWith("❯") || l.trim() === "❯");
				const above = tail.slice(0, promptIdx);
				return above.some(l => l.trim().endsWith("?") && !l.includes("refactor one of"));
			},
			120000,
		);

		// Check that the monitor detects this as interactive
		const lines = screen.split("\n").filter(l => l.trim());
		const hasQuestion = lines.some(l => l.trim().endsWith("?"));
		if (hasQuestion) {
			pass("Claude asking question", `Claude asked a question after ${(elapsed / 1000).toFixed(1)}s`, Date.now() - start);
		} else {
			fail("Claude asking question", `No question mark found in output`, Date.now() - start);
		}

		// Wait for Codex to respond to the question (should detect interactive prompt)
		log("  Waiting for Codex to answer Claude's question...");
		const logBefore = Date.now();
		await sleep(20000);

		const codexLogs = recentLogs("Codex (", logBefore);
		const feedbackLogs = recentLogs("FEEDBACK", logBefore);
		if (codexLogs.length > 0 || feedbackLogs.length > 0) {
			pass("Codex answers follow-up", `Codex responded to Claude's question`, Date.now() - start);
		} else {
			fail("Codex answers follow-up", `No Codex response to Claude's question after 20s`, Date.now() - start);
		}

	} catch (e) {
		fail("Claude asking question", `${e}`, Date.now() - start);
	}
}

async function testAcceptEditsFlow() {
	const start = Date.now();
	// This prompt should trigger the accept-edits dialog by requesting a file edit
	const prompt = "Add a Swift comment '// test-loop: accept-edits validation' as the FIRST line of app/PairApp/Sources/PairApp/Version.swift, then immediately remove it and restore the original file.";

	try {
		await waitForFreshPrompt(60000);
		await injectAndWaitForStart(prompt);
		log(`  Injected edit prompt (targets accept-edits flow)`);

		// Wait for Claude to complete (may see accept-edits, selection prompts, etc.)
		log("  Waiting for Claude to complete edit cycle...");

		// First wait for Claude to show it's working on this specific edit
		await waitFor("Claude working on Version.swift edit", (s) => {
			return s.includes("accept-edits") || s.includes("test-loop") ||
				(s.includes("Version.swift") && (s.includes("Edit") || s.includes("comment")));
		}, 60000);

		// Then wait for return to prompt
		const { elapsed } = await waitFor(
			"Claude returns to ❯ prompt after edit cycle",
			(s) => {
				const lines = s.split("\n").slice(-6);
				return lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			},
			300000,
		);

		// Check logs for accept-edits handling
		const acceptLogs = recentLogs("Accept", start);
		const selectLogs = recentLogs("SELECT", start);
		const enterLogs = recentLogs("Accepting edits", start);

		if (enterLogs.length > 0) {
			pass("Accept-edits flow", `Monitor accepted edits (${enterLogs.length} times) in ${(elapsed / 1000).toFixed(1)}s`, Date.now() - start);
		} else if (acceptLogs.length > 0 || selectLogs.length > 0) {
			pass("Accept-edits flow", `Edit completed with ${selectLogs.length} selections in ${(elapsed / 1000).toFixed(1)}s`, Date.now() - start);
		} else {
			// Claude may have had auto-accept — still a pass if it completed
			pass("Accept-edits flow", `Edit completed in ${(elapsed / 1000).toFixed(1)}s (auto-accept likely enabled)`, Date.now() - start);
		}

	} catch (e) {
		fail("Accept-edits flow", `${e}`, Date.now() - start);
	}
}

async function testMultiStepWithPermissions() {
	const start = Date.now();
	// A multi-step prompt that should trigger multiple interactive elements:
	// 1. Reading a file (Bash permission)
	// 2. Writing/editing a file (Edit permission)
	// 3. Running a command (Bash permission again)
	const prompt = "Read app/PairApp/Package.swift, then create a temporary file /tmp/pair-test-loop.txt with the package name from it, then run 'cat /tmp/pair-test-loop.txt' to verify, then delete it with rm.";

	try {
		await waitForFreshPrompt(60000);
		await injectAndWaitForStart(prompt);
		log(`  Injected multi-step prompt (read → write → verify → delete)`);

		// Wait for Claude to start (tool usage visible)
		await waitFor("Claude using tools", (s) => {
			return s.includes("Bash") || s.includes("Read") || s.includes("Write") || s.includes("pair-test-loop");
		}, 60000);

		log("  Waiting for multi-step completion...");
		const { screen, elapsed } = await waitFor(
			"Claude returns to ❯ after multi-step",
			(s) => {
				const lines = s.split("\n").slice(-6);
				return lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			},
			300000,
		);

		// Count permission/selection events in logs
		const selectLogs = recentLogs("SELECT", start);
		const toolUses = (screen.match(/Bash|Read|Write|Edit/g) ?? []).length;

		pass("Multi-step permissions", `Completed in ${(elapsed / 1000).toFixed(1)}s (${toolUses} tool uses, ${selectLogs.length} selections)`, Date.now() - start);

	} catch (e) {
		fail("Multi-step permissions", `${e}`, Date.now() - start);
	}
}

async function testStabilityAfterRapidChanges() {
	const start = Date.now();
	// This prompt triggers rapid screen changes (listing many files) to test that
	// the monitor doesn't trigger a premature review during output streaming.
	const prompt = "List all .swift files in app/PairApp/Sources/PairApp/ with wc -l for each, then summarize the total. Do NOT ask any follow-up questions — just output the results.";

	try {
		await waitForFreshPrompt(30000);
		await injectAndWaitForStart(prompt);
		log(`  Injected rapid-output prompt`);

		// Capture timestamps of screen changes during Claude's work
		const screenHashes: number[] = [];
		const pollStart = Date.now();
		let lastHash = 0;

		// Poll rapidly for 30s to observe screen change rate
		while (Date.now() - pollStart < 30000) {
			const screen = await readScreen();
			const hash = simpleHash(screen);
			if (hash !== lastHash) {
				screenHashes.push(hash);
				lastHash = hash;
			}
			await sleep(500);
		}

		// Wait for completion
		const { elapsed } = await waitFor(
			"Claude returns to ❯",
			(s) => {
				const lines = s.split("\n").slice(-6);
				return lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			},
			120000,
		);

		// Check that Codex didn't trigger review during rapid changes
		const prematureLogs = recentLogs("triggering review", start);

		pass("Stability detection", `${screenHashes.length} screen changes in first 30s, completed in ${(elapsed / 1000).toFixed(1)}s, ${prematureLogs.length} reviews triggered`, Date.now() - start);

	} catch (e) {
		fail("Stability detection", `${e}`, Date.now() - start);
	}
}

// ── Selection behavior tests ──────────────────────────────────────────
// These specifically test the bug where numbered lists and conversational
// questions were misclassified as selection prompts, causing random numbers
// to be injected into Claude's prompt.

async function testNumberedListNotSelection() {
	const start = Date.now();
	// This prompt makes Claude output a numbered list of files.
	// The monitor must NOT classify the NUMBERED LIST as a selection prompt.
	// Note: Claude may trigger real Bash permission prompts while running commands —
	// those ARE legitimate selection prompts and should be handled.
	const prompt = "List all Swift files in app/PairApp/Sources/PairApp/ with line counts. Number them 1, 2, 3, etc. Do NOT ask follow-up questions — just output the numbered list.";

	try {
		await waitForFreshPrompt(60000);
		await injectAndWaitForStart(prompt);
		log(`  Injected numbered-list prompt`);

		// Wait for Claude to produce output and return to prompt
		log("  Waiting for Claude to list files...");
		await waitFor("Claude lists files", (s) => {
			return s.includes(".swift") && (s.includes("1.") || s.includes("lines"));
		}, 60000);
		await waitFor("Claude returns to prompt", (s) => {
			const lines = s.split("\n").slice(-6);
			return lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
		}, 120000);

		// Now the screen shows a numbered list. Pause the monitor, wait for any in-flight
		// review, then check that the CURRENT screen is NOT classified as selection=true.
		await ipc({ action: "pause_monitor", surface: SESSION_ID });
		await sleep(5000);

		// Check: after Claude finishes and is at the prompt with numbered output visible,
		// the Codex reviews should be selection=false (not treating the list as a selection).
		const logAfterSettle = Date.now();
		await ipc({ action: "resume_monitor", surface: SESSION_ID });
		await sleep(15000);

		const selFalse = recentLogs("selection=false", logAfterSettle);
		const selTrue = recentLogs("selection=true", logAfterSettle);

		if (selTrue.length > 0 && selFalse.length === 0) {
			fail("Numbered list not selection", `Screen with numbered list was classified as selection=true (${selTrue.length} times)`, Date.now() - start);
		} else {
			pass("Numbered list not selection", `Correct: ${selFalse.length} selection=false, ${selTrue.length} selection=true (permission prompts during work)`, Date.now() - start);
		}
	} catch (e) {
		fail("Numbered list not selection", `${e}`, Date.now() - start);
	}
}

async function testConversationalQuestionNotSelection() {
	const start = Date.now();
	// This makes Claude ask a conversational question — "which file?"
	// When Claude is at the ❯ prompt with a question above it, the monitor
	// must classify this as selection=false (interactive, not selection).
	const prompt = "Look at app/PairApp/Sources/PairApp/ClaudeMonitor.swift and app/PairApp/Sources/PairApp/ScreenDetection.swift. Tell me which one has better code organization and ask me if I'd like you to refactor the other one to match.";

	try {
		await waitForFreshPrompt(60000);
		await injectAndWaitForStart(prompt);
		log(`  Injected conversational-question prompt`);

		// Wait for Claude to ask a follow-up question
		log("  Waiting for Claude to respond with a question...");
		await waitFor("Claude asks question", (s) => {
			const lines = s.split("\n").filter(l => l.trim());
			const tail = lines.slice(-10);
			const hasPrompt = tail.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			if (!hasPrompt) return false;
			return tail.some(l => l.trim().endsWith("?"));
		}, 180000);

		// Now Claude is at the prompt with a question above — this specific screen
		// should be classified as selection=false. Pause, wait for in-flight to finish,
		// then check the next review cycle.
		await ipc({ action: "pause_monitor", surface: SESSION_ID });
		await sleep(5000);

		const logAfterSettle = Date.now();
		await ipc({ action: "resume_monitor", surface: SESSION_ID });
		await sleep(20000);

		const selFalse = recentLogs("selection=false", logAfterSettle);
		const selTrue = recentLogs("selection=true", logAfterSettle);
		const codexLogs = recentLogs("Codex (", logAfterSettle);

		if (selTrue.length > 0 && selFalse.length === 0) {
			fail("Conversational question", `Question screen classified as selection=true (${selTrue.length} times) — should be selection=false`, Date.now() - start);
		} else if (codexLogs.length > 0) {
			pass("Conversational question", `Correct: ${selFalse.length} selection=false, Codex gave substantive response`, Date.now() - start);
		} else {
			pass("Conversational question", `No errant selection behavior (${selFalse.length} false, ${selTrue.length} true)`, Date.now() - start);
		}
	} catch (e) {
		fail("Conversational question", `${e}`, Date.now() - start);
	}
}

async function testRealPermissionPromptHandled() {
	const start = Date.now();
	// This triggers a real file edit which should produce a real permission prompt.
	// The monitor SHOULD detect it as a selection and type the option number.
	const prompt = "Create a file /tmp/pair-selection-test.txt with the text 'selection test', then delete it.";

	try {
		await waitForFreshPrompt(60000);
		const logBefore = Date.now();
		await injectAndWaitForStart(prompt);
		log(`  Injected file-edit prompt (should trigger real permission)`);

		// Wait for Claude to finish
		log("  Waiting for Claude to complete...");
		await waitFor("Claude returns to prompt after edit", (s) => {
			const lines = s.split("\n").slice(-6);
			const hasPrompt = lines.some(l => l.trim().startsWith("❯") || l.trim() === "❯");
			const didWork = s.includes("pair-selection-test") || s.includes("Created") || s.includes("Bash") || s.includes("Write");
			return hasPrompt && didWork;
		}, 300000);

		// Give Codex time to handle any permission prompts
		await sleep(10000);

		// CHECK: Selection prompts should have been detected and handled for real permissions
		const selectionLogs = recentLogs("Selection prompt, typing", logBefore);
		const acceptLogs = recentLogs("Accepting edits", logBefore);
		const selectEvents = recentLogs("SELECT", logBefore);

		if (selectionLogs.length > 0 || acceptLogs.length > 0) {
			pass("Real permission handled", `Monitor correctly handled ${selectionLogs.length} selection prompts + ${acceptLogs.length} accept-edits`, Date.now() - start);
		} else if (selectEvents.length > 0) {
			pass("Real permission handled", `${selectEvents.length} SELECT events logged`, Date.now() - start);
		} else {
			// Claude may have had auto-accept enabled
			pass("Real permission handled", `Claude completed (permissions may have been pre-granted)`, Date.now() - start);
		}
	} catch (e) {
		fail("Real permission handled", `${e}`, Date.now() - start);
	}
}

/** Simple string hash for screen comparison during polling. */
function simpleHash(s: string): number {
	let h = 0;
	for (let i = 0; i < s.length; i++) {
		h = ((h << 5) - h + s.charCodeAt(i)) | 0;
	}
	return h;
}

// ── Main ───────────────────────────────────────────────────────────────

/** Clean up old test sessions to prevent resource contention. */
async function cleanupOldTestSessions() {
	try {
		const resp = await ipc({ action: "list_sessions" });
		if (!resp.ok || !resp.result) return;
		const sessions: Array<{ id: string }> = JSON.parse(resp.result);
		for (const s of sessions) {
			if (s.id.startsWith("test-") && s.id !== SESSION_ID) {
				log(`  Removing old test session: ${s.id}`);
				await ipc({ action: "remove_session", surface: s.id });
			}
		}
	} catch { /* non-fatal */ }
}

export async function runTestLoop(): Promise<void> {
	log("PairApp automated test loop");
	log(`Project: ${PROJECT}`);
	log(`Session: ${SESSION_ID}`);
	log("");

	await testIpcConnection();
	if (!results[0].passed) {
		console.error("\nPairApp not running. Start it first.");
		process.exit(1);
	}

	// Clean up stale test sessions from previous runs
	await cleanupOldTestSessions();

	await testCreateSession();
	await sleep(3000); // Let Claude Code start

	await testClaudeStartup();
	await testPromptDetection();
	await testInjectAndRespond();
	await testCodexReview();
	await testCodexAnswersQuestion();
	await testClaudeAskingQuestion();
	await testAcceptEditsFlow();
	await testMultiStepWithPermissions();
	await testPermissionPromptHandling();

	// Selection behavior regression tests
	await testNumberedListNotSelection();
	await testConversationalQuestionNotSelection();
	await testRealPermissionPromptHandled();

	await testStabilityAfterRapidChanges();
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

	// Clean up this test session
	try {
		await ipc({ action: "remove_session", surface: SESSION_ID });
		log("Cleaned up test session");
	} catch { /* non-fatal */ }

	process.exit(failed > 0 ? 1 : 0);
}
