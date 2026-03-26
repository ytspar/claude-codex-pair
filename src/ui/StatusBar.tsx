import { Box, Text } from "ink";
import type { SessionState } from "../monitor/state.js";

interface Props {
	sessionId: string;
	project: string;
	state: SessionState | null;
}

function statusColor(status: string): string {
	switch (status) {
		case "reviewing":
			return "yellow";
		case "approved":
			return "green";
		case "feedback":
			return "magenta";
		case "error":
			return "red";
		default:
			return "gray";
	}
}

export function StatusBar({ sessionId, project, state }: Props) {
	const cycle = state?.cycle ?? 0;
	const status = state?.status ?? "idle";

	return (
		<Box borderStyle="single" paddingX={1} flexDirection="column">
			<Box gap={2}>
				<Text bold>claude-codex-pair</Text>
				<Text dimColor>session:</Text>
				<Text color="cyan">{sessionId.slice(0, 12)}</Text>
				<Text dimColor>project:</Text>
				<Text>{project.split("/").pop()}</Text>
			</Box>
			<Box gap={2}>
				<Text dimColor>cycle:</Text>
				<Text bold>{cycle}</Text>
				<Text dimColor>status:</Text>
				<Text color={statusColor(status)}>{status}</Text>
				{state?.lastDecision && (
					<>
						<Text dimColor>last:</Text>
						<Text>{state.lastDecision}</Text>
					</>
				)}
			</Box>
		</Box>
	);
}
