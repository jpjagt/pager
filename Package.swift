// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pager",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PagerCore", path: "Sources/PagerCore"),
        .executableTarget(name: "Pager", dependencies: ["PagerCore"], path: "Sources/Pager"),
        .testTarget(name: "PagerCoreTests", dependencies: ["PagerCore"], path: "Tests/PagerCoreTests"),
    ]
)
