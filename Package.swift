// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "upil-appa",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "upil-appa", targets: ["upil-appa"]),
        .library(name: "UpilAppaCore", targets: ["UpilAppaCore"]),
        .library(name: "UpilAppaPlatform", targets: ["UpilAppaPlatform"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "UpilAppaCore"),
        .target(
            name: "UpilAppaPlatform",
            dependencies: ["UpilAppaCore"]
        ),
        .executableTarget(
            name: "upil-appa",
            dependencies: [
                "UpilAppaCore",
                "UpilAppaPlatform",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "UpilAppaCoreTests",
            dependencies: ["UpilAppaCore"]
        ),
        .testTarget(
            name: "UpilAppaPlatformTests",
            dependencies: ["UpilAppaPlatform"]
        ),
    ]
)