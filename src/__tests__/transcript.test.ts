import { describe, it, expect, afterEach } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseTranscript, getLastAssistantMessages, getTaskContext, getTaskList } from "../monitor/transcript.js";

function tmpFile(content: string): string {
	const p = path.join(os.tmpdir(), `pair-test-${Date.now()}-${Math.random().toString(36).slice(2)}.jsonl`);
	fs.writeFileSync(p, content);
	return p;
}

let tmpFiles: string[] = [];

function makeTmp(content: string): string {
	const p = tmpFile(content);
	tmpFiles.push(p);
	return p;
}

afterEach(() => {
	for (const f of tmpFiles) {
		try { fs.unlinkSync(f); } catch { /* ignore */ }
	}
	tmpFiles = [];
});

describe("parseTranscript", () => {
	it("returns empty array for non-existent file", () => {
		expect(parseTranscript("/tmp/does-not-exist-12345.jsonl")).toEqual([]);
	});

	it("parses assistant messages with string content", () => {
		const data = JSON.stringify({
			type: "assistant",
			timestamp: "2025-01-01T00:00:00Z",
			message: { role: "assistant", content: "Hello from Claude" },
		});
		const msgs = parseTranscript(makeTmp(data));
		expect(msgs).toHaveLength(1);
		expect(msgs[0].role).toBe("assistant");
		expect(msgs[0].content).toBe("Hello from Claude");
	});

	it("parses assistant messages with block content including tool_use", () => {
		const data = JSON.stringify({
			type: "assistant",
			timestamp: "2025-01-01T00:00:00Z",
			message: {
				role: "assistant",
				content: [
					{ type: "text", text: "Let me read the file." },
					{ type: "tool_use", name: "Read", input: { path: "foo.ts" } },
				],
			},
		});
		const msgs = parseTranscript(makeTmp(data));
		expect(msgs).toHaveLength(1);
		expect(msgs[0].content).toBe("Let me read the file.");
		expect(msgs[0].toolCalls).toHaveLength(1);
		expect(msgs[0].toolCalls![0].tool).toBe("Read");
	});

	it("parses user messages with string content", () => {
		const data = JSON.stringify({
			type: "user",
			timestamp: "2025-01-01T00:00:00Z",
			message: { role: "user", content: "Fix the bug" },
		});
		const msgs = parseTranscript(makeTmp(data));
		expect(msgs).toHaveLength(1);
		expect(msgs[0].role).toBe("user");
		expect(msgs[0].content).toBe("Fix the bug");
	});

	it("parses user messages with block array content", () => {
		const data = JSON.stringify({
			type: "user",
			timestamp: "2025-01-01T00:00:00Z",
			message: {
				role: "user",
				content: [{ type: "text", text: "Do this" }, { type: "text", text: " and that" }],
			},
		});
		const msgs = parseTranscript(makeTmp(data));
		expect(msgs).toHaveLength(1);
		expect(msgs[0].content).toBe("Do this\n and that");
	});

	it("skips non-user/assistant entries", () => {
		const lines = [
			JSON.stringify({ type: "file-history-snapshot", message: {} }),
			JSON.stringify({ type: "user", timestamp: 1000, message: { content: "hi" } }),
		].join("\n");
		const msgs = parseTranscript(makeTmp(lines));
		expect(msgs).toHaveLength(1);
		expect(msgs[0].role).toBe("user");
	});

	it("skips malformed JSON lines", () => {
		const lines = "not-json\n" + JSON.stringify({
			type: "user",
			timestamp: 1000,
			message: { content: "valid" },
		});
		const msgs = parseTranscript(makeTmp(lines));
		expect(msgs).toHaveLength(1);
		expect(msgs[0].content).toBe("valid");
	});
});

describe("getLastAssistantMessages", () => {
	it("returns last N assistant messages formatted", () => {
		const lines = [
			JSON.stringify({ type: "assistant", timestamp: 1, message: { content: "First" } }),
			JSON.stringify({ type: "user", timestamp: 2, message: { content: "ok" } }),
			JSON.stringify({ type: "assistant", timestamp: 3, message: { content: "Second" } }),
			JSON.stringify({ type: "assistant", timestamp: 4, message: { content: "Third" } }),
		].join("\n");
		const result = getLastAssistantMessages(makeTmp(lines), 2);
		expect(result).toContain("Second");
		expect(result).toContain("Third");
		expect(result).not.toContain("First");
	});
});

describe("getTaskContext", () => {
	it("returns first user message as task context", () => {
		const lines = [
			JSON.stringify({ type: "user", timestamp: 1, message: { content: "Build a CLI tool" } }),
			JSON.stringify({ type: "assistant", timestamp: 2, message: { content: "Sure" } }),
		].join("\n");
		expect(getTaskContext(makeTmp(lines))).toBe("Build a CLI tool");
	});

	it("truncates long task context", () => {
		const longMsg = "x".repeat(2000);
		const data = JSON.stringify({ type: "user", timestamp: 1, message: { content: longMsg } });
		const result = getTaskContext(makeTmp(data), 100);
		expect(result.length).toBeLessThanOrEqual(103); // 100 + "..."
		expect(result.endsWith("...")).toBe(true);
	});

	it("returns fallback for empty transcript", () => {
		expect(getTaskContext(makeTmp(""))).toBe("(no task context available)");
	});
});

describe("getTaskList", () => {
	it("returns null when no tasks exist", () => {
		const data = JSON.stringify({ type: "user", timestamp: 1, message: { content: "hi" } });
		expect(getTaskList(makeTmp(data))).toBeNull();
	});

	it("reconstructs task list from TaskCreate tool calls", () => {
		const line = JSON.stringify({
			type: "assistant",
			timestamp: 1,
			message: {
				content: [
					{ type: "tool_use", name: "TaskCreate", input: { subject: "Write tests" } },
					{ type: "tool_use", name: "TaskCreate", input: { subject: "Fix bugs" } },
				],
			},
		});
		const result = getTaskList(makeTmp(line))!;
		expect(result).toContain("Write tests");
		expect(result).toContain("Fix bugs");
		expect(result).toContain("2 tasks");
		expect(result).toContain("0 done");
	});

	it("tracks TaskUpdate status changes", () => {
		const lines = [
			JSON.stringify({
				type: "assistant",
				timestamp: 1,
				message: {
					content: [{ type: "tool_use", name: "TaskCreate", input: { subject: "Task A" } }],
				},
			}),
			JSON.stringify({
				type: "assistant",
				timestamp: 2,
				message: {
					content: [{ type: "tool_use", name: "TaskUpdate", input: { taskId: "1", status: "completed" } }],
				},
			}),
		].join("\n");
		const result = getTaskList(makeTmp(lines))!;
		expect(result).toContain("1 done");
		expect(result).toContain("✓");
	});
});
