#!/bin/bash
# UI integration test for PairApp
# Launches the app, interacts with it via AppleScript, verifies behavior.
# Requires: PairApp built and installed at /Applications/Pair.app

set -e

PASS=0
FAIL=0
LOG="$HOME/.claude-codex-pair/pairapp.log"

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

echo "=== PairApp UI Test Suite ==="
echo ""

# Clean state
pkill -f Pair 2>/dev/null || true
sleep 1
> "$LOG"

# ── Test 1: App launches ──
echo "Test 1: App launches"
open /Applications/Pair.app
sleep 4

if pgrep -f "Pair" > /dev/null; then
    pass "App is running"
else
    fail "App did not start"
    exit 1
fi

# Verify window exists
WINDOW=$(osascript -e '
tell application "System Events"
    tell process "Pair"
        if (count of windows) > 0 then
            return name of window 1
        end if
    end tell
end tell' 2>/dev/null)

if [[ "$WINDOW" == *"Pair"* ]] || [[ "$WINDOW" == *"Claude"* ]]; then
    pass "Window visible: $WINDOW"
else
    fail "Window not found: $WINDOW"
fi

# ── Test 2: Auth check completes ──
echo "Test 2: Auth check"
sleep 5
if grep -q "Auth check:" "$LOG"; then
    pass "Auth check ran"
    if grep -q "claude=true" "$LOG"; then
        pass "Claude authenticated"
    else
        fail "Claude not authenticated"
    fi
    if grep -q "codex=true" "$LOG"; then
        pass "Codex authenticated"
    else
        fail "Codex not authenticated"
    fi
else
    fail "Auth check did not run"
fi

# ── Test 3: Monitor started ──
echo "Test 3: ClaudeMonitor"
if grep -q "ClaudeMonitor started" "$LOG"; then
    pass "Monitor polling"
else
    fail "Monitor not started"
fi

# ── Test 4: IPC socket ──
echo "Test 4: IPC socket"
if [ -S "$HOME/.claude-codex-pair/pair-terminal.sock" ]; then
    pass "Socket exists"

    # Test list_sessions
    RESPONSE=$(echo '{"action":"list_sessions"}' | nc -U "$HOME/.claude-codex-pair/pair-terminal.sock" 2>/dev/null)
    if echo "$RESPONSE" | grep -q '"ok":true'; then
        pass "IPC responds to list_sessions"
    else
        fail "IPC did not respond: $RESPONSE"
    fi
else
    fail "Socket not found"
fi

# ── Test 5: Create session via IPC ──
echo "Test 5: Create session"
RESPONSE=$(echo '{"action":"create_session","surface":"ui-test","text":"/tmp"}' | nc -U "$HOME/.claude-codex-pair/pair-terminal.sock" 2>/dev/null)
if echo "$RESPONSE" | grep -q '"ok":true'; then
    pass "Session created via IPC"
else
    fail "Session creation failed: $RESPONSE"
fi
sleep 3

if grep -q "makeNSView" "$LOG"; then
    pass "Terminal view created"
else
    fail "Terminal view not created"
fi

# ── Test 6: Menu bar exists ──
echo "Test 6: Menu bar"
MENUS=$(osascript -e '
tell application "System Events"
    tell process "Pair"
        set frontmost to true
        return name of every menu bar item of menu bar 1
    end tell
end tell' 2>/dev/null)

if echo "$MENUS" | grep -q "File"; then
    pass "File menu exists"
else
    fail "File menu not found: $MENUS"
fi

if echo "$MENUS" | grep -q "View"; then
    pass "View menu exists"
else
    fail "View menu not found"
fi

# ── Test 7: Keyboard shortcut (Cmd+W closes session) ──
echo "Test 7: Cmd+W closes session"
osascript -e '
tell application "System Events"
    tell process "Pair"
        set frontmost to true
        keystroke "w" using command down
    end tell
end tell' 2>/dev/null
sleep 2

SESSIONS=$(echo '{"action":"list_sessions"}' | nc -U "$HOME/.claude-codex-pair/pair-terminal.sock" 2>/dev/null)
if echo "$SESSIONS" | grep -q '"result":"\[\]"' || echo "$SESSIONS" | grep -q '"result":"[]"'; then
    pass "Session closed via Cmd+W"
else
    # Session might still exist if Cmd+W didn't work
    fail "Session may not have closed: $SESSIONS"
fi

# ── Cleanup ──
echo ""
pkill -f Pair 2>/dev/null || true

echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1
