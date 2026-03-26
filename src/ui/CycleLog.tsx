import { Box, Text } from "ink";
import type { InteractionEntry } from "../types.js";

interface Props {
	entries: InteractionEntry[];
	maxVisible?: number;
}

function decisionColor(decision: string): string {
	switch (decision) {
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

export function CycleLog({ entries, maxVisible = 10 }: Props) {
	if (entries.length === 0) {
		return (
			<Box paddingX={1}>
				<Text dimColor>No interactions yet. Waiting for Claude to pause...</Text>
			</Box>
		);
	}

	const visible = entries.slice(-maxVisible);

	return (
		<Box flexDirection="column" paddingX={1}>
			<Text bold underline>
				Interaction Log
			</Text>
			{visible.map((entry) => (
				<Box key={entry.cycle} flexDirection="column" marginTop={1}>
					<Box gap={2}>
						<Text dimColor>#{entry.cycle}</Text>
						<Text color={decisionColor(entry.codexDecision)} bold>
							{entry.codexDecision}
						</Text>
						<Text dimColor>{entry.gitDiffStats.split("\n").pop()}</Text>
						<Text dimColor>{(entry.codexDurationMs / 1000).toFixed(1)}s</Text>
					</Box>
					<Box paddingLeft={2}>
						<Text wrap="truncate-end">
							{entry.codexResponse.split("\n").slice(1, 3).join(" ").slice(0, 120)}
						</Text>
					</Box>
				</Box>
			))}
			{entries.length > maxVisible && (
				<Text dimColor>... {entries.length - maxVisible} earlier entries hidden</Text>
			)}
		</Box>
	);
}
