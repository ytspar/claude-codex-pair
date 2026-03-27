// swift-tools-version: 5.9
import PackageDescription

let ghosttyFrameworkPath = "Frameworks/GhosttyKit.xcframework/macos-arm64_x86_64"

let package = Package(
    name: "PairApp",
    platforms: [.macOS(.v14)],
    targets: [
        .testTarget(
            name: "PairAppTests",
            path: "Tests/PairAppTests"
        ),
        .executableTarget(
            name: "PairApp",
            path: "Sources/PairApp",
            resources: [
                .copy("Resources"),
            ],
            swiftSettings: [
                .unsafeFlags(["-I", ghosttyFrameworkPath + "/Headers"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L", ghosttyFrameworkPath]),
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
        ),
    ]
)
