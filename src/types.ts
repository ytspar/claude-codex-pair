/** JSON received by hooks via stdin from Claude Code */
export interface HookInput {
	session_id: string;
	transcript_path: string;
	cwd: string;
	hook_event_name: string;
	tool_name?: string;
	tool_input?: Record<string, unknown>;
	last_assistant_message?: string;
	/** True when Claude is continuing after a previous Stop hook block */
	stop_hook_active?: boolean;
}

/** Response returned by hook to Claude Code via stdout */
export interface HookResponse {
	decision: "approve" | "block";
	reason?: string;
}

/** Codex's assessment of Claude's work */
export type CodexDecision = "APPROVE" | "FEEDBACK" | "CONTEXT";

/** A single Claude message extracted from transcript */
export interface TranscriptMessage {
	role: "user" | "assistant";
	timestamp: number;
	content: string;
	toolCalls?: Array<{
		tool: string;
		input: string;
		result?: string;
	}>;
}

/** Result from a Codex review call */
export interface CodexReviewResult {
	decision: CodexDecision;
	response: string;
	tokensUsed?: number;
	durationMs: number;
}

/** A single interaction logged to the session JSONL */
export interface InteractionEntry {
	timestamp: string;
	sessionId: string;
	cycle: number;
	claudeSummary: string;
	gitDiffStats: string;
	codexDecision: CodexDecision;
	codexResponse: string;
	hookResponse: HookResponse;
	codexTokens?: number;
	codexDurationMs: number;
}

/** CLI config stored at ~/.claude-codex-pair/config.json */
export interface PairConfig {
	maxCycles: number;
	codexModel: string | null;
	codexTimeout: number;
	logDir: string;
	/** If set, only review sessions matching these IDs or project directory names */
	targetSessions: string[] | null;
}

export const DEFAULT_CONFIG: PairConfig = {
	maxCycles: 5,
	codexModel: null,
	codexTimeout: 300_000,
	logDir: "~/.claude-codex-pair/sessions",
	targetSessions: null,
};
