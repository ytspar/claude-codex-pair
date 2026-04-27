# Codex Strategy for claude-codex-pair
Updated: 2026-04-27 12:37

## Effectiveness
- Total interventions: 50
- Improved: 0 (0%)
- Regressed: 0 (0%)
- Loop detections: 3
- Avg review duration: 13735ms

## Pending Improvements (auto-queued as tasks)
- Add a hard pre-ingest `NOOP_STOP` guard for startup banner + `WAIT` + `⏺ Waiting.` + clean final `❯` before classification, menu rendering, loop tracking, decision history, or context writes.
- Implement the pre-ingest `NOOP_STOP` guard now: startup banner + `WAIT` + `⏺ Waiting.` + clean final `❯` must be dropped before classification, menu rendering, loop tracking, decision history, or context writes.
- Add a pre-ingest `NOOP_STOP` quarantine for startup banner + `WAIT` + `⏺ Waiting.` + clean final `❯`, before classification, menu rendering, loop tracking, decision history, or context writes.
- Implement the pre-ingest `NOOP_STOP` guard now: startup banner + `WAIT` + `⏺ Waiting.` + clean final `❯` must be dropped before classification, menu rendering, loop tracking, decision history, or context writes.
- Add the pre-ingest `NOOP_STOP` guard before classification, menu rendering, loop tracking, decision history, or context writes.
- Add a pre-ingest `NOOP_STOP` quarantine for this exact idle pattern before classification, menu rendering, loop tracking, decision history, or context writes.
- Add a hard pre-ingest `NOOP_STOP` quarantine for this exact pattern before classification, menu rendering, loop tracking, decision history, or context writes.
- Add a screen-detector heuristic that recognizes Codex CLI JSON error envelopes (`■ {"type":"error"...}`) and auto-escalates with the parsed `error.message`, so we don't waste decisions retrying against a broken model/CLI configuration.
- Add a hard-error detector in ScreenParser/CodexDecision that recognizes `■ {"type":"error","status":<4xx/5xx>"` lines as terminal upstream errors and surfaces a single ESCALATE with a one-time notification (e.g., macOS notification + halts re-decision loop) instead of re-evaluating every poll cycle.
- Add a hard-error deduplication layer in CodexDecision/FeedbackHandler: when the screen contains a `■ {"type":"error","status":4xx,...}` line and the parsed error message matches the previous turn's, short-circuit to a single "human required" notification (e.g., macOS notification + ledger entry) instead of re-running the LLM decision loop. Pattern key: hash of the error JSON. Reset on any terminal-output change.


## Unmatched Prompt Patterns (improve detection heuristics)
- Expected: selection, Got response: 2{}?})
  Screen:   - Swift build: compiles cleanly (2.43s)
  - Swift tests: 33/33 passed, 0 failures (includes integration tests with moc

