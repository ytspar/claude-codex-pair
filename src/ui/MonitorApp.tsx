import { useState, useEffect, useMemo } from "react";
import { Box, Text, useApp, useInput, useStdout } from "ink";
import { SessionPane } from "./SessionPane.js";
import { findActiveSessions, type ActiveSession } from "../monitor/session-watcher.js";

interface Props {
	sessionId?: string;
	project: string;
}

export function MonitorApp({ sessionId, project }: Props): JSX.Element {
	const { exit } = useApp();
	const { stdout } = useStdout();
	const [sessions, setSessions] = useState<ActiveSession[]>([]);
	const [scrollOffset, setScrollOffset] = useState(0);
	const [selectedIdx, setSelectedIdx] = useState(0);
	const [expandedIdx, setExpandedIdx] = useState<number | null>(null);

	const termHeight = stdout?.rows ?? 40;
	const viewportHeight = Math.max(10, termHeight - 4);

	useEffect(() => {
		const poll = () => {
			const found = findActiveSessions();
			if (sessionId) {
				setSessions(found.filter((s) => s.sessionId === sessionId || s.sessionId.startsWith(sessionId)));
			} else {
				setSessions(found);
			}
		};
		poll();
		const interval = setInterval(poll, 5000);
		return () => clearInterval(interval);
	}, [sessionId]);

	const clampedIdx = useMemo(() => Math.min(selectedIdx, Math.max(0, sessions.length - 1)), [selectedIdx, sessions.length]);

	useInput((input, key) => {
		if (input === "q") exit();
		if (key.return) {
			// Toggle expand/collapse
			setExpandedIdx((cur) => (cur === clampedIdx ? null : clampedIdx));
		}
		if (key.upArrow || input === "k") {
			setSelectedIdx((i) => Math.max(0, i - 1));
			setScrollOffset((o) => {
				const newIdx = Math.max(0, clampedIdx - 1);
				if (newIdx < o) return newIdx;
				return o;
			});
		}
		if (key.downArrow || input === "j") {
			setSelectedIdx((i) => Math.min(sessions.length - 1, i + 1));
			setScrollOffset((o) => {
				const newIdx = Math.min(sessions.length - 1, clampedIdx + 1);
				const maxVisible = Math.max(1, Math.floor(viewportHeight / 10));
				if (newIdx >= o + maxVisible) return newIdx - maxVisible + 1;
				return o;
			});
		}
		if (key.escape) {
			setExpandedIdx(null);
		}
	});

	const maxVisible = expandedIdx !== null ? sessions.length : Math.max(1, Math.floor(viewportHeight / 10));
	const visibleSessions = expandedIdx !== null ? sessions : sessions.slice(scrollOffset, scrollOffset + maxVisible);
	const hasMore = expandedIdx === null && sessions.length > scrollOffset + maxVisible;
	const hasPrev = expandedIdx === null && scrollOffset > 0;

	return (
		<Box flexDirection="column" height={termHeight}>
			{/* Header */}
			<Box paddingX={1} gap={2}>
				<Text bold color="cyan">claude-codex-pair</Text>
				<Text dimColor>{sessions.length} session{sessions.length !== 1 ? "s" : ""}</Text>
				<Text dimColor>cwd: {project.split("/").pop()}</Text>
			</Box>

			{hasPrev && (
				<Box paddingX={1}>
					<Text dimColor>▲ {scrollOffset} more above</Text>
				</Box>
			)}

			{/* Session panes */}
			<Box flexDirection="column" flexGrow={1} overflow="hidden">
				{visibleSessions.length === 0 ? (
					<Box paddingX={1} marginTop={1}>
						<Text dimColor>No active Claude Code sessions detected.</Text>
					</Box>
				) : (
					visibleSessions.map((s) => {
						const globalIdx = sessions.indexOf(s);
						const isExpanded = globalIdx === expandedIdx;
						// When one pane is expanded, hide the others
						if (expandedIdx !== null && !isExpanded) return null;
						return (
							<SessionPane
								key={s.sessionId}
								sessionId={s.sessionId}
								project={s.cwd.split("/").pop() ?? s.cwd}
								pid={s.pid}
								selected={globalIdx === clampedIdx}
								expanded={isExpanded}
							/>
						);
					})
				)}
			</Box>

			{hasMore && (
				<Box paddingX={1}>
					<Text dimColor>▼ {sessions.length - scrollOffset - maxVisible} more below</Text>
				</Box>
			)}

			{/* Footer */}
			<Box paddingX={1} gap={2}>
				<Text dimColor>q quit</Text>
				<Text dimColor>j/k scroll</Text>
				<Text dimColor>enter expand</Text>
				{expandedIdx !== null && <Text dimColor>esc collapse</Text>}
				<Text dimColor>{clampedIdx + 1}/{sessions.length}</Text>
			</Box>
		</Box>
	);
}
