import SwiftUI
import ManbokCore
import ManbokPlatform

struct SettingsView: View {
    let registry: SessionRegistry

    @EnvironmentObject private var settings: SettingsStore
    private let log = AppLog(category: .settings)

    @State private var selectedPreset: BufferPolicy.Preset = .default
    @State private var bufferErrorMessage: String?

    @State private var startAtLogin: Bool = false
    @State private var loginErrorMessage: String?

    private let presets = BufferPolicy.Preset.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            bufferSection
            Rectangle().fill(Theme.line).frame(height: 1)
            loginSection
        }
        .padding(20)
        // hiddenTitleBar floats the traffic lights over the content's top-left;
        // clear them so the BUFFER caption doesn't sit underneath.
        .padding(.top, 18)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(PanelBackgroundView().ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .windowThemed()
        .onAppear {
            selectedPreset = settings.bufferPreset
            startAtLogin = settings.startAtLogin
        }
    }

    private var bufferSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MicroLabel(text: "Buffer")

            Text("How far back?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.cream)

            PresetSlider(
                presets: presets,
                selected: $selectedPreset,
                sessionsLost: sessionsLost
            ) { preset in
                applyPreset(preset)
            }

            if let bufferErrorMessage {
                Text(bufferErrorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger)
            }

            Text("manbok records while another app is using your mic and keeps a rolling window in memory. This is how many minutes of that audio you can rewind.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.creamDim)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

            Text("Audio stays in RAM only. Nothing touches disk until you export.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.creamFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MicroLabel(text: "Startup")

            Toggle(isOn: $startAtLogin) {
                Text("Start at login")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.cream)
            }
            .toggleStyle(ThemedCheckboxToggleStyle())
            .onChange(of: startAtLogin) { _, newValue in
                applyStartAtLogin(newValue)
            }

            Text("Launch automatically so manbok is always ready.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.creamDim)

            if let loginErrorMessage {
                Text(loginErrorMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private func sessionsLost(for preset: BufferPolicy.Preset) -> Int {
        guard preset != settings.bufferPreset else { return 0 }
        let newCapacity = BufferPolicy.capacityBytes(for: preset)
        guard newCapacity < registry.capacityBytes else { return 0 }
        return registry.sessionsLost(ifResizedTo: preset)
    }

    private func applyPreset(_ newPreset: BufferPolicy.Preset) {
        guard newPreset != settings.bufferPreset else { return }
        let previous = settings.bufferPreset
        do {
            try registry.resize(to: newPreset)
            settings.bufferPreset = newPreset
            bufferErrorMessage = nil
            log.notice("buffer preset changed: \(previous.minutes)min → \(newPreset.minutes)min")
        } catch {
            selectedPreset = previous
            bufferErrorMessage = "Couldn't resize — kept \(previous.minutes) min."
            log.error("buffer resize failed: \(error)")
        }
    }

    private func applyStartAtLogin(_ newValue: Bool) {
        guard newValue != settings.startAtLogin else { return }
        do {
            if newValue {
                try LoginItemManager.register()
            } else {
                try LoginItemManager.unregister()
            }
            settings.startAtLogin = newValue
            loginErrorMessage = nil
            log.notice("login item \(newValue ? "registered" : "unregistered")")
        } catch {
            startAtLogin = settings.startAtLogin
            loginErrorMessage = "macOS declined — check System Settings → Login Items."
            log.error("login item \(newValue ? "register" : "unregister") failed: \(error)")
        }
    }
}

private struct PresetSlider: View {
    let presets: [BufferPolicy.Preset]
    @Binding var selected: BufferPolicy.Preset
    let sessionsLost: (BufferPolicy.Preset) -> Int
    let onSelect: (BufferPolicy.Preset) -> Void

    private var selectedIndex: Int {
        presets.firstIndex(of: selected) ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let count = presets.count
                let padding: CGFloat = 10
                let trackWidth = geo.size.width - padding * 2

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.bgWell)
                        .frame(height: 3)
                        .padding(.horizontal, padding)

                    Capsule()
                        .fill(Theme.tapeGreen.opacity(0.5))
                        .frame(width: xOffset(for: selectedIndex, trackWidth: trackWidth, count: count), height: 3)
                        .padding(.leading, padding)

                    ForEach(0..<count, id: \.self) { i in
                        let x = xOffset(for: i, trackWidth: trackWidth, count: count)
                        Circle()
                            .fill(i == selectedIndex ? Theme.amber : (i < selectedIndex ? Theme.tapeGreen : Theme.creamFaint.opacity(0.25)))
                            .frame(width: i == selectedIndex ? 14 : 8, height: i == selectedIndex ? 14 : 8)
                            .shadow(color: i == selectedIndex ? Theme.amberGlow : .clear, radius: i == selectedIndex ? 5 : 0)
                            .position(x: padding + x, y: geo.size.height / 2)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selected = presets[i]
                                }
                                onSelect(presets[i])
                            }
                    }
                }
            }
            .frame(height: 20)

            HStack {
                ForEach(0..<presets.count, id: \.self) { i in
                    if i > 0 { Spacer() }
                    Text("\(presets[i].minutes)")
                        .font(Theme.mono(9, weight: i == selectedIndex ? .semibold : .regular))
                        .foregroundStyle(i == selectedIndex ? Theme.cream : Theme.creamFaint)
                }
            }
            .padding(.horizontal, 10)

            selectedLabel
        }
    }

    private var selectedLabel: some View {
        let preset = selected
        let lost = sessionsLost(preset)
        return VStack(spacing: 2) {
            Text("\(preset.minutes) minutes — \(BufferPolicy.memoryCost(for: preset))")
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.cream)
            if lost > 0 {
                Text("Shrinking removes \(lost) session\(lost == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.amberHot)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func xOffset(for index: Int, trackWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return trackWidth * CGFloat(index) / CGFloat(count - 1)
    }
}

/// A 14pt rounded-square checkbox in the panel's amber/cream palette, replacing
/// the system checkbox whose accent color follows the OS tint (blue) rather
/// than the app's theme. Wrapping the box in a plain-style `Button` (instead
/// of a bare tap gesture) keeps keyboard activation and VoiceOver focus intact
/// on the underlying `Toggle` — only the visual chrome changes.
private struct ThemedCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(configuration.isOn ? Theme.amber : Theme.bgWell)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Theme.lineStrong, lineWidth: 1)
                    )
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.bgWell)
                        }
                    }
                    .frame(width: 14, height: 14)
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}
