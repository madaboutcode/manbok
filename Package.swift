// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "manbok",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "manbok", targets: ["manbok"]),
        .executable(name: "ManbokApp", targets: ["ManbokApp"]),
        .library(name: "ManbokCore", targets: ["ManbokCore"]),
        .library(name: "ManbokPlatform", targets: ["ManbokPlatform"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "ManbokCore", exclude: ["CLAUDE.md"]),
        .target(
            name: "ManbokPlatform",
            dependencies: ["ManbokCore"],
            exclude: ["CLAUDE.md"]
        ),
        .executableTarget(
            name: "manbok",
            dependencies: [
                "ManbokCore",
                "ManbokPlatform",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            exclude: ["CLAUDE.md", "Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/manbok/Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "ManbokApp",
            dependencies: [
                "ManbokCore",
                "ManbokPlatform",
            ],
            exclude: ["CLAUDE.md"]
        ),
        .testTarget(
            name: "ManbokCoreTests",
            dependencies: ["ManbokCore"]
        ),
        .testTarget(
            name: "ManbokPlatformTests",
            dependencies: ["ManbokPlatform"]
        ),
    ]
)