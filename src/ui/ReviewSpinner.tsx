import { Box, Text } from "ink";
import Spinner from "ink-spinner";

interface Props {
	active: boolean;
	decision?: string;
}

export function ReviewSpinner({ active, decision }: Props) {
	if (!active) {
		if (decision) {
			return (
				<Box paddingX={1}>
					<Text dimColor>Last review: </Text>
					<Text color={decision === "APPROVE" ? "green" : "yellow"}>{decision}</Text>
				</Box>
			);
		}
		return null;
	}

	return (
		<Box paddingX={1} gap={1}>
			<Text color="yellow">
				<Spinner type="dots" />
			</Text>
			<Text>Codex is reviewing...</Text>
		</Box>
	);
}
