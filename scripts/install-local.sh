#!/bin/bash
# Build PairApp + npm package and install to /Applications/Pair.app.
# Ad-hoc signed (no notarization) — for local development, not distribution.
# For full signed/notarized release, use scripts/release.sh.
#
# Usage: ./scripts/install-local.sh [--launch]

set -e
cd "$(dirname "$0")/.."

REPO_ROOT="$(pwd)"
APP_DIR="$REPO_ROOT/app/PairApp"
BUILD_DIR="$APP_DIR/.build/release"
DST_APP="/Applications/Pair.app"

echo "▸ Building npm package + pair-terminal daemon..."
npm run build > /dev/null

echo "▸ Building PairApp (release)..."
(cd "$APP_DIR" && swift build -c release 2>&1 | tail -3)

if pgrep -x "Pair" > /dev/null 2>&1 || pgrep -x "PairApp" > /dev/null 2>&1; then
    echo "▸ Quitting running Pair instance..."
    osascript -e 'tell application "Pair" to quit' 2>/dev/null || true
    for _ in {1..30}; do
        pgrep -x "Pair" > /dev/null 2>&1 || pgrep -x "PairApp" > /dev/null 2>&1 || break
        sleep 0.1
    done
    pkill -9 -x "Pair" 2>/dev/null || true
    pkill -9 -x "PairApp" 2>/dev/null || true
fi

if [ ! -d "$DST_APP" ]; then
    echo "▸ Creating bundle at $DST_APP..."
    VERSION=$(node -p "require('$REPO_ROOT/package.json').version")
    mkdir -p "$DST_APP/Contents/MacOS" "$DST_APP/Contents/Resources"
    cat > "$DST_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Pair</string>
    <key>CFBundleIdentifier</key><string>com.ytspar.pair</string>
    <key>CFBundleName</key><string>Pair</string>
    <key>CFBundleDisplayName</key><string>Pair</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST
fi

echo "▸ Installing to $DST_APP..."
cp "$BUILD_DIR/PairApp" "$DST_APP/Contents/MacOS/Pair"
if [ -d "$BUILD_DIR/PairApp_PairApp.bundle" ]; then
    rm -rf "$DST_APP/Contents/Resources/PairApp_PairApp.bundle"
    cp -R "$BUILD_DIR/PairApp_PairApp.bundle" "$DST_APP/Contents/Resources/"
fi
ICON="$APP_DIR/Sources/PairApp/Resources/AppIcon.icns"
[ -f "$ICON" ] && [ ! -f "$DST_APP/Contents/Resources/AppIcon.icns" ] && cp "$ICON" "$DST_APP/Contents/Resources/"

xattr -cr "$DST_APP"
codesign --force --deep --sign - "$DST_APP" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$DST_APP"

echo "✓ Installed Pair.app ($(du -sh "$DST_APP/Contents/MacOS/Pair" | cut -f1) binary)"

if [[ "$1" == "--launch" ]] || [[ "$1" == "-l" ]]; then
    echo "▸ Launching Pair..."
    open "$DST_APP"
fi
