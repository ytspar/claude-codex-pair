import { execFile as execFileCb } from "node:child_process";
import { promisify } from "node:util";

const execFile = promisify(execFileCb);

export interface DiffResult {
	stat: string;
	diff: string;
	filesChanged: number;
}

export async function gitDiffStat(cwd: string): Promise<string> {
	try {
		const { stdout } = await execFile("git", ["diff", "--stat", "HEAD"], { cwd });
		return stdout.trim();
	} catch {
		return "(no git diff available)";
	}
}

/**
 * Get a comprehensive view of all changes: tracked modifications + untracked new files.
 * This ensures the reviewer sees everything, not just modified tracked files.
 */
export async function gitDiff(cwd: string, maxChars = 8000): Promise<DiffResult> {
	try {
		const [trackedStat, trackedDiff, untrackedFiles, statusResult] = await Promise.all([
			execFile("git", ["diff", "--stat", "HEAD"], { cwd }).catch(() => ({ stdout: "" })),
			execFile("git", ["diff", "HEAD"], { cwd, maxBuffer: 2 * 1024 * 1024 }).catch(() => ({ stdout: "" })),
			// List untracked files (new files not yet added to git)
			execFile("git", ["ls-files", "--others", "--exclude-standard"], { cwd }).catch(() => ({ stdout: "" })),
			execFile("git", ["status", "--short"], { cwd }).catch(() => ({ stdout: "" })),
		]);

		const stat = statusResult.stdout.trim() || trackedStat.stdout.trim();
		let diff = trackedDiff.stdout;

		// Append untracked file listing so reviewer knows what new files exist
		const untracked = untrackedFiles.stdout.trim();
		if (untracked) {
			const untrackedList = untracked.split("\n");
			diff += `\n\n--- NEW (untracked) FILES (${untrackedList.length}) ---\n`;
			diff += untrackedList.join("\n");

			// For key source files, include their content so the reviewer can actually see the code
			for (const file of untrackedList) {
				if (file.match(/\.(ts|tsx|js|jsx|json|md)$/) && !file.includes("node_modules") && !file.includes("package-lock")) {
					try {
						const { stdout: content } = await execFile("git", ["diff", "--no-index", "/dev/null", file], {
							cwd,
							maxBuffer: 512 * 1024,
						});
						diff += `\n${content}`;
					} catch (err: unknown) {
						// git diff --no-index exits 1 when there are differences (which there always are vs /dev/null)
						const e = err as { stdout?: string };
						if (e.stdout) {
							diff += `\n${e.stdout}`;
						}
					}
				}
			}
		}

		// Count total files changed
		const statusLines = statusResult.stdout.trim().split("\n").filter(Boolean);
		const filesChanged = statusLines.length;

		if (diff.length > maxChars) {
			diff = diff.slice(0, maxChars) + `\n\n... (truncated, ${diff.length} total chars)`;
		}

		return { stat, diff, filesChanged };
	} catch {
		return { stat: "(no diff)", diff: "", filesChanged: 0 };
	}
}

export async function gitStagedDiff(cwd: string): Promise<string> {
	try {
		const { stdout } = await execFile("git", ["diff", "--cached"], { cwd });
		return stdout.trim();
	} catch {
		return "";
	}
}
