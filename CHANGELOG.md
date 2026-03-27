# Changelog

## v0.1.1 — March 26, 2026

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

## v0.1.0 — March 26, 2026

Initial release. See README for full feature list.
