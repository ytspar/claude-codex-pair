#!/usr/bin/env node
import { spawn, type ChildProcess } from "node:child_process";
import path from "node:path";
import fs from "node:fs";
import { Command } from "commander";
import { render } from "ink";
import { MonitorApp } from "./ui/MonitorApp.js";
import { installHook, removeHook, isHookInstalled } from "./monitor/daemon.js";
import { findActiveSessions, getMostRecentSession, isProcessAlive } from "./monitor/session-watcher.js";
import { readState, removeState, listActiveStates } from "./monitor/state.js";
import { callCodex, isCodexAvailable } from "./codex/client.js";
import { buildReviewPrompt } from "./codex/prompt-builder.js";
import { gitDiff } from "./shared/git.js";
import { getConversationContext } from "./monitor/transcript.js";
import { loadConfig, saveConfig } from "./shared/config.js";
import { generateReport } from "./report/generator.js";
import { listSessions } from "./report/logger.js";
import { bold, cyan, dim, green, red, yellow, decisionColor } from "./shared/formatter.js";

/** Launch pair-terminal daemon and return the child process. */
function launchPairTerminal(): ChildProcess | null {
	const binaryPath = path.resolve(import.meta.dirname, "pair-terminal");
	if (!fs.existsSync(binaryPath)) {
		return null;
	}

	const child = spawn(binaryPath, [], {
		stdio: ["ignore", "ignore", "ignore"],
		detached: true,
	});

	child.unref();

	return child;
}

const program = new Command();

program.name("pair").description("Codex reviews active Claude Code sessions").version("0.1.0");

// ── pair start ──────────────────────────────────────────────────────────
program
	.command("start")
	.description("Launch monitor: install hooks and start TUI dashboard")
	.option("-s, --session <id>", "Target a specific session ID")
	.action(async (opts: { session?: string }) => {
		// Check codex availability
		if (!(await isCodexAvailable())) {
			console.error(red("Error: codex CLI not found on PATH."));
			console.error(dim("Install it: npm install -g @openai/codex"));
			process.exit(1);
		}

		// Install hook
		const { installed, hookCommand } = installHook();
		if (installed) {
			console.log(green("✓ Stop hook installed"));
			console.log(dim(`  command: ${hookCommand}`));
		} else {
			console.log(yellow("Hook already installed, skipping"));
		}

		const project = process.cwd();
		const sessionId = opts.session;

		// Scope the hook to targeted session/project if specified
		const config = loadConfig();
		if (sessionId) {
			config.targetSessions = [sessionId];
		} else {
			config.targetSessions = null; // monitor all
		}
		saveConfig(config);

		const allSessions = findActiveSessions();
		console.log(dim(`Found ${allSessions.length} active session(s)`));
		for (const s of allSessions) {
			console.log(dim(`  ${s.sessionId.slice(0, 12)}  ${s.cwd.split("/").pop()}`));
		}

		// Launch pair-terminal daemon for reliable input injection
		const ptChild = launchPairTerminal();
		if (ptChild) {
			console.log(green("✓ pair-terminal daemon started"));
		} else {
			console.log(dim("pair-terminal binary not found  - using Ghostty/hook fallback"));
		}

		// Hook is ONLY active while pair start is running
		let cleaned = false;
		const cleanup = () => {
			if (cleaned) return;
			cleaned = true;
			removeHook();
			if (ptChild && !ptChild.killed) {
				ptChild.kill("SIGTERM");
			}
			console.log(dim("\nHook removed, pair-terminal stopped. Goodbye."));
		};
		process.on("SIGINT", () => {
			cleanup();
			process.exit(0);
		});
		process.on("SIGTERM", () => {
			cleanup();
			process.exit(0);
		});
		process.on("exit", cleanup);

		console.log(green("\nStarting monitor...\n"));
		console.log(dim("Hook is active ONLY while this TUI is running. Press q to quit and remove hook.\n"));
		render(<MonitorApp sessionId={sessionId} project={project} />);
	});

// ── pair stop ───────────────────────────────────────────────────────────
program
	.command("stop")
	.description("Remove hooks (safety net  - quitting pair start already cleans up)")
	.option("-s, --session <id>", "Clean up a specific session")
	.action((opts: { session?: string }) => {
		const removed = removeHook();
		if (removed) {
			console.log(green("✓ Hooks removed"));
		} else {
			console.log(yellow("No hook found to remove"));
		}

		if (opts.session) {
			removeState(opts.session);
			console.log(dim(`Cleaned up state for session ${opts.session}`));
		}
	});

// ── pair launch ─────────────────────────────────────────────────────────
program
	.command("launch [directory]")
	.description("Launch a Claude session in PairApp (Codex can inject input)")
	.option("--id <id>", "Session ID")
	.action(async (directory?: string, opts?: { id?: string }) => {
		const cwd = directory ? path.resolve(directory) : process.cwd();
		const id = opts?.id ?? `pair-${Date.now().toString(36)}`;
		const appBinary = path.resolve(import.meta.dirname, "..", "app", "PairApp", ".build", "debug", "PairApp");
		const releaseBinary = path.resolve(import.meta.dirname, "..", "app", "PairApp", ".build", "release", "PairApp");
		const binary = fs.existsSync(releaseBinary) ? releaseBinary : appBinary;

		const appDir = path.resolve(import.meta.dirname, "..", "app", "PairApp");
		const sourcesDir = path.join(appDir, "Sources");
		const appBundleBinary = "/Applications/Pair.app/Contents/MacOS/Pair";
		const { execFileSync, execFile: ef2 } = await import("node:child_process");

		// Build if sources are newer than binary
		if (fs.existsSync(sourcesDir)) {
			const binaryExists = fs.existsSync(binary);
			let needsBuild = !binaryExists;

			if (binaryExists) {
				try {
					const newer = execFileSync("find", [sourcesDir, "-name", "*.swift", "-newer", binary], { encoding: "utf-8" });
					if (newer.trim().length > 0) needsBuild = true;
				} catch { /* ignore */ }
			}

			if (needsBuild) {
				console.log(dim("Building PairApp (sources changed)..."));
				try {
					execFileSync("swift", ["build"], { cwd: appDir, stdio: "inherit" });
					console.log(green("✓ Build complete"));
				} catch {
					console.error(red("Build failed"));
					process.exit(1);
				}
			}

			// Always sync /Applications/Pair.app with the latest build
			if (fs.existsSync(appBundleBinary) && fs.existsSync(binary)) {
				const buildStat = fs.statSync(binary);
				const appStat = fs.statSync(appBundleBinary);
				if (buildStat.mtimeMs > appStat.mtimeMs) {
					fs.copyFileSync(binary, appBundleBinary);
					try {
							execFileSync("xattr", ["-cr", "/Applications/Pair.app"]);
							execFileSync("codesign", ["--force", "--deep", "--sign", "-", "/Applications/Pair.app"]);
						} catch { /* */ }
					console.log(dim("Updated /Applications/Pair.app"));
				}
			}
		}

		// Check if PairApp is already running
		const { isPairTerminalRunning } = await import("./shared/pair-terminal.js");
		const appRunning = await isPairTerminalRunning();

		if (appRunning) {
			console.log(dim("PairApp already running"));
		} else {
			if (fs.existsSync("/Applications/Pair.app")) {
				console.log(dim("Starting Pair.app..."));
				ef2("open", ["/Applications/Pair.app"], () => {});
			} else if (fs.existsSync(binary)) {
				console.log(dim("Starting PairApp..."));
				const child = spawn(binary, [], { stdio: "ignore", detached: true });
				child.unref();
			} else {
				console.error(red("PairApp not found. Build with: cd app/PairApp && swift build"));
				process.exit(1);
			}

			// Wait for IPC to be ready
			for (let i = 0; i < 20; i++) {
				await new Promise((r) => setTimeout(r, 500));
				if (await isPairTerminalRunning()) break;
			}

			if (!(await isPairTerminalRunning())) {
				console.error(red("PairApp failed to start"));
				process.exit(1);
			}
		}

		// Create session via IPC
		const net = await import("node:net");
		const socketPath = path.join(process.env.HOME ?? "", ".claude-codex-pair", "pair-terminal.sock");
		await new Promise<void>((resolve, reject) => {
			const client = net.createConnection(socketPath);
			client.on("connect", () => {
				client.write(JSON.stringify({ action: "create_session", surface: id, text: cwd }));
			});
			client.on("data", (d) => {
				const resp = JSON.parse(d.toString());
				if (resp.ok) {
					console.log(green(`✓ Launched Claude session: ${id}`));
					console.log(dim(`  directory: ${cwd}`));
					console.log(dim(`  Codex injects input via PairApp IPC`));
				} else {
					console.error(red(`Failed: ${resp.error}`));
				}
				client.destroy();
				resolve();
				// Bring PairApp to front (fire and forget, after resolve)
				import("node:child_process").then(({ execFile: ef }) => {
					ef("osascript", ["-e", `tell application "System Events" to set frontmost of process "Pair" to true`], () => {});
				}).catch(() => {});
			});
			client.on("error", (e) => { reject(e); });
			setTimeout(() => reject(new Error("timeout")), 5000);
		});
	});

// ── pair status ─────────────────────────────────────────────────────────
program
	.command("status")
	.description("Show current status of all sessions")
	.option("-s, --session <id>", "Check a specific session")
	.action((opts: { session?: string }) => {
		const hookActive = isHookInstalled();
		console.log(`Hook installed: ${hookActive ? green("yes") : dim("no")}\n`);

		const sessions = findActiveSessions();
		if (sessions.length === 0) {
			console.log(dim("No active Claude Code sessions found."));
			return;
		}

		console.log(bold(`Active sessions (${sessions.length}):\n`));
		for (const s of sessions) {
			const alive = isProcessAlive(s.pid);
			const status = alive ? green("running") : dim("stopped");
			const project = s.cwd.split("/").pop() ?? s.cwd;
			const state = readState(s.sessionId);

			console.log(`  ${cyan(s.sessionId.slice(0, 12))}  ${bold(project.padEnd(25))} ${status}`);
			if (state) {
				const decision = state.lastDecision ? decisionColor(state.lastDecision) : dim("none");
				console.log(`    cycle: ${state.cycle}  status: ${state.status}  last: ${decision}`);
			}
		}

		// Show detail for specific session if requested
		if (opts.session) {
			const state = readState(opts.session);
			if (state) {
				console.log(`\n${bold("Session detail:")} ${opts.session}`);
				console.log(`  Cycle: ${bold(String(state.cycle))}`);
				console.log(`  Status: ${state.status}`);
				if (state.lastDecision) console.log(`  Last decision: ${decisionColor(state.lastDecision)}`);
				if (state.lastResponse) console.log(`  Response: ${state.lastResponse.slice(0, 200)}`);
			}
		}
	});

// ── pair review ─────────────────────────────────────────────────────────
program
	.command("review")
	.description("One-shot: Codex reviews current diff")
	.option("-s, --session <id>", "Session to review")
	.action(async (opts: { session?: string }) => {
		if (!(await isCodexAvailable())) {
			console.error(red("Error: codex CLI not found on PATH."));
			process.exit(1);
		}

		const config = loadConfig();
		const cwd = process.cwd();

		// Gather context  - use specified session or most recent
		const diffResult = await gitDiff(cwd);
		let sessionContext = "";
		const allSessions = findActiveSessions();
		const targetSession = opts.session
			? allSessions.find((s) => s.sessionId.startsWith(opts.session!) || s.cwd.includes(opts.session!))
			: getMostRecentSession();
		if (targetSession) {
			sessionContext = getConversationContext(targetSession.transcriptPath);
		}

		console.log(dim("Running Codex review..."));
		const prompt = buildReviewPrompt({ cwd, diffResult, sessionContext });
		const result = await callCodex({
			prompt,
			cwd,
			timeout: config.codexTimeout,
			model: config.codexModel,
		});

		console.log(`\n${decisionColor(result.decision)}`);
		console.log(result.response);
		console.log(dim(`\n(${(result.durationMs / 1000).toFixed(1)}s)`));
	});

// ── pair report ─────────────────────────────────────────────────────────
program
	.command("report")
	.description("Generate markdown report for a session")
	.option("-s, --session <id>", "Session to report on")
	.action((opts: { session?: string }) => {
		let sessionId = opts.session;

		if (!sessionId) {
			const sessions = listSessions();
			if (sessions.length === 0) {
				console.error(red("No sessions found."));
				process.exit(1);
			}
			sessionId = sessions[sessions.length - 1];
			console.error(dim(`Using most recent session: ${sessionId}`));
		}

		console.log(generateReport(sessionId));
	});

// ── pair screenshot ────────────────────────────────────────────────────
program
	.command("screenshot")
	.description("Capture a screenshot (screen, app window, or website)")
	.option("-a, --app <name>", "Capture a specific app window by name")
	.option("-u, --url <url>", "Capture a website via Playwright or WebKit")
	.option("-r, --region <x,y,w,h>", "Capture a screen region")
	.action(async (opts: { app?: string; url?: string; region?: string }) => {
		const { captureScreen, captureApp, captureWebsite, captureRegion } = await import("./screenshots/capture.js");

		let result: string | null = null;

		if (opts.url) {
			console.log(dim(`Capturing website: ${opts.url}`));
			result = await captureWebsite(opts.url);
		} else if (opts.app) {
			console.log(dim(`Capturing app: ${opts.app}`));
			result = await captureApp(opts.app);
		} else if (opts.region) {
			const parts = opts.region.split(",").map(Number);
			if (parts.length === 4 && parts.every((n) => !Number.isNaN(n))) {
				console.log(dim(`Capturing region: ${opts.region}`));
				result = await captureRegion(parts[0], parts[1], parts[2], parts[3]);
			} else {
				console.error(red("Region must be x,y,width,height (e.g. 0,0,800,600)"));
				process.exit(1);
			}
		} else {
			console.log(dim("Capturing full screen..."));
			result = await captureScreen();
		}

		if (result) {
			console.log(green(`✓ Screenshot saved: ${result}`));
		} else {
			console.error(red("Screenshot failed"));
			process.exit(1);
		}
	});

// ── pair test-loop ─────────────────────────────────────────────────────
program
	.command("test-loop")
	.description("Automated test: create session, inject tasks, verify monitor loop works end-to-end")
	.action(async () => {
		const { runTestLoop } = await import("./watch/test-loop.js");
		await runTestLoop();
	});

// ── pair watch ─────────────────────────────────────────────────────────
program
	.command("watch")
	.description("Auto-rebuild daemon: watches Swift sources, builds, tests, hot-restarts PairApp")
	.action(async () => {
		const { startWatchDaemon } = await import("./watch/rebuild-daemon.js");
		await startWatchDaemon();
	});

// ── pair config ─────────────────────────────────────────────────────────
const configCmd = program
	.command("config")
	.description("Manage configuration")
	.action(() => {
		// Bare `pair config` shows config (same as `pair config show`)
		const config = loadConfig();
		console.log(JSON.stringify(config, null, 2));
	});

configCmd.command("show").action(() => {
	const config = loadConfig();
	console.log(JSON.stringify(config, null, 2));
});

configCmd
	.command("set")
	.argument("<key>", "Config key")
	.argument("<value>", "Config value")
	.action((key: string, value: string) => {
		const config = loadConfig();
		if (!(key in config)) {
			console.error(red(`Unknown config key: ${key}`));
			console.error(dim(`Valid keys: ${Object.keys(config).join(", ")}`));
			process.exit(1);
		}

		// Type-specific validation
		let parsed: unknown;
		if (key === "targetSessions") {
			// Must be null or a JSON array of strings
			if (value === "null") {
				parsed = null;
			} else if (value.startsWith("[")) {
				try {
					const arr = JSON.parse(value);
					if (!Array.isArray(arr) || !arr.every((v: unknown) => typeof v === "string")) {
						console.error(red("targetSessions must be null or a JSON array of strings, e.g. '[\"my-project\"]'"));
						process.exit(1);
					}
					parsed = arr;
				} catch {
					console.error(red(`Invalid JSON: ${value}`));
					process.exit(1);
				}
			} else {
				// Convenience: bare string → single-element array
				parsed = [value];
			}
		} else {
			// Generic scalar coercion
			parsed = value;
			if (value === "null") parsed = null;
			else if (value === "true") parsed = true;
			else if (value === "false") parsed = false;
			else if (/^\d+$/.test(value)) parsed = Number.parseInt(value, 10);
		}

		(config as unknown as Record<string, unknown>)[key] = parsed;
		saveConfig(config);
		console.log(green(`✓ ${key} = ${JSON.stringify(parsed)}`));
	});

program.parse();
