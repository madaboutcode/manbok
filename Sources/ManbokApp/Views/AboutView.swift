import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)

            Image(systemName: "ear")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.secondary)

            Spacer().frame(height: 14)

            Text("manbok")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Text("v\(version)" + (build.isEmpty ? "" : " (\(build))"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer().frame(height: 16)

            Text("Always listening. Never missing a word.")
                .font(.system(size: 12, weight: .medium))
                .italic()
                .foregroundStyle(.secondary)

            Spacer().frame(height: 14)

            Text(storyText)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 260)

            Spacer().frame(height: 20)

            Divider().padding(.horizontal, 24)

            Spacer().frame(height: 12)

            Text("madaboutcode")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)

            Spacer().frame(height: 20)
        }
        .frame(width: 320)
        .fixedSize()
    }

    private var storyText: String {
        "Named after Jung Man-bok (정만복), the wiretapper " +
        "from Crash Landing on You — he never missed a word " +
        "and neither does this app.\n\n" +
        "manbok keeps a rolling buffer of your mic audio in RAM. " +
        "When your speech-to-text glitches, or you need to replay " +
        "what was just said — just rewind. " +
        "No cloud, no disk, no fuss."
    }
}
