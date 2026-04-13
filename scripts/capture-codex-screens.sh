#!/bin/bash
# Capture Codex CLI interactive TUI screen patterns using `script`.
# This records the raw terminal output to analyze Codex's TUI structure.
#
# Usage: bash scripts/capture-codex-screens.sh

OUTPUT_DIR=".codex-pair/screen-captures"
mkdir -p "$OUTPUT_DIR"

echo "=== Codex TUI Screen Capture ==="
echo "Output: $OUTPUT_DIR"
echo ""
echo "This will run Codex interactively with 'script' recording."
echo "The session will auto-send prompts and capture screens."
echo ""

# Use 'script' to capture full terminal session including escape codes
TYPESCRIPT="$OUTPUT_DIR/codex-session.typescript"

# Create an expect-like script that sends prompts at intervals
SEND_SCRIPT="$OUTPUT_DIR/send-prompts.sh"
cat > "$SEND_SCRIPT" << 'SENDEOF'
#!/bin/bash
# Wait for Codex to start up
sleep 8

# Capture startup screen
echo "=== SCREEN CAPTURE: startup ===" >> /tmp/codex-screens.log
sleep 2

# Send first prompt
echo "What files are in app/PairApp/Sources/PairApp/? Just list the filenames."
sleep 20

# Send second prompt
echo "How many lines is ClaudeMonitor.swift?"
sleep 20

# Send a prompt that should trigger tool approval
echo "Create a file /tmp/codex-capture-test.txt with 'hello'"
sleep 20

# Send exit
echo "/exit"
sleep 2
SENDEOF
chmod +x "$SEND_SCRIPT"

# Run Codex with script recording, piping prompts from our send script
echo "Starting Codex with script recording..."
script -q "$TYPESCRIPT" bash -c "cat '$SEND_SCRIPT' | codex --full-auto 2>&1"

echo ""
echo "Session recorded to $TYPESCRIPT"
echo ""

# Post-process: strip ANSI codes and split into readable screens
echo "Post-processing..."
cat "$TYPESCRIPT" | \
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | \
  sed 's/\x1b\][^\x07]*\x07//g' | \
  sed 's/\x1b[()][0-9A-Za-z]//g' | \
  tr -d '\000-\010\013\014\016-\037' > "$OUTPUT_DIR/codex-session-clean.txt"

echo "Clean output: $OUTPUT_DIR/codex-session-clean.txt"

# Extract interesting sections
echo ""
echo "=== Key patterns found ==="
echo ""
echo "Lines containing prompt-like markers:"
grep -n ">" "$OUTPUT_DIR/codex-session-clean.txt" | head -20
echo ""
echo "Lines containing selection/approval markers:"
grep -in "allow\|approve\|select\|yes\|no\|confirm\|sandbox" "$OUTPUT_DIR/codex-session-clean.txt" | head -20
echo ""
echo "Lines containing navigation hints:"
grep -in "enter\|esc\|arrow\|navigate\|tab" "$OUTPUT_DIR/codex-session-clean.txt" | head -20
echo ""
echo "Done."
