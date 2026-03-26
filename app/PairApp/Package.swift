// swift-tools-version: 5.9
import PackageDescription
import Foundation

// ---------------------------------------------------------------------------
// Conditionally link GhosttyKit when the xcframework is present.
// Set USE_GHOSTTY=1 in environment or simply have the xcframework in place.
// ---------------------------------------------------------------------------
let ghosttyFrameworkPath = "Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64"
let ghosttyHeaderPath = ghosttyFrameworkPath + "/Headers"
let ghosttyLibPath = ghosttyFrameworkPath

// Check whether the static library actually exists on disk so the package
// still resolves when the xcframework is absent.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ghosttyLibExists = FileManager.default.fileExists(
    atPath: repoRoot + "/" + ghosttyLibPath + "/libghostty.a"
)

// Allow explicit opt-in / opt-out via environment variable.
let envFlag = ProcessInfo.processInfo.environment["USE_GHOSTTY"]
let useGhostty: Bool = {
    if let flag = envFlag {
        return flag == "1" || flag.lowercased() == "true"
    }
    return ghosttyLibExists
}()

// Build Swift settings and linker settings only when GhosttyKit is available.
var swiftSettings: [SwiftSetting] = []
var linkerSettings: [LinkerSetting] = []

if useGhostty {
    swiftSettings += [
        .define("USE_GHOSTTY"),
        .unsafeFlags(["-I", ghosttyHeaderPath]),
    ]
    linkerSettings += [
        .unsafeFlags(["-L", ghosttyLibPath]),
        .linkedLibrary("ghostty"),
        .linkedLibrary("z"),
        .linkedLibrary("c++"),
        .linkedFramework("Carbon"),
        .linkedFramework("Metal"),
        .linkedFramework("MetalKit"),
        .linkedFramework("CoreGraphics"),
        .linkedFramework("QuartzCore"),
        .linkedFramework("CoreText"),
        .linkedFramework("IOSurface"),
        .linkedFramework("Foundation"),
        .linkedFramework("AppKit"),
    ]
}

let package = Package(
    name: "PairApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // SwiftTerm: pure-Swift terminal emulator (fallback when GhosttyKit is unavailable)
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "PairApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/PairApp",
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: linkerSettings
        ),
    ]
)
