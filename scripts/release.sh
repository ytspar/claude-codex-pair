#!/bin/bash
# Release script for Pair (claude-codex-pair)
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 0.2.0

set -e

VERSION="${1:?Usage: $0 <version> (e.g. 0.2.0)}"
DATE=$(date +%Y-%m-%d)
DISPLAY_DATE=$(date +"%B %-d, %Y")
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Releasing Pair v${VERSION} (${DATE}) ==="

# 1. Update Version.swift
echo "Updating Version.swift..."
cat > "$REPO_ROOT/app/PairApp/Sources/PairApp/Version.swift" << EOF
import Foundation

/// Single source of truth for version info.
/// Updated by scripts/release.sh
enum AppVersion {
    static let version = "${VERSION}"
    static let buildDate = "${DATE}"

    static var displayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: buildDate) {
            let display = DateFormatter()
            display.dateFormat = "MMMM d, yyyy"
            return "v\(version) · \(display.string(from: date))"
        }
        return "v\(version)"
    }
}
EOF

# 2. Update package.json version
echo "Updating package.json..."
cd "$REPO_ROOT"
sed -i '' "s/\"version\": \"[^\"]*\"/\"version\": \"${VERSION}\"/" package.json

# 3. Build release binary
echo "Building release binary..."
cd "$REPO_ROOT/app/PairApp"
swift build -c release

# 4. Package .app bundle
echo "Packaging Pair.app..."
RELEASE_DIR="/tmp/pair-release-${VERSION}"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR/Pair.app/Contents/MacOS"
mkdir -p "$RELEASE_DIR/Pair.app/Contents/Resources"

cp .build/release/PairApp "$RELEASE_DIR/Pair.app/Contents/MacOS/Pair"
cp -R .build/release/PairApp_PairApp.bundle "$RELEASE_DIR/Pair.app/Contents/Resources/" 2>/dev/null || true
cp Sources/PairApp/Resources/AppIcon.icns "$RELEASE_DIR/Pair.app/Contents/Resources/" 2>/dev/null || true

cat > "$RELEASE_DIR/Pair.app/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Pair</string>
    <key>CFBundleIdentifier</key><string>com.ytspar.pair</string>
    <key>CFBundleName</key><string>Pair</string>
    <key>CFBundleDisplayName</key><string>Pair — Claude + Codex</string>
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

# 5. Zip
echo "Creating zip..."
cd /tmp
ZIP_NAME="pair-v${VERSION}-macos-arm64.zip"
rm -f "$ZIP_NAME"
cd "$RELEASE_DIR"
zip -r "/tmp/$ZIP_NAME" Pair.app
echo "Created /tmp/$ZIP_NAME ($(du -h /tmp/$ZIP_NAME | cut -f1))"

# 6. Git commit + tag
echo "Committing..."
cd "$REPO_ROOT"
git add -A
git commit -m "Release v${VERSION}

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
git tag "v${VERSION}"

echo ""
echo "=== Release v${VERSION} prepared ==="
echo ""
echo "Next steps:"
echo "  git push && git push --tags"
echo "  gh release create v${VERSION} /tmp/$ZIP_NAME --title 'v${VERSION}' --notes-file CHANGELOG.md"
echo ""
