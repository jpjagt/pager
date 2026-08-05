// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "decode-log", targets: ["DecodeLog"]),
        .executable(name: "e2e", targets: ["E2E"]),
        .executable(name: "design-preview", targets: ["DesignPreview"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "PagerCore", path: "Sources/PagerCore"),
        .target(name: "PagerUI", dependencies: ["PagerCore"], path: "Sources/PagerUI"),
        .executableTarget(
            name: "Pager",
            dependencies: ["PagerCore", "PagerUI", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Pager"),
        .executableTarget(name: "DecodeLog", dependencies: ["PagerCore"], path: "Sources/DecodeLog"),
        .executableTarget(name: "E2E", dependencies: ["PagerCore"], path: "Sources/E2E"),
        .executableTarget(name: "DesignPreview", dependencies: ["PagerUI"], path: "Sources/DesignPreview"),
        .testTarget(name: "PagerCoreTests", dependencies: ["PagerCore"], path: "Tests/PagerCoreTests"),
        .testTarget(name: "PagerUITests", dependencies: ["PagerUI"], path: "Tests/PagerUITests"),
    ]
)
