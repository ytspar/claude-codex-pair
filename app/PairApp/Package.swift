// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PairApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        // SwiftTerm: pure-Swift terminal emulator (swap for libghostty later)
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "PairApp",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/PairApp"
        ),
    ]
)
