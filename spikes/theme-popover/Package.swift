// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThemePopoverSpike",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Local path dependency on the main package — reuse ManbokCore's pure-Foundation
        // domain types (SessionRegistry.SessionSnapshot, AudioFormat) so mock data and
        // formatting logic stay in sync with production instead of drifting again.
        .package(name: "manbok", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "ThemePopoverSpike",
            dependencies: [
                .product(name: "ManbokCore", package: "manbok")
            ],
            path: "Sources/ThemePopoverSpike"
        )
    ]
)
