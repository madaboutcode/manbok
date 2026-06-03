// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpilAppaSpikes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "capture-spike", targets: ["CaptureSpike"]),
        .executable(name: "wav-spike", targets: ["WavSpike"]),
        .executable(name: "ipc-spike", targets: ["IpcSpike"]),
        .executable(name: "ring-math-spike", targets: ["RingMathSpike"]),
        .executable(name: "device-spike", targets: ["DeviceSpike"]),
        .executable(name: "device-usage-spike", targets: ["DeviceUsageSpike"]),
        .executable(name: "device-capture-spike", targets: ["DeviceCaptureSpike"]),
    ],
    targets: [
        .executableTarget(name: "CaptureSpike", dependencies: []),
        .executableTarget(name: "WavSpike", dependencies: []),
        .executableTarget(name: "IpcSpike", dependencies: []),
        .executableTarget(name: "RingMathSpike", dependencies: []),
        .executableTarget(name: "DeviceSpike", dependencies: []),
        .executableTarget(name: "DeviceUsageSpike", dependencies: []),
        .executableTarget(name: "DeviceCaptureSpike", dependencies: []),
    ]
)