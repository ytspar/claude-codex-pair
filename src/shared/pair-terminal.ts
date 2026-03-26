import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";

const SOCKET_PATH = path.join(os.homedir(), ".claude-codex-pair", "pair-terminal.sock");

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
		await sendCommand({ action: "list_surfaces" });
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
 * List all surfaces managed by pair-terminal.
 */
export async function listSurfaces(): Promise<
	Array<{ id: string; title: string; pid: number; cwd: string }>
> {
	try {
		const response = await sendCommand({ action: "list_surfaces" });
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
			client.write(JSON.stringify(command));
			// Don't end() — keep connection open for response
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
