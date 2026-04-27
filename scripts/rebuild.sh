#!/bin/bash
# Fast rebuild + relaunch with session restore.
# Sessions are persisted on quit and auto-restored on launch.
#
# Usage: ./scripts/rebuild.sh
#   or:  ./scripts/rebuild.sh --run  (also launches after build)

set -e
cd "$(dirname "$0")/.."

APP_NAME="PairApp"
INSTALLED_APP_NAME="Pair"
APP_DIR="app/PairApp"
BUILD_DIR="$APP_DIR/.build/debug"
BUNDLE="$BUILD_DIR/$APP_NAME"

echo "▸ Building $APP_NAME..."
time (cd "$APP_DIR" && swift build 2>&1 | tail -5)

if [[ "$1" == "--run" ]] || [[ "$1" == "-r" ]]; then
    # Gracefully quit the running app (triggers persistSessionDirs)
    if pgrep -x "$APP_NAME" > /dev/null 2>&1 || pgrep -x "$INSTALLED_APP_NAME" > /dev/null 2>&1; then
        echo "▸ Quitting running Pair app..."
        osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
        osascript -e "tell application \"$INSTALLED_APP_NAME\" to quit" 2>/dev/null || true
        # Wait for clean exit (up to 3s)
        for i in {1..30}; do
            if ! pgrep -x "$APP_NAME" > /dev/null 2>&1 && ! pgrep -x "$INSTALLED_APP_NAME" > /dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
        # Force kill if still running
        pkill -9 -x "$APP_NAME" 2>/dev/null || true
        pkill -9 -x "$INSTALLED_APP_NAME" 2>/dev/null || true
        sleep 0.2
    fi

    echo "▸ Launching $APP_NAME..."
    "$BUNDLE" &
    disown
    echo "✓ $APP_NAME launched (sessions will auto-restore)"
else
    echo "✓ Build complete. Run with --run to also relaunch."
fi
