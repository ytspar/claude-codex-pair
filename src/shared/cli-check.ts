import { execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";
import { dim, red } from "./formatter.js";

const execFile = promisify(execFileCb);

const INSTALL_HINTS: Record<string, string> = {
	claude: "Install: https://docs.claude.com/en/docs/claude-code (or `npm install -g @anthropic-ai/claude-code`)",
	codex: "Install: npm install -g @openai/codex",
};

export async function isCliAvailable(name: string): Promise<boolean> {
	try {
		await execFile(name, ["--version"]);
		return true;
	} catch {
		return false;
	}
}

/**
 * Verify required CLIs are on PATH. Exits the process with a clear error if any are missing.
 * Run early in command handlers so failures surface before any side effects.
 */
export async function assertClisAvailable(...names: string[]): Promise<void> {
	const checks = await Promise.all(names.map(async (n) => [n, await isCliAvailable(n)] as const));
	const missing = checks.filter(([, ok]) => !ok).map(([n]) => n);

	if (missing.length === 0) return;

	for (const name of missing) {
		console.error(red(`Error: ${name} CLI not found on PATH.`));
		const hint = INSTALL_HINTS[name];
		if (hint) console.error(dim(`  ${hint}`));
	}
	console.error(dim(`  current PATH: ${process.env.PATH ?? "(unset)"}`));
	process.exit(1);
}
