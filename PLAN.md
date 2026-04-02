# claude-codex-pair  - Implementation Plan

## What This Is

A CLI tool that makes Codex an autonomous reviewer for active Claude Code sessions. When Claude pauses (completes a task, asks a question), Codex reviews the modified files and Claude's output, then decides: approve, provide feedback, or add context. Claude receives the feedback and continues. On completion, a report of all interactions is generated.

## Architecture

```text
┌─────────────────────┐     Stop hook    ┌─────────────────────┐
│   Claude Code       │ ───────────────→ │  hook-handler.ts     │
│   (active session)  │                  │                      │
│                     │ ←──────────────  │  1. Parse transcript │
│   Reads hook        │  {decision,      │  2. git diff         │
│   response, either  │   reason}        │  3. codex exec       │
│   stops or continues│                  │  4. Log interaction  │
└─────────────────────┘                  └──────────┬───────────┘
                                                    │
        ┌───────────────────────────────────────────┘
        ▼
┌─────────────────────┐          ┌─────────────────────┐
│  codex exec          │          │  Ink TUI (pair start)│
│  -s read-only        │          │  Real-time dashboard │
│  -o /tmp/response    │          │  Session status      │
│  --json              │          │  Cycle log           │
└─────────────────────┘          └─────────────────────┘
```

### Integration Point: Claude Code Hooks

The `Stop` hook fires when Claude thinks it's done. The hook:
- Receives `{session_id, transcript_path, cwd}` via stdin JSON
- Reads the JSONL transcript to extract Claude's last actions
- Runs `git diff` to see what changed
- Calls `codex exec` with a review prompt
- Returns `{"decision": "block", "reason": "<feedback>"}` to send Claude back, or exits 0 to approve

### Ink TUI

`pair start` renders a live dashboard showing:
- Active session ID and project
- Current cycle number
- Codex review status (waiting / reviewing / approved / feedback sent)
- Scrollable interaction history
- Git diff summary

## Tech Stack

- **Ink 5** + React 18 for the TUI
- **Commander** for subcommand routing (start/stop/status/review/report)
- **TSX** files for Ink components, regular TS for non-UI modules
- **execFile** (not exec) for spawning codex  - no shell injection risk
- **tsc** with `"jsx": "react-jsx"` for TSX compilation

## Project Structure

```
~/git/ytspar/claude-codex-pair/
├── src/
│   ├── cli.tsx                       # Entry point: Commander routes to Ink apps
│   ├── types.ts                      # HookInput, CodexDecision, InteractionEntry, PairConfig
│   │
│   ├── ui/                           # Ink components
│   │   ├── MonitorApp.tsx            # Main dashboard: session status + cycle log
│   │   ├── StatusBar.tsx             # Top bar: session ID, project, cycle count
│   │   ├── CycleLog.tsx              # Scrollable list of Claude↔Codex interactions
│   │   └── ReviewSpinner.tsx         # Codex review in-progress indicator
│   │
│   ├── monitor/
│   │   ├── daemon.ts                 # Install/remove hooks from ~/.claude/settings.json
│   │   ├── hook-handler.ts           # Stop hook script (standalone, receives stdin)
│   │   ├── transcript.ts             # Parse Claude JSONL transcripts
│   │   ├── session-watcher.ts        # Watch ~/.claude/sessions/ for active sessions
│   │   └── state.ts                  # Shared state file for hook↔TUI communication
│   │
│   ├── codex/
│   │   ├── client.ts                 # Spawn codex exec, handle timeout/errors
│   │   ├── prompt-builder.ts         # Build review prompt from transcript + diff
│   │   └── response-parser.ts        # Parse codex output → APPROVE/FEEDBACK/CONTEXT
│   │
│   ├── report/
│   │   ├── logger.ts                 # Append interaction entries to session JSONL
│   │   └── generator.ts              # Generate markdown report from JSONL
│   │
│   └── shared/
│       ├── config.ts                 # ~/.claude-codex-pair/config.json management
│       ├── git.ts                    # execFile-based git diff helpers
│       └── formatter.ts              # Color helpers for non-Ink output
│
├── package.json                      # ink, react, commander, cli-table3
├── tsconfig.json                     # jsx: react-jsx, ES2022, Node16
├── biome.json
├── .gitignore
└── README.md
```

## CLI Commands

```bash
pair start [--session <id>]     # Launch Ink TUI, install hooks, monitor
pair stop                       # Remove hooks, clean up
pair status                     # Quick status check (non-Ink)
pair review [--session <id>]    # One-shot: Codex reviews current diff
pair report [--session <id>]    # Generate markdown report
pair config                     # Show config
pair config set <key> <value>   # Update config
```

## Implementation Order

### Phase 1: Scaffolding
- [ ] `package.json`, `tsconfig.json` (jsx: react-jsx), `biome.json`
- [ ] `npm install`
- [ ] Verify TSX compiles: minimal `src/cli.tsx` with Ink hello world
- [ ] `git init`, initial commit

### Phase 2: Core Non-UI Modules
- [ ] `src/types.ts`  - all type definitions
- [ ] `src/shared/config.ts`  - config read/write
- [ ] `src/shared/git.ts`  - git diff helpers (execFile, not exec)
- [ ] `src/monitor/transcript.ts`  - parse Claude JSONL transcripts
- [ ] `src/codex/client.ts`  - spawn codex, capture output
- [ ] `src/codex/prompt-builder.ts`  - build review prompts
- [ ] `src/codex/response-parser.ts`  - classify APPROVE/FEEDBACK/CONTEXT
- [ ] `src/report/logger.ts`  - JSONL interaction logging
- [ ] `src/report/generator.ts`  - markdown report generation

### Phase 3: Hook System
- [ ] `src/monitor/daemon.ts`  - install/remove Stop hook in `~/.claude/settings.json`
- [ ] `src/monitor/hook-handler.ts`  - standalone script, receives stdin, orchestrates Codex call
- [ ] `src/monitor/state.ts`  - shared state file for hook↔TUI communication
- [x] Test: manually trigger hook with mock stdin JSON (validated  - hook processes input, calls Codex, returns verdict)

### Phase 4: Ink TUI
- [ ] `src/ui/StatusBar.tsx`  - session info + cycle count
- [ ] `src/ui/CycleLog.tsx`  - scrollable interaction history
- [ ] `src/ui/ReviewSpinner.tsx`  - Codex review progress
- [ ] `src/ui/MonitorApp.tsx`  - compose into main dashboard
- [ ] `src/monitor/session-watcher.ts`  - watch for active sessions

### Phase 5: CLI Integration
- [ ] `src/cli.tsx`  - Commander routes: start → Ink app, stop/status/review/report → non-Ink handlers
- [ ] Wire `pair start` to install hooks + launch TUI
- [ ] Wire `pair stop` to remove hooks
- [ ] Wire `pair review` for one-shot Codex review
- [ ] Wire `pair report` for report generation
- [x] `npm link` and test end-to-end (validated  - `pair --version`, `pair config`, `pair status`, `pair review`, `pair report` all work)

### Phase 6: Polish
- [ ] README.md with usage examples
- [ ] Graceful error handling (Codex not installed, no active session, etc.)
- [ ] Max cycle safety limit
- [ ] Hook timeout configuration (120s for Codex calls)
- [ ] `pair config` commands

## Key Design Decisions

### Hook handler is a separate entry point
`hook-handler.ts` runs as a standalone Node.js script spawned by Claude Code's hook system. It does NOT run inside the Ink TUI process. Communication between hook and TUI happens via a shared state file (`~/.claude-codex-pair/state/{session_id}.json`).

### Codex is always read-only
`codex exec -s read-only` ensures Codex can never modify files. It reviews and advises only.

### Max cycle limit
Default 5 cycles. After that, auto-approve to prevent infinite loops. Configurable via `pair config set maxCycles N`.

### Graceful degradation
If Codex fails, times out, or isn't installed, the hook exits 0 (Claude proceeds normally). The TUI shows the error but doesn't block Claude.

### Hook installation is reversible
`pair start` adds our hooks to `~/.claude/settings.json`. `pair stop` (or quitting the TUI) removes them by filtering out our specific entries, preserving all other hooks. Clean uninstall guaranteed.

### PermissionRequest hook (Codex-gated)
A second hook handles Claude's permission requests (Write, Edit, Bash). Read-only tools are auto-approved. For mutations, Codex makes a quick YES/NO decision  - approving unless clearly dangerous. This prevents Claude from blocking on permission dialogs during paired sessions while keeping Codex as the safety gate.

### Ghostty input injection
When Codex needs to respond to Claude (answering questions, sending feedback), it types into the correct Ghostty terminal window via macOS AppleScript/System Events. This is more effective than hook block reasons because Claude receives it as real user input. Clipboard is saved/restored, focus is verified before pasting, and the system falls back to hook block if Ghostty is unavailable.

### Two prompt modes
- **Review mode**: Claude finished working → Codex checks if the original task is complete
- **Respond mode**: Claude asked a question → Codex answers as the human, always choosing the most thorough option

## Codex Review Prompt Template

```
You are reviewing code changes made by Claude Code in an active development session.

PROJECT: {cwd}
GIT DIFF STATS: {diffStat}

CLAUDE'S LAST ACTIONS:
{last 3-5 assistant messages summarized}

FILES CHANGED:
{git diff, truncated to 4000 chars}

Review the changes and respond with EXACTLY ONE of these verdicts:

APPROVE  - The changes look correct, complete, and safe. No issues found.
FEEDBACK  - You found issues that should be addressed. Describe each issue concisely.
CONTEXT  - You need additional context to review properly. State what's missing.

Start your response with the verdict on its own line, then explain below.
```

## Config

`~/.claude-codex-pair/config.json`:
```json
{
  "maxCycles": 5,
  "codexModel": null,
  "codexTimeout": 300000,
  "logDir": "~/.claude-codex-pair/sessions"
}
```

## State File (hook↔TUI communication)

`~/.claude-codex-pair/state/{session_id}.json`:
```json
{
  "cycle": 2,
  "status": "reviewing",
  "lastUpdate": "2026-03-25T22:05:00Z",
  "lastDecision": "FEEDBACK",
  "lastResponse": "The function doesn't handle..."
}
```

The Ink TUI polls this file to update the dashboard. The hook handler writes to it during each cycle.
