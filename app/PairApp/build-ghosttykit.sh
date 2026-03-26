#!/bin/bash
# Build GhosttyKit.xcframework from the Ghostty source
# Requires: Zig 0.15.2+, Xcode with Metal toolchain

GHOSTTY_DIR="/tmp/ghostty-lib"
OUTPUT_DIR="$(dirname "$0")/Frameworks"

if [ ! -d "$GHOSTTY_DIR" ]; then
    echo "Cloning Ghostty..."
    git clone --depth 1 https://github.com/ghostty-org/ghostty.git "$GHOSTTY_DIR"
fi

echo "Building GhosttyKit.xcframework..."
cd "$GHOSTTY_DIR"
zig build -Demit-xcframework=true -Doptimize=ReleaseFast

mkdir -p "$OUTPUT_DIR"
cp -R "$GHOSTTY_DIR/macos/GhosttyKit.xcframework" "$OUTPUT_DIR/"
echo "Done: $OUTPUT_DIR/GhosttyKit.xcframework"
