#!/usr/bin/env node
/**
 * Permission handler  - Codex decides whether to approve Claude's tool requests.
 *
 * For fast/safe operations (Read, Glob, Grep): auto-approve without calling Codex.
 * For mutations (Write, Edit, Bash): quick Codex check  - approve unless clearly dangerous.
 */
import { callCodex } from "../codex/client.js";

interface PermissionInput {
	hook_event_name: string;
	tool_name?: string;
	tool_input?: Record<string, unknown>;
	session_id?: string;
	cwd?: string;
}

// Tools that are always safe  - no review needed
const ALWAYS_SAFE = new Set(["Read", "Glob", "Grep", "LSP", "WebSearch", "WebFetch"]);

// Bash commands/patterns that are genuinely dangerous and need Codex review
const DANGEROUS_PATTERNS = [
	/\brm\s+(-[a-zA-Z]*[rf]|--recursive|--force)/,  // rm -rf, rm -r, rm -f
	/\brm\s+-[a-zA-Z]*\s+[\/~]/,                     // rm targeting root or home
	/\bsudo\b/,                                        // privilege escalation
	/\bchmod\s+[0-7]*777\b/,                           // world-writable permissions
	/\bchown\b/,                                       // ownership changes
	/\bmkfs\b/,                                        // filesystem format
	/\bdd\s+/,                                         // raw disk writes
	/>\s*\/etc\//,                                     // overwriting system config
	/\bcurl\b.*\|\s*(ba)?sh/,                          // pipe-to-shell
	/\bwget\b.*\|\s*(ba)?sh/,
	/\bgit\s+push\s+.*--force/,                        // force push
	/\bgit\s+reset\s+--hard/,                          // destructive git reset
	/\bpkill\b|\bkillall\b|\bkill\s+-9/,              // killing processes
	/\bdrop\s+(table|database)/i,                      // SQL destructive ops
	/\btruncate\s+table/i,
];

function isDangerousBash(command: string): boolean {
	return DANGEROUS_PATTERNS.some((p) => p.test(command));
}

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

	// Auto-approve file creation/editing within the project directory.
	// Block writes to sensitive paths outside the working directory.
	if (tool === "Write" || tool === "Edit" || tool === "NotebookEdit") {
		const filePath = String(input.tool_input?.file_path ?? "");
		const cwd = input.cwd ?? "";
		const sensitive = ["/etc/", "/.ssh/", "/.gnupg/", "/.aws/", "/.config/", "/sudoers"];
		if (filePath && sensitive.some((s) => filePath.includes(s))) {
			deny();
			return;
		}
		if (cwd && filePath && !filePath.startsWith(cwd) && !filePath.startsWith("/tmp")) {
			deny();
			return;
		}
		approve();
		return;
	}

	// For Bash, only flag genuinely dangerous commands
	if (tool === "Bash") {
		const command = String(input.tool_input?.command ?? "");
		if (!isDangerousBash(command)) {
			approve();
			return;
		}
	}

	// Only reach here for dangerous bash commands or unknown tools  - ask Codex
	const toolDesc = describeToolAction(tool, input.tool_input ?? {});

	try {
		const result = await callCodex({
			prompt: `Claude Code wants to run a potentially dangerous command. Should this be allowed?

Tool: ${tool}
Action: ${toolDesc}
Working directory: ${input.cwd ?? "unknown"}

This was flagged because it matches a destructive pattern (rm -rf, sudo, force push, etc).
Only say NO if this would cause genuine damage (data loss, security breach, system corruption).
Say YES if it seems intentional and scoped appropriately.

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
		// Codex failed  - deny dangerous commands (fail-closed for safety)
		deny();
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
