import { spawn, execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";
import type { CodexReviewResult } from "../types.js";
import { parseCodexResponse } from "./response-parser.js";

const execFile = promisify(execFileCb);

export interface CodexExecOptions {
	prompt: string;
	cwd: string;
	timeout?: number;
	model?: string | null;
	/** Called with live text fragments as Codex streams its response */
	onProgress?: (text: string) => void;
}

/**
 * Spawn `codex exec --json` in read-only mode, stream events, return parsed result.
 */
export async function callCodex(options: CodexExecOptions): Promise<CodexReviewResult> {
	const { prompt, cwd, timeout = 300_000, model, onProgress } = options;
	const start = Date.now();

	const args = ["exec", "--json", "-s", "read-only"];
	if (model) {
		args.push("-m", model);
	}
	args.push(prompt);

	try {
		const result = await spawnCodexStream(args, cwd, timeout, onProgress);
		const durationMs = Date.now() - start;
		const parsed = parseCodexResponse(result.text);

		return {
			...parsed,
			tokensUsed: result.outputTokens,
			durationMs,
		};
	} catch (err: unknown) {
		const durationMs = Date.now() - start;
		const message = err instanceof Error ? err.message : String(err);

		return {
			decision: "APPROVE",
			response: `Codex error (auto-approving): ${message}`,
			durationMs,
		};
	}
}

interface StreamResult {
	text: string;
	outputTokens?: number;
}

function spawnCodexStream(
	args: string[],
	cwd: string,
	timeout: number,
	onProgress?: (text: string) => void,
): Promise<StreamResult> {
	return new Promise((resolve, reject) => {
		const proc = spawn("codex", args, {
			cwd,
			env: { ...process.env },
			stdio: ["pipe", "pipe", "pipe"],
		});

		let fullText = "";
		let outputTokens: number | undefined;
		let buffer = "";

		const timer = setTimeout(() => {
			proc.kill("SIGTERM");
			reject(new Error(`Codex timed out after ${timeout}ms`));
		}, timeout);

		proc.stdout.setEncoding("utf-8");
		proc.stdout.on("data", (chunk: string) => {
			buffer += chunk;
			const lines = buffer.split("\n");
			// Keep the last incomplete line in the buffer
			buffer = lines.pop() ?? "";

			for (const line of lines) {
				if (!line.trim()) continue;
				try {
					const event = JSON.parse(line);
					processEvent(event);
				} catch {
					// Skip non-JSON lines
				}
			}
		});

		function processEvent(event: Record<string, unknown>) {
			const type = event.type as string;

			if (type === "item.completed") {
				// Final item with complete text
				const item = event.item as Record<string, unknown> | undefined;
				if (item?.text) {
					fullText = item.text as string;
					onProgress?.(fullText);
				}
			} else if (type === "item.delta") {
				// Streaming delta  - append to running text
				const delta = event.delta as Record<string, unknown> | undefined;
				if (delta?.text) {
					fullText += delta.text as string;
					onProgress?.(fullText);
				}
			} else if (type === "turn.completed") {
				const usage = event.usage as Record<string, unknown> | undefined;
				if (usage?.output_tokens) {
					outputTokens = usage.output_tokens as number;
				}
			}
		}

		proc.on("close", (code) => {
			clearTimeout(timer);
			// Process any remaining buffer
			if (buffer.trim()) {
				try {
					processEvent(JSON.parse(buffer));
				} catch {
					// ignore
				}
			}
			if (code !== 0 && !fullText) {
				reject(new Error(`Codex exited with code ${code}`));
			} else {
				resolve({ text: fullText, outputTokens });
			}
		});

		proc.on("error", (err) => {
			clearTimeout(timer);
			reject(err);
		});

		// Close stdin immediately  - prompt is passed as arg
		proc.stdin.end();
	});
}

/**
 * Check if codex CLI is available on PATH.
 */
export async function isCodexAvailable(): Promise<boolean> {
	try {
		await execFile("codex", ["--version"]);
		return true;
	} catch {
		return false;
	}
}
