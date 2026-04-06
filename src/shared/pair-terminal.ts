import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

const SOCKET_PATH = path.join(os.homedir(), ".claude-codex-pair", "pair-terminal.sock");
const TOKEN_PATH = path.join(os.homedir(), ".claude-codex-pair", "auth-token");

function readAuthToken(): string {
	try { return fs.readFileSync(TOKEN_PATH, "utf-8").trim(); }
	catch { return ""; }
}

interface IPCResponse {
	ok: boolean;
	result?: string;
	error?: string;
}

/**
 * Check if pair-terminal is running (socket exists and is connectable).
 */
export async function isPairTerminalRunning(): Promise<boolean> {
	if (!fs.existsSync(SOCKET_PATH)) return false;
	try {
		await sendCommand({ action: "list_sessions" });
		return true;
	} catch {
		return false;
	}
}

/**
 * Send input text to a Claude session surface via pair-terminal.
 */
export async function sendInputViaPairTerminal(
	surfaceId: string,
	text: string,
): Promise<{ success: boolean; error?: string }> {
	try {
		const response = await sendCommand({
			action: "send_input",
			surface: surfaceId,
			text,
		});

		if (response.ok) {
			return { success: true };
		}
		return { success: false, error: response.error ?? "Unknown error" };
	} catch (err) {
		return { success: false, error: err instanceof Error ? err.message : String(err) };
	}
}

/**
 * Read the terminal screen content for a session.
 * Returns plain text of what's currently displayed.
 */
export async function readScreen(
	surfaceId: string,
	scrollback = false,
): Promise<string | null> {
	try {
		const response = await sendCommand({
			action: "read_screen",
			surface: surfaceId,
			text: scrollback ? "--scrollback" : undefined,
		});
		if (response.ok && response.result) return response.result;
		return null;
	} catch {
		return null;
	}
}

/**
 * Send a named key to a session (enter, ctrl-c, tab, escape, etc.)
 */
export async function sendKey(
	surfaceId: string,
	key: string,
): Promise<boolean> {
	try {
		const response = await sendCommand({
			action: "send_key",
			surface: surfaceId,
			text: key,
		});
		return response.ok;
	} catch {
		return false;
	}
}

/**
 * List all surfaces managed by pair-terminal.
 */
export async function listSurfaces(): Promise<
	Array<{ id: string; title: string; pid: number; cwd: string }>
> {
	try {
		const response = await sendCommand({ action: "list_sessions" });
		if (response.ok && response.result) {
			return JSON.parse(response.result);
		}
		return [];
	} catch {
		return [];
	}
}

/**
 * Send a JSON command to the pair-terminal unix socket.
 */
function sendCommand(command: Record<string, unknown>, timeout = 5000): Promise<IPCResponse> {
	return new Promise((resolve, reject) => {
		const client = net.createConnection(SOCKET_PATH);
		let data = "";

		const timer = setTimeout(() => {
			client.destroy();
			reject(new Error("pair-terminal IPC timeout"));
		}, timeout);

		client.on("connect", () => {
			client.write(JSON.stringify({ ...command, token: readAuthToken() }));
			// Don't end()  - keep connection open for response
		});

		client.on("data", (chunk) => {
			data += chunk.toString();
		});

		client.on("end", () => {
			clearTimeout(timer);
			try {
				resolve(JSON.parse(data));
			} catch {
				reject(new Error(`Invalid response: ${data}`));
			}
		});

		client.on("error", (err) => {
			clearTimeout(timer);
			reject(err);
		});
	});
}
