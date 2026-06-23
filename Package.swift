// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "decode-log", targets: ["DecodeLog"]),
        .executable(name: "e2e", targets: ["E2E"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "PagerCore", path: "Sources/PagerCore"),
        .executableTarget(
            name: "Pager",
            dependencies: ["PagerCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Pager"),
        .executableTarget(name: "DecodeLog", dependencies: ["PagerCore"], path: "Sources/DecodeLog"),
        .executableTarget(name: "E2E", dependencies: ["PagerCore"], path: "Sources/E2E"),
        .testTarget(name: "PagerCoreTests", dependencies: ["PagerCore"], path: "Tests/PagerCoreTests"),
    ]
)
