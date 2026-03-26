# claude-codex-pair

Codex monitors and reviews active Claude Code sessions, providing autonomous feedback and cross-model validation.

When Claude Code pauses (completes a task or asks a question), Codex reviews the modified files and Claude's output, then decides: **approve**, **provide feedback**, or **request context**. Claude receives the feedback and continues. On completion, a report of all interactions is generated.

## How It Works

```
┌─────────────────────┐     Stop hook    ┌─────────────────────┐
│   Claude Code       │ ───────────────→ │  hook-handler        │
│   (active session)  │                  │                      │
│                     │ ←──────────────  │  1. Parse transcript │
│   Reads hook        │  {decision,      │  2. git diff         │
│   response, either  │   reason}        │  3. codex exec       │
│   stops or continues│                  │  4. Log interaction  │
└─────────────────────┘                  └──────────────────────┘
```

The tool installs a Claude Code [Stop hook](https://docs.anthropic.com/en/docs/claude-code/hooks) that fires every time Claude finishes responding. The hook:

1. Reads Claude's JSONL transcript to extract recent actions
2. Runs `git diff` to see what changed
3. Calls `codex exec -s read-only` with a review prompt
4. Returns `{"decision": "block", "reason": "<feedback>"}` to send Claude back, or approves to let Claude stop

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and configured
- [Codex CLI](https://github.com/openai/codex) installed (`npm install -g @openai/codex`)
- Node.js >= 22

## Install

```bash
git clone https://github.com/ytspar/claude-codex-pair.git
cd claude-codex-pair
npm install
npm run build
npm link
```

## Usage

### Start monitoring

```bash
pair start                    # Auto-detect session, install hooks, launch TUI
pair start --session <id>     # Monitor a specific session
```

This installs the Stop hook into `~/.claude/settings.json`, launches a real-time TUI dashboard, and starts monitoring. Press `q` to quit (hooks are automatically removed).

### Stop monitoring

```bash
pair stop                     # Remove hooks
```

### Quick status check

```bash
pair status                   # Show hook status and recent session info
```

### One-shot review

```bash
pair review                   # Codex reviews current git diff (no hooks needed)
```

### Generate report

```bash
pair report                   # Markdown report from most recent session
pair report --session <id>    # Report for a specific session
```

### Configuration

```bash
pair config show              # Show current config
pair config set maxCycles 10  # Set max review cycles (default: 5)
pair config set codexTimeout 600000  # Codex timeout in ms (default: 300000)
pair config set codexModel gpt-4.1   # Override Codex model
```

Config is stored at `~/.claude-codex-pair/config.json`.

## Configuration Options

| Key | Default | Description |
|-----|---------|-------------|
| `maxCycles` | `5` | Max review cycles before auto-approve |
| `codexModel` | `null` | Override Codex model (null = default) |
| `codexTimeout` | `300000` | Codex call timeout in ms |
| `logDir` | `~/.claude-codex-pair/sessions` | Session log directory |
| `targetSessions` | `null` | Only review these sessions/projects (null = all) |

## Safety

- **Codex is always read-only** — `codex exec -s read-only` ensures Codex can never modify files
- **Max cycle limit** — prevents infinite feedback loops (default 5, configurable)
- **Graceful degradation** — if Codex fails, times out, or isn't installed, Claude proceeds normally
- **Reversible hooks** — `pair start` adds hooks; quitting the TUI or `pair stop` removes them cleanly
- **Permission gating** — Codex reviews Write/Edit/Bash requests, auto-approves reads, blocks dangerous operations
- **Ghostty integration** — feedback is typed into Claude's terminal as real user input (falls back to hook mechanism)

## Session Logs

Interactions are logged as JSONL at `~/.claude-codex-pair/sessions/<session_id>.jsonl`. Use `pair report` to generate a readable markdown summary.

## License

MIT
