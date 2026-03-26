#!/usr/bin/env node
/**
 * Permission handler — Codex decides whether to approve Claude's tool requests.
 *
 * For fast/safe operations (Read, Glob, Grep): auto-approve without calling Codex.
 * For mutations (Write, Edit, Bash): quick Codex check — approve unless clearly dangerous.
 */
import { callCodex } from "../codex/client.js";

interface PermissionInput {
	hook_event_name: string;
	tool_name?: string;
	tool_input?: Record<string, unknown>;
	session_id?: string;
	cwd?: string;
}

// Tools that are always safe — no review needed
const ALWAYS_SAFE = new Set(["Read", "Glob", "Grep", "LSP", "WebSearch", "WebFetch"]);

async function main(): Promise<void> {
	let input: PermissionInput;
	try {
		const stdin = await readStdin();
		input = JSON.parse(stdin);
	} catch {
		process.exit(0);
	}

	const tool = input.tool_name ?? "";

	// Auto-approve read-only tools
	if (ALWAYS_SAFE.has(tool)) {
		approve();
		return;
	}

	// For mutations, ask Codex for a quick judgment
	const toolDesc = describeToolAction(tool, input.tool_input ?? {});

	try {
		const result = await callCodex({
			prompt: `Claude Code wants to use a tool. Should this be allowed?

Tool: ${tool}
Action: ${toolDesc}
Working directory: ${input.cwd ?? "unknown"}

Default to YES unless this is clearly dangerous (deleting important files, running destructive commands, modifying system files, exposing secrets).

Respond with exactly YES or NO on the first line, then a brief reason.`,
			cwd: input.cwd ?? ".",
			timeout: 15_000,
		});

		const firstLine = result.response.trim().split("\n")[0].toUpperCase();
		if (firstLine.startsWith("NO")) {
			deny();
		} else {
			approve();
		}
	} catch {
		// Codex failed — default to approve so Claude isn't blocked
		approve();
	}
}

function describeToolAction(tool: string, toolInput: Record<string, unknown>): string {
	switch (tool) {
		case "Write":
			return `Create/overwrite file: ${toolInput.file_path ?? "unknown"}`;
		case "Edit":
			return `Edit file: ${toolInput.file_path ?? "unknown"}`;
		case "Bash":
			return `Run command: ${String(toolInput.command ?? "unknown").slice(0, 200)}`;
		case "NotebookEdit":
			return `Edit notebook: ${toolInput.file_path ?? "unknown"}`;
		default:
			return `${tool} with ${JSON.stringify(toolInput).slice(0, 200)}`;
	}
}

function approve(): void {
	process.stdout.write(
		JSON.stringify({
			hookSpecificOutput: {
				hookEventName: "PermissionRequest",
				decision: { behavior: "allow" },
			},
		}),
	);
	process.exit(0);
}

function deny(): void {
	process.stdout.write(
		JSON.stringify({
			hookSpecificOutput: {
				hookEventName: "PermissionRequest",
				decision: { behavior: "deny" },
			},
		}),
	);
	process.exit(0);
}

function readStdin(): Promise<string> {
	return new Promise((resolve, reject) => {
		let data = "";
		process.stdin.setEncoding("utf-8");
		process.stdin.on("data", (chunk) => (data += chunk));
		process.stdin.on("end", () => resolve(data));
		process.stdin.on("error", reject);
		if (process.stdin.readableEnded) resolve(data);
	});
}

main().catch(() => process.exit(0));
