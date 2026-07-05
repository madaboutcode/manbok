// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThemePopoverSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ThemePopoverSpike", path: "Sources/ThemePopoverSpike")
    ]
)
