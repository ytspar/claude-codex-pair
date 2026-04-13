/**
 * Capture Codex TUI screen patterns via PairApp IPC.
 * Creates a codexLeads session, sends prompts, and dumps the screen
 * buffer at intervals to analyze Codex's terminal rendering.
 *
 * Prerequisites: PairApp must be running with the latest build.
 * Usage: npx tsx scripts/capture-codex-screens.ts
 */
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

const SOCKET = path.join(os.homedir(), ".claude-codex-pair", "pair-terminal.sock");
const TOKEN_PATH = path.join(os.homedir(), ".claude-codex-pair", "auth-token");
const OUTPUT_DIR = path.join(process.cwd(), ".codex-pair", "screen-captures");
const SESSION_ID = `codex-capture-${Date.now().toString(36)}`;

fs.mkdirSync(OUTPUT_DIR, { recursive: true });

function readToken(): string {
	try { return fs.readFileSync(TOKEN_PATH, "utf-8").trim(); }
	catch { return ""; }
}

async function ipc(command: Record<string, unknown>): Promise<{ ok: boolean; result?: string; error?: string }> {
	return new Promise((resolve, reject) => {
		const client = net.createConnection(SOCKET);
		let data = "";
		const timer = setTimeout(() => { client.destroy(); reject(new Error("IPC timeout")); }, 10000);
		client.on("connect", () => client.write(JSON.stringify({ ...command, token: readToken() })));
		client.on("data", (d) => { data += d.toString(); });
		client.on("end", () => { clearTimeout(timer); try { resolve(JSON.parse(data)); } catch { reject(new Error(`Bad: ${data}`)); } });
		client.on("error", (e) => { clearTimeout(timer); reject(e); });
	});
}

async function readScreen(): Promise<string> {
	const resp = await ipc({ action: "read_screen", surface: SESSION_ID });
	return resp.ok ? (resp.result ?? "") : "";
}

function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)); }

let captureNum = 0;
function capture(label: string, screen: string) {
	captureNum++;
	const name = `${String(captureNum).padStart(3, "0")}-${label}.txt`;
	fs.writeFileSync(path.join(OUTPUT_DIR, name), screen);

	const lines = screen.split("\n").filter(l => l.trim());
	console.log(`\n[${captureNum}] ${label} (${lines.length} lines, ${screen.length} chars)`);
	console.log("─".repeat(80));
	// Show last 15 non-empty lines
	for (const l of lines.slice(-15)) {
		console.log(`  ${l.substring(0, 100)}`);
	}
}

async function main() {
	console.log("=== Codex TUI Screen Capture ===\n");

	// Verify PairApp is running
	const check = await ipc({ action: "list_sessions" });
	if (!check.ok) { console.error("PairApp not running"); process.exit(1); }

	// Create a Codex-mode session
	// Note: we need to pass mode via a field. Currently create_session doesn't support mode,
	// so we'll create a normal session and the mode was set in the code.
	// Actually, let's just create the session — the mode is on PairSession, defaulting to claudeLeads.
	// We need to either update the IPC or manually set mode. For now, let's add mode to the IPC request.
	console.log(`Creating Codex session: ${SESSION_ID}`);
	// Append :codex to surface ID to trigger codexLeads mode
	const createResp = await ipc({ action: "create_session", surface: SESSION_ID + ":codex", text: process.cwd() });
	if (!createResp.ok) { console.error("Failed to create session:", createResp.error); process.exit(1); }

	// Wait for startup
	console.log("Waiting for session to start...");
	await sleep(10000);
	capture("startup", await readScreen());

	// Send first prompt
	console.log("\nSending prompt 1: list files...");
	await ipc({ action: "send_input", surface: SESSION_ID, text: "What files are in app/PairApp/Sources/PairApp/? Just list filenames.\r" });
	await sleep(5000);
	capture("prompt1-working", await readScreen());
	await sleep(15000);
	capture("prompt1-done", await readScreen());

	// Send second prompt
	console.log("\nSending prompt 2: line count...");
	await ipc({ action: "send_input", surface: SESSION_ID, text: "How many lines is ClaudeMonitor.swift?\r" });
	await sleep(5000);
	capture("prompt2-working", await readScreen());
	await sleep(15000);
	capture("prompt2-done", await readScreen());

	// Try to trigger a permission prompt
	console.log("\nSending prompt 3: file creation (may trigger permission)...");
	await ipc({ action: "send_input", surface: SESSION_ID, text: "Create a file /tmp/codex-test-capture.txt with 'hello world'\r" });
	await sleep(5000);
	capture("prompt3-permission-maybe", await readScreen());
	await sleep(15000);
	capture("prompt3-done", await readScreen());

	// Idle state
	await sleep(5000);
	capture("final-idle", await readScreen());

	// Cleanup
	await ipc({ action: "remove_session", surface: SESSION_ID });
	console.log(`\n\nDone! ${captureNum} captures saved to ${OUTPUT_DIR}`);
	console.log("Analyze the files to identify Codex TUI patterns.\n");

	// Summary: what unique patterns did we find?
	console.log("=== Pattern Analysis ===");
	const allScreens = fs.readdirSync(OUTPUT_DIR)
		.filter(f => f.endsWith(".txt"))
		.map(f => fs.readFileSync(path.join(OUTPUT_DIR, f), "utf-8"));

	const allText = allScreens.join("\n");
	const patterns = [
		["❯ (Claude prompt)", /❯/g],
		["› (guillemet)", /›/g],
		["> (angle bracket)", /^>/gm],
		["Enter to select", /enter to select/gi],
		["↑/↓ navigate", /[↑↓]/g],
		["Do you want", /do you want/gi],
		["Allow", /allow/gi],
		["Permission", /permission/gi],
		["Sandbox", /sandbox/gi],
		["[S] marker", /\[S\]/g],
		["● (bullet)", /●/g],
		["⠋⠙ (spinner)", /[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/g],
	] as const;

	for (const [name, regex] of patterns) {
		const matches = allText.match(regex);
		console.log(`  ${name}: ${matches?.length ?? 0} occurrences`);
	}

	process.exit(0);
}

main().catch(e => { console.error(e); process.exit(1); });
