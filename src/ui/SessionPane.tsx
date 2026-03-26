import { useState, useEffect } from "react";
import { Box, Text } from "ink";
import Spinner from "ink-spinner";
import { readState, type SessionState } from "../monitor/state.js";
import { readSessionLog } from "../report/logger.js";
import { isProcessAlive } from "../monitor/session-watcher.js";
import type { InteractionEntry } from "../types.js";

interface Props {
	sessionId: string;
	project: string;
	pid: number;
	selected: boolean;
	expanded: boolean;
}

function statusColor(status: string): string {
	switch (status) {
		case "reviewing":
			return "yellow";
		case "approved":
			return "green";
		case "feedback":
			return "magenta";
		case "responding":
			return "cyan";
		case "claude-responding":
			return "blue";
		case "error":
			return "red";
		default:
			return "gray";
	}
}

function decisionColor(d: string): string {
	switch (d) {
		case "APPROVE":
			return "green";
		case "FEEDBACK":
			return "yellow";
		case "CONTEXT":
			return "cyan";
		default:
			return "white";
	}
}

function extractFeedback(response: string, maxLines: number): string[] {
	return response
		.split("\n")
		.filter((l) => l.trim() && !l.trim().match(/^(APPROVE|FEEDBACK|CONTEXT)$/))
		.slice(0, maxLines);
}

function truncLine(line: string, max: number): string {
	return line.length > max ? line.slice(0, max - 3) + "..." : line;
}

export function SessionPane({ sessionId, project, pid, selected, expanded }: Props) {
	const [state, setState] = useState<SessionState | null>(null);
	const [entries, setEntries] = useState<InteractionEntry[]>([]);
	const [alive, setAlive] = useState(true);

	useEffect(() => {
		const poll = () => {
			setState(readState(sessionId));
			setEntries(readSessionLog(sessionId));
			setAlive(isProcessAlive(pid));
		};
		poll();
		const interval = setInterval(poll, 2000);
		return () => clearInterval(interval);
	}, [sessionId, pid]);

	const cycle = state?.cycle ?? 0;
	const status = alive ? (state?.status ?? "idle") : "stopped";
	const isReviewing = status === "reviewing";
	const borderColor = selected ? "cyan" : "gray";
	const latest = entries.length > 0 ? entries[entries.length - 1] : null;

	// Limits based on expanded/collapsed
	const feedbackLines = expanded ? 20 : 3;
	const lineMax = expanded ? 200 : 120;

	return (
		<Box flexDirection="column" borderStyle="single" borderColor={borderColor} paddingX={1} width="100%">
			{/* ── Header ── */}
			<Box gap={2}>
				<Text bold color={alive ? "white" : "gray"}>
					{expanded ? "▼" : "▸"} {project}
				</Text>
				<Text dimColor>{sessionId.slice(0, 8)}</Text>
				<Text color={statusColor(status)}>
					{isReviewing ? <Spinner type="dots" /> : "●"} {status}
				</Text>
				{cycle > 0 && <Text dimColor>cycle {cycle}</Text>}
				{selected && !expanded && <Text dimColor>[enter to expand]</Text>}
				{selected && expanded && <Text dimColor>[enter to collapse]</Text>}
			</Box>

			{/* ── Task ── */}
			{state?.task && (
				<Box marginTop={1}>
					<Text dimColor>Task: </Text>
					<Text wrap={expanded ? "wrap" : "truncate-end"}>
						{expanded ? state.task : truncLine(state.task, lineMax)}
					</Text>
				</Box>
			)}

			{/* ── Diff ── */}
			{state?.diffStats && (
				<Box flexDirection={expanded ? "column" : "row"}>
					<Text dimColor>Diff: </Text>
					{expanded ? (
						<Box flexDirection="column" paddingLeft={2}>
							{state.diffStats.split("\n").map((line, i) => (
								<Text key={i} color="blue">{line}</Text>
							))}
						</Box>
					) : (
						<Text color="blue" wrap="truncate-end">{state.diffStats.split("\n").pop()}</Text>
					)}
				</Box>
			)}

			{/* ── Claude's response to feedback ── */}
			{state?.claudeResponse && (
				<Box flexDirection="column" marginTop={1}>
					<Text color="blue" bold>Claude responded:</Text>
					<Box flexDirection="column" paddingLeft={2}>
						{state.claudeResponse
							.split("\n")
							.filter((l: string) => l.trim())
							.slice(0, expanded ? 15 : 3)
							.map((line: string, i: number) => (
								<Text key={i} wrap={expanded ? "wrap" : "truncate-end"}>
									{expanded ? line : truncLine(line, lineMax)}
								</Text>
							))}
					</Box>
				</Box>
			)}

			{/* ── Live Codex streaming ── */}
			{isReviewing && state?.lastResponse && (
				<Box flexDirection="column" marginTop={1}>
					<Text dimColor>Codex (streaming):</Text>
					<Box flexDirection="column" paddingLeft={2}>
						{extractFeedback(state.lastResponse, expanded ? 15 : 3).map((line, i) => (
							<Text key={i} wrap={expanded ? "wrap" : "truncate-end"} color="gray">
								{expanded ? line : truncLine(line, lineMax)}
							</Text>
						))}
					</Box>
				</Box>
			)}

			{/* ── Latest Codex feedback ── */}
			{!isReviewing && latest && (
				<Box flexDirection="column" marginTop={1}>
					<Box gap={1}>
						<Text bold color={decisionColor(latest.codexDecision)}>
							{latest.codexDecision}
						</Text>
						<Text dimColor>
							(cycle {latest.cycle}, {(latest.codexDurationMs / 1000).toFixed(0)}s)
						</Text>
					</Box>
					<Box flexDirection="column" paddingLeft={2}>
						{extractFeedback(latest.codexResponse, feedbackLines).map((line, i) => (
							<Text key={i} wrap={expanded ? "wrap" : "truncate-end"}>
								{expanded ? line : truncLine(line, lineMax)}
							</Text>
						))}
						{!expanded && latest.codexResponse.split("\n").filter((l) => l.trim()).length > feedbackLines + 1 && (
							<Text dimColor>... more</Text>
						)}
					</Box>
				</Box>
			)}

			{/* ── Full history (expanded only) ── */}
			{expanded && entries.length > 0 && (
				<Box flexDirection="column" marginTop={1}>
					<Text bold underline>Full History</Text>
					{entries.map((e) => (
						<Box key={e.cycle} flexDirection="column" marginTop={1}>
							<Box gap={1}>
								<Text dimColor>#{e.cycle}</Text>
								<Text bold color={decisionColor(e.codexDecision)}>{e.codexDecision}</Text>
								<Text dimColor>{(e.codexDurationMs / 1000).toFixed(0)}s</Text>
								<Text dimColor>{e.gitDiffStats.split("\n").pop()}</Text>
							</Box>
							<Box flexDirection="column" paddingLeft={2}>
								{extractFeedback(e.codexResponse, 10).map((line, i) => (
									<Text key={i} wrap="wrap">{line}</Text>
								))}
							</Box>
						</Box>
					))}
				</Box>
			)}

			{/* ── Compact history (collapsed) ── */}
			{!expanded && entries.length > 1 && (
				<Box marginTop={1} overflow="hidden">
					<Text dimColor>History: </Text>
					<Text wrap="truncate-end">
						{entries.slice(0, -1).map((e) => `#${e.cycle} ${e.codexDecision}`).join("  ")}
					</Text>
				</Box>
			)}

			{/* ── Empty state ── */}
			{!latest && !isReviewing && <Text dimColor>Waiting for Claude to pause…</Text>}
		</Box>
	);
}
