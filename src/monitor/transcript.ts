import fs from "node:fs";
import type { TranscriptMessage } from "../types.js";

/**
 * Parse a Claude Code JSONL transcript file and extract messages.
 *
 * Real format: each line is a JSON object with:
 * - type: "user" | "assistant" | "file-history-snapshot" | etc.
 * - message.role: "user" | "assistant"
 * - message.content: string | Array<{type: "text"|"tool_use"|"thinking", ...}>
 * - timestamp: ISO string
 * - sessionId, cwd, etc.
 */
export function parseTranscript(transcriptPath: string): TranscriptMessage[] {
	if (!fs.existsSync(transcriptPath)) return [];

	const raw = fs.readFileSync(transcriptPath, "utf-8");
	const lines = raw.trim().split("\n").filter(Boolean);
	const messages: TranscriptMessage[] = [];

	for (const line of lines) {
		try {
			const entry = JSON.parse(line);
			const entryType = entry.type as string;

			if (entryType === "assistant") {
				messages.push(extractAssistantMessage(entry));
			} else if (entryType === "user") {
				messages.push(extractUserMessage(entry));
			}
			// Skip file-history-snapshot, tool_result, and other entry types
		} catch {
			// Skip malformed lines
		}
	}

	return messages;
}

/**
 * Get the last N assistant messages from a transcript, summarized.
 */
export function getLastAssistantMessages(transcriptPath: string, count = 3): string {
	const messages = parseTranscript(transcriptPath);
	const assistantMsgs = messages.filter((m) => m.role === "assistant");
	const recent = assistantMsgs.slice(-count);

	return recent
		.map((msg, i) => {
			const tools = msg.toolCalls?.length
				? `\n  Tools used: ${msg.toolCalls.map((t) => t.tool).join(", ")}`
				: "";
			const content = msg.content.length > 500 ? msg.content.slice(0, 500) + "..." : msg.content;
			return `[${i + 1}] ${content}${tools}`;
		})
		.join("\n\n");
}

// biome-ignore lint/suspicious/noExplicitAny: transcript entries have dynamic shape
function extractAssistantMessage(entry: Record<string, any>): TranscriptMessage {
	const message = entry.message ?? {};
	const contentBlocks = message.content ?? [];
	const toolCalls: TranscriptMessage["toolCalls"] = [];
	const textParts: string[] = [];

	if (typeof contentBlocks === "string") {
		textParts.push(contentBlocks);
	} else if (Array.isArray(contentBlocks)) {
		for (const block of contentBlocks) {
			if (block.type === "text" && block.text) {
				textParts.push(block.text);
			} else if (block.type === "tool_use") {
				toolCalls.push({
					tool: block.name ?? "unknown",
					input: typeof block.input === "string" ? block.input : JSON.stringify(block.input),
				});
			}
			// Skip thinking blocks — they're not useful for review context
		}
	}

	return {
		role: "assistant",
		timestamp: parseTimestamp(entry.timestamp),
		content: textParts.join("\n"),
		toolCalls: toolCalls.length > 0 ? toolCalls : undefined,
	};
}

// biome-ignore lint/suspicious/noExplicitAny: transcript entries have dynamic shape
function extractUserMessage(entry: Record<string, any>): TranscriptMessage {
	const message = entry.message ?? {};
	let content: string;

	if (typeof message === "string") {
		content = message;
	} else if (typeof message.content === "string") {
		content = message.content;
	} else if (Array.isArray(message.content)) {
		content = message.content
			.filter((block: Record<string, unknown>) => block.type === "text")
			.map((block: Record<string, unknown>) => block.text)
			.join("\n");
	} else {
		content = "";
	}

	return {
		role: "user",
		timestamp: parseTimestamp(entry.timestamp),
		content,
	};
}

/**
 * Extract the original task/goal from the transcript.
 * Returns the first user message (the initial prompt) truncated for context.
 */
export function getTaskContext(transcriptPath: string, maxChars = 1000): string {
	const messages = parseTranscript(transcriptPath);
	const firstUser = messages.find((m) => m.role === "user");
	if (!firstUser || !firstUser.content) return "(no task context available)";

	const content = firstUser.content.trim();
	if (content.length <= maxChars) return content;
	return content.slice(0, maxChars) + "...";
}

/**
 * Build a conversation summary: task, key user directions, and recent activity.
 */
export function getConversationContext(transcriptPath: string): string {
	const messages = parseTranscript(transcriptPath);
	const parts: string[] = [];

	// 1. Original task (first user message)
	const firstUser = messages.find((m) => m.role === "user");
	if (firstUser?.content) {
		const task = firstUser.content.length > 800 ? firstUser.content.slice(0, 800) + "..." : firstUser.content;
		parts.push(`ORIGINAL TASK:\n${task}`);
	}

	// 2. Key user directions (user messages that aren't the first one, sampled)
	const userMsgs = messages.filter((m) => m.role === "user" && m !== firstUser);
	if (userMsgs.length > 0) {
		// Take last few user messages to show recent direction changes
		const recentUser = userMsgs.slice(-3);
		const directions = recentUser
			.map((m) => {
				const content = m.content.length > 200 ? m.content.slice(0, 200) + "..." : m.content;
				return `- ${content}`;
			})
			.join("\n");
		parts.push(`RECENT USER DIRECTIONS:\n${directions}`);
	}

	// 3. Recent assistant activity (last 5 messages with tool info)
	const assistantMsgs = messages.filter((m) => m.role === "assistant");
	const recent = assistantMsgs.slice(-5);
	if (recent.length > 0) {
		const activity = recent
			.map((msg, i) => {
				const tools = msg.toolCalls?.length
					? `\n  Tools: ${msg.toolCalls.map((t) => t.tool).join(", ")}`
					: "";
				const content = msg.content.length > 300 ? msg.content.slice(0, 300) + "..." : msg.content;
				return `[${i + 1}] ${content}${tools}`;
			})
			.join("\n\n");
		parts.push(`RECENT CLAUDE ACTIVITY:\n${activity}`);
	}

	// 4. Task list (from TaskCreate/TaskUpdate tool calls)
	const taskList = getTaskList(transcriptPath);
	if (taskList) {
		parts.push(`CLAUDE'S TASK LIST:\n${taskList}`);
	}

	return parts.join("\n\n---\n\n");
}

interface TaskEntry {
	id: string;
	subject: string;
	description?: string;
	status: string;
}

/**
 * Reconstruct Claude's task list by scanning TaskCreate/TaskUpdate tool calls in the raw JSONL.
 */
export function getTaskList(transcriptPath: string): string | null {
	if (!fs.existsSync(transcriptPath)) return null;

	const raw = fs.readFileSync(transcriptPath, "utf-8");
	const lines = raw.trim().split("\n").filter(Boolean);
	const tasks = new Map<string, TaskEntry>();
	let autoId = 0;

	for (const line of lines) {
		try {
			const entry = JSON.parse(line);
			const msg = entry.message;
			if (!msg || typeof msg !== "object") continue;
			const content = msg.content;
			if (!Array.isArray(content)) continue;

			for (const block of content) {
				if (block.type !== "tool_use") continue;

				if (block.name === "TaskCreate") {
					autoId++;
					const id = String(autoId);
					tasks.set(id, {
						id,
						subject: block.input?.subject ?? "untitled",
						description: block.input?.description,
						status: "pending",
					});
				} else if (block.name === "TaskUpdate") {
					const id = block.input?.taskId;
					if (id && tasks.has(id)) {
						const task = tasks.get(id)!;
						if (block.input?.status) task.status = block.input.status;
						if (block.input?.subject) task.subject = block.input.subject;
					}
				}
			}
		} catch {
			// skip
		}
	}

	if (tasks.size === 0) return null;

	const taskLines: string[] = [];
	for (const t of tasks.values()) {
		const icon = t.status === "completed" ? "✓" : t.status === "in_progress" ? "→" : "○";
		taskLines.push(`${icon} [${t.status}] ${t.subject}`);
	}

	const done = [...tasks.values()].filter((t) => t.status === "completed").length;
	const total = tasks.size;
	taskLines.unshift(`${total} tasks (${done} done, ${total - done} remaining)`);

	return taskLines.join("\n");
}

function parseTimestamp(ts: unknown): number {
	if (typeof ts === "number") return ts;
	if (typeof ts === "string") return new Date(ts).getTime();
	return Date.now();
}
