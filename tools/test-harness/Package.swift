// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "test-harness",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "test-mic-harness", targets: ["TestMicHarness"]),
    ],
    targets: [
        .executableTarget(name: "TestMicHarness", dependencies: []),
    ]
)
