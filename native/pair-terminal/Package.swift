// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "pair-terminal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "pair-terminal", targets: ["PairTerminal"]),
    ],
    targets: [
        .executableTarget(
            name: "PairTerminal",
            dependencies: ["Bridge"],
            path: "Sources/PairTerminal"
        ),
        // Bridge module: wraps the unix socket IPC server
        .target(
            name: "Bridge",
            path: "Sources/Bridge"
        ),
    ]
)
