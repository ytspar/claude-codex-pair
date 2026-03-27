#!/bin/bash
# Generates/updates the Xcode project from the SPM package.
# Run this after adding/removing Swift files.
#
# Uses tuist or xcodegen if available, falls back to manual pbxproj generation.

set -e
cd "$(dirname "$0")/../app/PairApp"

echo "Generating Xcode project..."

# Find all Swift source files
SOURCES=($(find Sources/PairApp -name "*.swift" | sort))
TESTS=($(find Tests/PairAppTests -name "*.swift" 2>/dev/null | sort))
RESOURCES=($(find Sources/PairApp/Resources -type f 2>/dev/null | sort))

echo "  ${#SOURCES[@]} source files"
echo "  ${#TESTS[@]} test files"
echo "  ${#RESOURCES[@]} resources"

# Check if xcodegen is available (preferred)
if command -v xcodegen &>/dev/null; then
    echo "Using xcodegen..."

    cat > project.yml << 'XCODEGEN'
name: PairApp
options:
  bundleIdPrefix: com.ytspar
  deploymentTarget:
    macOS: "14.0"

targets:
  PairApp:
    type: application
    platform: macOS
    sources:
      - Sources/PairApp
    resources:
      - Sources/PairApp/Resources
    settings:
      base:
        PRODUCT_NAME: Pair
        PRODUCT_BUNDLE_IDENTIFIER: com.ytspar.pair
        GENERATE_INFOPLIST_FILE: YES
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        SWIFT_VERSION: "5.9"
        HEADER_SEARCH_PATHS: $(PROJECT_DIR)/Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64/Headers
        LIBRARY_SEARCH_PATHS: $(PROJECT_DIR)/Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64
        OTHER_LDFLAGS:
          - -lghostty
          - -lz
          - -lc++
      configs:
        debug:
          SWIFT_OPTIMIZATION_LEVEL: -Onone
        release:
          SWIFT_OPTIMIZATION_LEVEL: -O
    dependencies:
      - framework: Carbon.framework
      - framework: Metal.framework
      - framework: MetalKit.framework
      - framework: CoreGraphics.framework
      - framework: QuartzCore.framework
      - framework: CoreText.framework
      - framework: IOSurface.framework

  PairAppUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - Tests/PairAppUITests
    dependencies:
      - target: PairApp
    settings:
      base:
        TEST_TARGET_NAME: PairApp
XCODEGEN

    xcodegen generate
    echo "Done: PairApp.xcodeproj"
else
    echo "xcodegen not found. Installing..."
    brew install xcodegen 2>&1 | tail -3
    echo "Re-run this script."
    exit 1
fi
