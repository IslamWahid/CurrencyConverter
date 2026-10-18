import SwiftUI

struct SettingsView: View {
    @State private var settings = MirrorSettings.load()

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $settings.resolution) {
                    ForEach(MirrorSettings.Resolution.allCases) { Text($0.title).tag($0) }
                }
                Picker("Bitrate", selection: $settings.bitrateMbps) {
                    ForEach([2, 4, 6, 8], id: \.self) { Text("\($0) Mbps").tag($0) }
                }
                Picker("Frame rate", selection: $settings.frameRate) {
                    ForEach([24, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
            } header: {
                Text("TV mirroring quality")
            } footer: {
                Text("Lower settings work better on slow Wi-Fi. Changes apply the next time you start mirroring.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Image quality: \(Int(settings.browserQuality * 100))%")
                    Slider(value: $settings.browserQuality, in: 0.3...0.9, step: 0.1)
                }
            } header: {
                Text("Browser mirroring")
            }

            Section("About") {
                LabeledContent("Version",
                               value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            }
        }
        .navigationTitle("Settings")
        .onChange(of: settings) { $0.save() }
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("Getting started") {
                tip("wifi", "Same Wi-Fi", "Your iPhone and TV must be on the same Wi-Fi network. Guest networks often block devices from seeing each other.")
                tip("tv", "Turn on your TV's media sharing", "Some TVs need DLNA / \"Screen Share\" / \"Media Renderer\" enabled in their network settings.")
                tip("lock.shield", "Allow Local Network", "If no TVs appear, open Settings › Privacy & Security › Local Network and turn on Screen Mirror.")
            }
            Section("Troubleshooting") {
                tip("hourglass", "Delay on the TV", "TVs buffer a few seconds of video before playing. For lower delay, use Web Browser mode.")
                tip("speaker.slash", "No sound", "Screen mirroring sends the picture only. To play a video with sound, use Videos or Web Video.")
                tip("exclamationmark.triangle", "TV says the format isn't supported", "Try 720p in Settings, or use the Web Browser mode with your TV's web browser.")
                tip("arrow.triangle.2.circlepath", "Mirroring stopped", "iOS ends screen broadcasts during calls or when the phone gets too hot. Start it again from the app.")
            }
        }
        .navigationTitle("Help")
    }

    private func tip(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
