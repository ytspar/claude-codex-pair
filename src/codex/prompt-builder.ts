import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { DiffResult } from "../shared/git.js";

const RULES_FILE = path.join(os.homedir(), ".claude-codex-pair", "rules.md");

/**
 * Load project-specific review rules that Claude and Codex share.
 * Claude can edit this file to steer Codex's review behavior.
 */
function loadRules(): string {
	if (!fs.existsSync(RULES_FILE)) {
		// Create default rules on first run
		const defaults = [
			"# Review Rules",
			"",
			"These rules guide Codex's review of Claude's work. Claude can edit this file to steer reviews.",
			"",
			"## Preferences",
			"- Always take the harder, more complete path. Never defer work to future tasks.",
			"- Prefer thorough implementations over quick fixes.",
			"- When Claude offers options, choose the most comprehensive one.",
			"",
			"## Project-Specific Notes",
			"(Claude: add notes here about architecture, conventions, or priorities that Codex should know)",
			"",
		].join("\n");
		fs.mkdirSync(path.dirname(RULES_FILE), { recursive: true });
		fs.writeFileSync(RULES_FILE, defaults);
		return defaults;
	}
	return fs.readFileSync(RULES_FILE, "utf-8");
}

const REVIEW_TEMPLATE = `You are a completion gate for an AI coding agent (Claude Code). Your job is to determine whether the user's original task has been FULLY completed — not partially, not "good enough", but actually done.

Progress is not completion. A convincing summary is not completion. Only verifiable evidence counts.

REVIEW RULES (maintained by Claude — follow these):
{rules}

PROJECT: {cwd}

SESSION CONTEXT:
{sessionContext}

YOUR PREVIOUS FEEDBACK (if any):
{previousFeedback}

GIT DIFF STATS: {diffStat}

FILES CHANGED:
{diff}

REVIEW PROCESS — Track progress across cycles:
1. If you gave previous feedback, check each item: was it fixed? Acknowledge what was fixed. Only re-raise items that are still broken.
2. Re-read the ORIGINAL TASK. What exactly did the user ask for?
3. For each discrete item, check: is there evidence in the diff that it was done?
4. Check for new bugs, missing error handling, or incomplete implementations.
5. Check if Claude's last actions align with the task — or if it went off-track.

Do NOT accept rationalizations like "the rest would require architectural changes" or "diminishing returns". If work remains, say so.

Respond with EXACTLY ONE verdict on its own line:

APPROVE — Every discrete item in the original task is done. The code is correct and complete. Claude can stop.
FEEDBACK — Work remains or issues exist. List each unfinished item or bug concisely. Be specific and actionable — Claude will receive your feedback and continue working.
CONTEXT — You cannot determine completion. State what information is missing.

Start your response with the verdict, then explain below.

IMPORTANT: Do NOT narrate your review process. Do NOT say things like "I'm checking...", "Let me validate...", "I've confirmed...". Just state the verdict and the specific issues or approval. Claude receives your response as direct feedback — it should be actionable, not a description of what you did.`;

const RESPOND_TEMPLATE = `You are acting as the human operator for an AI coding agent (Claude Code). Claude has stopped and may be waiting for your input, asking a question, or reporting completion. Read its message and decide what to do.

RULES (maintained by Claude — follow these):
{rules}

PROJECT: {cwd}

SESSION CONTEXT:
{sessionContext}

CLAUDE IS ASKING:
{lastMessage}

YOUR ROLE:
- You are the human making decisions for this session. Answer Claude's question directly.
- Choose the option that best advances the ORIGINAL TASK toward full completion.
- ALWAYS choose the most thorough option. If there's "review everything", "apply all fixes", "fix all issues", or similar — pick that. Never skip work, never take shortcuts, never pick "just show the report" or "skip".
- If Claude offers numbered options, pick the one that does the most work (e.g. "Accept recommended + review remaining" over "Accept recommended fixes" alone; "Review everything" over partial review).
- If Claude asks for confirmation, confirm if the plan aligns with the task.
- If Claude suggests deferring work ("that's a bigger refactor", "worth doing as its own task", "for now let's just..."), REJECT the deferral. Say: "No, do it properly now. Take the harder and more complete path."
- If Claude wants to create a ticket/issue instead of doing the work, say: "Don't create an issue. Do the work now."
- If Claude is confused or off-track, redirect it back to the original task.
- Be concise and decisive — Claude is waiting.

Respond with EXACTLY the text that should be sent to Claude as user input. Do not add meta-commentary. Just the response.`;

export interface PromptInput {
	cwd: string;
	diffResult: DiffResult;
	sessionContext: string;
	/** Previous Codex feedback from earlier cycles, so Codex can track progress */
	previousFeedback?: string;
}

export interface RespondInput {
	cwd: string;
	sessionContext: string;
	lastMessage: string;
}

export function buildReviewPrompt(input: PromptInput): string {
	return REVIEW_TEMPLATE.replace("{cwd}", input.cwd)
		.replace("{rules}", loadRules())
		.replace("{diffStat}", input.diffResult.stat)
		.replace("{sessionContext}", input.sessionContext || "(no session context available)")
		.replace("{previousFeedback}", input.previousFeedback || "(first review cycle — no previous feedback)")
		.replace("{diff}", input.diffResult.diff || "(no changes detected)");
}

export function buildRespondPrompt(input: RespondInput): string {
	return RESPOND_TEMPLATE.replace("{cwd}", input.cwd)
		.replace("{rules}", loadRules())
		.replace("{sessionContext}", input.sessionContext || "(no session context available)")
		.replace("{lastMessage}", input.lastMessage || "(no message)");
}
