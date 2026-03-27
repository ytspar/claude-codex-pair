#!/bin/bash
# Double-click this file to allow Pair.app to run on macOS
# (removes the quarantine flag that triggers the Gatekeeper warning)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/Pair.app"

if [ ! -d "$APP_PATH" ]; then
    echo "Pair.app not found next to this script."
    echo "Make sure install.command and Pair.app are in the same folder."
    read -p "Press Enter to close..."
    exit 1
fi

echo "Removing macOS quarantine from Pair.app..."
xattr -cr "$APP_PATH"
echo "Done. Opening Pair..."
open "$APP_PATH"
