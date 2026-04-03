/**
 * Auto-rebuild daemon for PairApp.
 *
 * Watches Swift sources for changes, rebuilds, and hot-restarts the running app.
 * This closes the self-improvement loop: code change → build → restart → verify.
 *
 * Usage: pair watch
 */
import { watch, type FSWatcher } from "node:fs";
import { execFileSync, spawn } from "node:child_process";
import path from "node:path";
import fs from "node:fs";
import { isPairTerminalRunning, listSurfaces } from "../shared/pair-terminal.js";
import type { ChildProcess } from "node:child_process";

const ROOT = path.resolve(import.meta.dirname, "..", "..");
const APP_DIR = path.join(ROOT, "app", "PairApp");
const SOURCES_DIR = path.join(APP_DIR, "Sources");
const TESTS_DIR = path.join(APP_DIR, "Tests");
const BINARY = path.join(APP_DIR, ".build", "debug", "PairApp");
const APP_BUNDLE = "/Applications/Pair.app/Contents/MacOS/Pair";

interface WatchState {
	building: boolean;
	lastBuildTime: number;
	lastBuildSuccess: boolean;
	lastError: string | null;
	buildCount: number;
	restartCount: number;
	crashCount: number;
	lastCrashLog: string | null;
	debounceTimer: ReturnType<typeof setTimeout> | null;
	watchers: FSWatcher[];
	appProcess: ChildProcess | null;
}

const state: WatchState = {
	building: false,
	lastBuildTime: 0,
	lastBuildSuccess: true,
	lastError: null,
	buildCount: 0,
	restartCount: 0,
	crashCount: 0,
	lastCrashLog: null,
	debounceTimer: null,
	watchers: [],
	appProcess: null,
};

function log(msg: string) {
	const ts = new Date().toLocaleTimeString("en-US", { hour12: false });
	console.log(`[${ts}] ${msg}`);
}

function logError(msg: string) {
	const ts = new Date().toLocaleTimeString("en-US", { hour12: false });
	console.error(`[${ts}] ✗ ${msg}`);
}

function logSuccess(msg: string) {
	const ts = new Date().toLocaleTimeString("en-US", { hour12: false });
	console.log(`[${ts}] ✓ ${msg}`);
}

/** Find all Swift source files recursively. */
function findSwiftFiles(dir: string): string[] {
	const files: string[] = [];
	if (!fs.existsSync(dir)) return files;
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			files.push(...findSwiftFiles(full));
		} else if (entry.name.endsWith(".swift")) {
			files.push(full);
		}
	}
	return files;
}

/** Find the PID of the running PairApp process. */
function findPairAppPid(): number | null {
	try {
		const output = execFileSync("pgrep", ["-f", "PairApp"], { encoding: "utf-8" }).trim();
		const pids = output.split("\n").map(Number).filter(Boolean);
		return pids[0] ?? null;
	} catch {
		return null;
	}
}

/** Build PairApp. Returns { success, durationMs, error }. */
function build(): { success: boolean; durationMs: number; error: string | null } {
	const start = Date.now();
	try {
		execFileSync("swift", ["build"], {
			cwd: APP_DIR,
			stdio: ["ignore", "pipe", "pipe"],
			timeout: 120_000,
		});
		const durationMs = Date.now() - start;

		// Sync to /Applications/Pair.app if it exists
		if (fs.existsSync(APP_BUNDLE) && fs.existsSync(BINARY)) {
			try {
				fs.copyFileSync(BINARY, APP_BUNDLE);
				execFileSync("xattr", ["-cr", "/Applications/Pair.app"]);
				execFileSync("codesign", ["--force", "--deep", "--sign", "-", "/Applications/Pair.app"]);
			} catch { /* non-fatal */ }
		}

		return { success: true, durationMs, error: null };
	} catch (err: unknown) {
		const durationMs = Date.now() - start;
		const message = err instanceof Error ? (err as { stderr?: Buffer }).stderr?.toString() ?? err.message : String(err);
		return { success: false, durationMs, error: message };
	}
}

/** Ensure a Claude session exists for the project directory.
 *  If no session points at ROOT, create one via IPC. */
async function ensureProjectSession(): Promise<string | null> {
	try {
		const surfaces = await listSurfaces();
		const existing = surfaces.find(s => s.cwd === ROOT || ROOT.startsWith(s.cwd));
		if (existing) {
			log(`Session exists: ${existing.id} (${existing.cwd})`);
			return existing.id;
		}

		// Create a new session via IPC
		const net = await import("node:net");
		const socketPath = path.join(process.env.HOME ?? "", ".claude-codex-pair", "pair-terminal.sock");
		const sessionId = `watch-${Date.now().toString(36)}`;

		await new Promise<void>((resolve, reject) => {
			const client = net.createConnection(socketPath);
			client.on("connect", () => {
				client.write(JSON.stringify({ action: "create_session", surface: sessionId, text: ROOT }));
			});
			client.on("data", (d) => {
				const resp = JSON.parse(d.toString());
				if (resp.ok) {
					logSuccess(`Created session: ${sessionId} → ${ROOT}`);
				} else {
					logError(`Failed to create session: ${resp.error}`);
				}
				client.destroy();
				resolve();
			});
			client.on("error", (e) => reject(e));
			setTimeout(() => reject(new Error("timeout")), 5000);
		});
		return sessionId;
	} catch (err) {
		logError(`Failed to ensure session: ${err}`);
		return null;
	}
}

/** Kill old PairApp and start new one.
 *  Launches as a managed child process to capture crash output. */
async function hotRestart(): Promise<boolean> {
	// Kill existing process (managed or orphan)
	if (state.appProcess && !state.appProcess.killed) {
		state.appProcess.kill("SIGTERM");
		state.appProcess = null;
	}
	const oldPid = findPairAppPid();
	if (oldPid) {
		log(`Stopping PairApp (PID ${oldPid})...`);
		try {
			process.kill(oldPid, "SIGTERM");
			for (let i = 0; i < 30; i++) {
				await new Promise(r => setTimeout(r, 100));
				try { process.kill(oldPid, 0); } catch { break; }
			}
		} catch { /* already dead */ }
	}

	if (!fs.existsSync(BINARY)) {
		logError(`Binary not found: ${BINARY}`);
		return false;
	}

	log("Starting PairApp...");
	let stderrBuf = "";
	const child = spawn(BINARY, [], {
		stdio: ["ignore", "ignore", "pipe"],
		detached: false,  // Keep as child so we detect crashes
	});
	state.appProcess = child;

	child.stderr?.on("data", (chunk: Buffer) => {
		stderrBuf += chunk.toString();
		// Keep only last 2000 chars
		if (stderrBuf.length > 2000) stderrBuf = stderrBuf.slice(-2000);
	});

	child.on("exit", (code, signal) => {
		if (code === 0 || signal === "SIGTERM") return;  // Clean exit
		state.crashCount++;
		state.lastCrashLog = stderrBuf || `exit code ${code}, signal ${signal}`;
		logError(`PairApp crashed (exit=${code}, signal=${signal}, crash #${state.crashCount})`);
		if (stderrBuf) {
			const lines = stderrBuf.split("\n").filter(l => l.trim()).slice(-8);
			for (const line of lines) console.error(`  ${line}`);
		}
		// Write crash log for debugging / Codex to read
		const crashLogPath = path.join(ROOT, ".codex-pair", "crash.log");
		try {
			fs.mkdirSync(path.dirname(crashLogPath), { recursive: true });
			const entry = `\n--- Crash #${state.crashCount} at ${new Date().toISOString()} ---\nexit=${code} signal=${signal}\n${stderrBuf}\n`;
			fs.appendFileSync(crashLogPath, entry);
		} catch { /* non-fatal */ }
		state.appProcess = null;
	});

	// Verify via IPC (wait up to 10s)
	for (let i = 0; i < 20; i++) {
		await new Promise(r => setTimeout(r, 500));
		if (await isPairTerminalRunning()) return true;
		// If process already exited, don't keep waiting
		if (child.exitCode !== null) return false;
	}
	return false;
}

/** Run tests. Returns { success, output }. */
function runTests(): { success: boolean; output: string } {
	try {
		const output = execFileSync("swift", ["test"], {
			cwd: APP_DIR,
			encoding: "utf-8",
			timeout: 120_000,
		});
		return { success: true, output };
	} catch (err: unknown) {
		const output = err instanceof Error ? (err as { stdout?: string }).stdout ?? err.message : String(err);
		return { success: false, output };
	}
}

/** Handle a file change: debounce, build, test, restart. */
function onFileChanged(filename: string) {
	if (state.building) return;

	if (state.debounceTimer) clearTimeout(state.debounceTimer);
	state.debounceTimer = setTimeout(async () => {
		state.building = true;
		state.buildCount++;
		const shortName = filename.replace(ROOT + "/", "");
		log(`Change detected: ${shortName} (build #${state.buildCount})`);

		// Step 1: Build
		log("Building...");
		const buildResult = build();
		state.lastBuildTime = buildResult.durationMs;

		if (!buildResult.success) {
			state.lastBuildSuccess = false;
			state.lastError = buildResult.error;
			logError(`Build failed (${(buildResult.durationMs / 1000).toFixed(1)}s)`);
			if (buildResult.error) {
				const lines = buildResult.error.split("\n").filter(l => l.trim());
				for (const line of lines.slice(-10)) {
					console.error(`  ${line}`);
				}
			}
			state.building = false;
			return;
		}
		logSuccess(`Build OK (${(buildResult.durationMs / 1000).toFixed(1)}s)`);
		state.lastBuildSuccess = true;
		state.lastError = null;

		// Step 2: Run tests
		log("Testing...");
		const testResult = runTests();
		if (!testResult.success) {
			logError("Tests failed — skipping restart");
			const failLines = testResult.output.split("\n").filter(l => l.includes("FAIL") || l.includes("failed"));
			for (const line of failLines.slice(-5)) {
				console.error(`  ${line}`);
			}
			state.building = false;
			return;
		}
		const testMatch = testResult.output.match(/Executed (\d+) tests?, with (\d+) failures?/);
		const testSummary = testMatch ? `${testMatch[1]} tests, ${testMatch[2]} failures` : "tests passed";
		logSuccess(`Tests OK (${testSummary})`);

		// Step 3: Hot restart
		const started = await hotRestart();
		if (started) {
			state.restartCount++;
			logSuccess(`PairApp restarted (restart #${state.restartCount})`);
			// Ensure project session exists after restart
			await ensureProjectSession();
		} else {
			logError("PairApp failed to start — IPC not responding");
		}

		state.building = false;
	}, 500);
}

/** Set up recursive file watchers on Swift sources.
 *  Uses `recursive: true` (macOS FSEvents) for reliable detection
 *  of atomic writes and new file creation. */
function watchDirectories() {
	const watchRoots = [SOURCES_DIR, TESTS_DIR, APP_DIR];

	for (const dir of watchRoots) {
		if (!fs.existsSync(dir)) continue;
		try {
			// recursive: true uses FSEvents on macOS — catches all nested changes
			const isLeaf = dir === APP_DIR;
			const watcher = watch(dir, { persistent: true, recursive: !isLeaf }, (_eventType, filename) => {
				if (!filename) return;
				if (!filename.endsWith(".swift")) return;
				onFileChanged(path.join(dir, filename));
			});
			state.watchers.push(watcher);
		} catch { /* directory may not exist */ }
	}

	log(`Watching ${watchRoots.filter(d => fs.existsSync(d)).length} root directories (recursive) for Swift changes`);
}

/** Entry point. */
export async function startWatchDaemon() {
	log("PairApp auto-rebuild daemon starting");
	log(`Sources: ${SOURCES_DIR}`);
	log(`Binary:  ${BINARY}`);

	const swiftFiles = findSwiftFiles(SOURCES_DIR);
	log(`Found ${swiftFiles.length} Swift source files`);

	const pid = findPairAppPid();
	if (pid) {
		log(`PairApp running (PID ${pid})`);
		// Ensure project session exists on startup
		await ensureProjectSession();
	} else {
		log("PairApp not running — launching and creating session...");
		const started = await hotRestart();
		if (started) {
			logSuccess("PairApp started");
			await ensureProjectSession();
		} else {
			logError("Could not start PairApp");
		}
	}

	watchDirectories();

	// Health check: restart PairApp if it crashes between builds.
	// Exponential backoff on repeated crashes to avoid tight restart loops.
	let crashBackoff = 0;
	const healthCheck = setInterval(async () => {
		if (state.building) return;
		const alive = state.appProcess && state.appProcess.exitCode === null;
		if (alive) { crashBackoff = 0; return; }

		// Also check by PID in case it was launched externally
		if (findPairAppPid()) { crashBackoff = 0; return; }

		// Backoff: 0s, 5s, 10s, 20s, 40s... up to 60s
		if (crashBackoff > 0) {
			crashBackoff--;
			return;
		}

		const attempt = Math.min(state.crashCount, 5);
		crashBackoff = Math.min(attempt * 2, 12);  // 12 ticks * 5s = 60s max

		if (state.lastCrashLog) {
			log(`PairApp crashed (crash #${state.crashCount}) — rebuilding before restart...`);
			// Rebuild first in case crash was from a bad binary
			const buildResult = build();
			if (!buildResult.success) {
				logError(`Rebuild failed — cannot recover. Fix the code and save.`);
				if (buildResult.error) {
					const lines = buildResult.error.split("\n").filter(l => l.trim()).slice(-5);
					for (const line of lines) console.error(`  ${line}`);
				}
				return;
			}
			logSuccess(`Rebuilt OK (${(buildResult.durationMs / 1000).toFixed(1)}s)`);
		} else {
			log("PairApp not running — restarting...");
		}

		const started = await hotRestart();
		if (started) {
			logSuccess(`PairApp recovered (crash #${state.crashCount})`);
			await ensureProjectSession();
			state.lastCrashLog = null;
		} else {
			logError("PairApp recovery failed — will retry");
		}
	}, 5000);

	log("Waiting for changes... (Ctrl+C to stop)\n");

	process.on("SIGINT", () => {
		log("Shutting down file watchers");
		clearInterval(healthCheck);
		for (const w of state.watchers) w.close();
		process.exit(0);
	});

	await new Promise(() => {});
}
