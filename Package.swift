// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pager",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "decode-log", targets: ["DecodeLog"]),
    ],
    targets: [
        .target(name: "PagerCore", path: "Sources/PagerCore"),
        .executableTarget(name: "Pager", dependencies: ["PagerCore"], path: "Sources/Pager"),
        .executableTarget(name: "DecodeLog", dependencies: ["PagerCore"], path: "Sources/DecodeLog"),
        .testTarget(name: "PagerCoreTests", dependencies: ["PagerCore"], path: "Tests/PagerCoreTests"),
    ]
)
