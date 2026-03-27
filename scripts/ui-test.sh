#!/bin/bash
# UI integration test for PairApp
# Launches the app, interacts via AppleScript, verifies behavior.

set -e

PASS=0
FAIL=0
LOG="$HOME/.claude-codex-pair/pairapp.log"

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

# Run osascript with a timeout
run_osa() {
    timeout 5 osascript -e "$1" 2>/dev/null
}

echo "=== PairApp UI Test Suite ==="
echo ""

# Clean state
pkill -f Pair 2>/dev/null || true
sleep 1
> "$LOG"

# ── Test 1: App launches ──
echo "Test 1: Launch"
open /Applications/Pair.app
sleep 5

if pgrep -x "Pair" > /dev/null 2>&1 || pgrep -f "PairApp" > /dev/null 2>&1; then
    pass "App is running"
else
    fail "App did not start"
    exit 1
fi

WINDOW=$(run_osa 'tell application "System Events" to tell process "Pair" to get name of window 1' || echo "")
if [[ -n "$WINDOW" ]]; then
    pass "Window: $WINDOW"
else
    fail "No window found"
fi

# ── Test 2: Auth ──
echo "Test 2: Auth"
sleep 2
grep -q "Auth check:" "$LOG" && pass "Auth check ran" || fail "No auth check"
grep -q "claude=true" "$LOG" && pass "Claude OK" || fail "Claude not auth'd"
grep -q "codex=true" "$LOG" && pass "Codex OK" || fail "Codex not auth'd"

# ── Test 3: Monitor ──
echo "Test 3: Monitor"
grep -q "ClaudeMonitor started" "$LOG" && pass "Monitor started" || fail "Monitor not started"
grep -q "Poll #" "$LOG" && pass "Polling active" || fail "Not polling"

# ── Test 4: IPC ──
echo "Test 4: IPC"
if [ -S "$HOME/.claude-codex-pair/pair-terminal.sock" ]; then
    pass "Socket exists"
    RESP=$(echo '{"action":"list_sessions"}' | timeout 3 nc -U "$HOME/.claude-codex-pair/pair-terminal.sock" 2>/dev/null || echo "")
    if echo "$RESP" | grep -q '"ok":true'; then
        pass "IPC responds"
    else
        fail "IPC no response: $RESP"
    fi
else
    fail "No socket"
fi

# ── Test 5: Create session ──
echo "Test 5: Session"
echo '{"action":"create_session","surface":"ui-test","text":"/tmp"}' | timeout 3 nc -U "$HOME/.claude-codex-pair/pair-terminal.sock" 2>/dev/null > /dev/null
sleep 3
grep -q "makeNSView" "$LOG" && pass "Terminal created" || fail "No terminal"
grep -q "Creating session" "$LOG" && pass "Session logged" || fail "Session not logged"

# ── Test 6: Cmd+T (new tab) ──
echo "Test 6: Cmd+T"
run_osa 'tell application "System Events" to tell process "Pair" to keystroke "t" using command down'
sleep 2
# Verify app survived
if pgrep -x "Pair" > /dev/null 2>&1 || pgrep -f "PairApp" > /dev/null 2>&1; then
    pass "Cmd+T didn't crash"
else
    fail "Crashed on Cmd+T"
fi

# ── Test 7: Cmd+W (close session) ──
echo "Test 7: Cmd+W"
run_osa 'tell application "System Events" to tell process "Pair" to keystroke "w" using command down'
sleep 2
if pgrep -x "Pair" > /dev/null 2>&1 || pgrep -f "PairApp" > /dev/null 2>&1; then
    pass "Cmd+W didn't crash"
else
    fail "Crashed on Cmd+W"
fi

# ── Cleanup ──
echo ""
pkill -f Pair 2>/dev/null || true
sleep 1

echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && exit 0 || exit 1
