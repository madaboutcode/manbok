// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ManbokSpikes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "capture-spike", targets: ["CaptureSpike"]),
        .executable(name: "wav-spike", targets: ["WavSpike"]),
        .executable(name: "ipc-spike", targets: ["IpcSpike"]),
        .executable(name: "ring-math-spike", targets: ["RingMathSpike"]),
        .executable(name: "device-spike", targets: ["DeviceSpike"]),
        .executable(name: "device-usage-spike", targets: ["DeviceUsageSpike"]),
        .executable(name: "device-capture-spike", targets: ["DeviceCaptureSpike"]),
        .executable(name: "speech-activity-spike", targets: ["SpeechActivitySpike"]),
        .executable(name: "mic-detect-spike", targets: ["MicDetectSpike"]),
        .executable(name: "device-switch-spike", targets: ["DeviceSwitchSpike"]),
        .executable(name: "pinned-capture-spike", targets: ["PinnedCaptureSpike"]),
        .executable(name: "vpio-contention-spike", targets: ["VpioContentionSpike"]),
        .executable(name: "tap-load-spike", targets: ["TapLoadSpike"]),
        .executable(name: "device-truth-spike", targets: ["DeviceTruthSpike"]),
        .executable(name: "silence-probe-spike", targets: ["SilenceProbeSpike"]),
    ],
    targets: [
        .executableTarget(name: "CaptureSpike", dependencies: []),
        .executableTarget(name: "WavSpike", dependencies: []),
        .executableTarget(name: "IpcSpike", dependencies: []),
        .executableTarget(name: "RingMathSpike", dependencies: []),
        .executableTarget(name: "DeviceSpike", dependencies: []),
        .executableTarget(name: "DeviceUsageSpike", dependencies: []),
        .executableTarget(name: "DeviceCaptureSpike", dependencies: []),
        .executableTarget(name: "SpeechActivitySpike", dependencies: []),
        .executableTarget(name: "MicDetectSpike", dependencies: []),
        .executableTarget(name: "DeviceSwitchSpike", dependencies: []),
        .executableTarget(name: "PinnedCaptureSpike", dependencies: []),
        .executableTarget(name: "VpioContentionSpike", dependencies: []),
        .executableTarget(name: "TapLoadSpike", dependencies: []),
        .executableTarget(name: "DeviceTruthSpike", dependencies: []),
        .executableTarget(name: "SilenceProbeSpike", dependencies: []),
    ]
)