# Changelog

## v0.2.0 - April 3, 2026

### Autoresearch-Inspired Self-Improving Monitor
- **Eval/strategy layer separation**: Screen detection (immutable) cleanly separated from decision logic (mutable)
- **Progress signals**: Git-based scalar metrics (commits, file changes, diff size) measure intervention effectiveness
- **Outcome tracking**: Each Codex review is scored as improved/neutral/regressed 30s after delivery
- **Exponential backoff**: When interventions aren't helping, review frequency drops (2x→4x→8x→10x cap), resets on improvement
- **Review cycle timeout**: 5-minute hard kill prevents stuck review loops
- **Commit nudging**: Codex prompts Claude to commit after meaningful changes, then verifies on next cycle
- **Reflexion-style prompts**: Codex sees its last 5 decisions with outcomes, avoids repeating regressions
- **Per-project strategy memory**: `.codex-pair/strategy.md` persists what works across sessions
- **Unmatched prompt pattern tracking**: Detection heuristic misses are logged for future improvement

### UI Enhancements
- Backoff indicator (yellow badge) in status strip when reviews are throttled
- Effectiveness stats in footer (e.g., "3/8 helped")
- Thumbs up/down on timeline entries — user feedback overrides git-based outcomes
- Session-level outcome counters (improved/neutral/regressed)

### Task Queue & Monitor Improvements
- Task queue with start/stop, immediate dequeue
- Active-tab-only monitoring, modal view dismissal
- Loop detection across review cycles
- Screenshot capture support

## v0.1.1  - March 26, 2026

### GhosttyKit Metal Rendering
- Switched from SwiftTerm to GhosttyKit as the only terminal backend
- GPU-accelerated rendering via Metal (same engine as Ghostty)
- Reads user's ~/.config/ghostty/config for colors and fonts

### UI Polish
- Departure Mono typeface everywhere (auth, project picker, scratchpad, toolbar, dialogs)
- Themed quit confirmation dialog with app icon
- Browse opens as a new tab (doesn't replace active session)
- Scratchpad: terminal-style keybindings (Ctrl+W/A/E/K/U), Cmd+Enter to send, Esc to clear
- Scratchpad "Send" button shows ⌘↩ shortcut on hover
- Cmd+T opens new tab with project picker
- Auto-focus terminal on session create
- pair launch brings app to front

### Fixes
- Fixed "pasting text" on every keystroke (use ghostty_surface_key with text field)
- Fixed tab switching crash (keep all views alive, toggle opacity)
- Fixed divider gray bar (SwiftTerm scroller was visible)
- Socket permissions locked to current user (chmod 0600)
- Dynamic NVM path scanning instead of hardcoded version
- FileHandle leak fix in logger

## v0.1.0  - March 26, 2026

Initial release. See README for full feature list.
