import ReplayKit
import SwiftUI

struct MirrorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var picker = BroadcastPicker()
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Picker("Mirror to", selection: $model.mirrorTarget) {
                    ForEach(MirrorTarget.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                if model.mirrorTarget == .tv {
                    DeviceStatusBar()
                } else {
                    browserCard
                }

                mirrorButton

                if model.isMirroring && model.mirrorTarget == .tv && model.selectedDevice != nil {
                    Button {
                        model.sendMirrorToTV()
                    } label: {
                        Label("Send to TV again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                steps
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Screen Mirroring")
        .navigationBarTitleDisplayMode(.inline)
        .background(BroadcastPickerHost(picker: picker.view).frame(width: 1, height: 1).opacity(0.01))
    }

    private var mirrorButton: some View {
        Button {
            if model.isMirroring {
                model.stopMirroring()
            } else if model.mirrorTarget == .tv && model.selectedDevice == nil {
                model.showError("Connect to a TV first, or mirror to a web browser.")
            } else {
                picker.show()
            }
        } label: {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(model.isMirroring
                              ? LinearGradient(colors: [.red, .orange], startPoint: .top, endPoint: .bottom)
                              : LinearGradient(colors: [.blue, .indigo], startPoint: .top, endPoint: .bottom))
                        .frame(width: 168, height: 168)
                        .shadow(color: (model.isMirroring ? Color.red : Color.blue).opacity(0.35), radius: 18, y: 8)
                    Image(systemName: model.isMirroring ? "stop.fill" : "rectangle.on.rectangle")
                        .font(.system(size: 56, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text(model.isMirroring ? "Stop Mirroring" : "Start Mirroring")
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)
    }

    private var browserCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Open this address in any browser", systemImage: "globe")
                .font(.headline)
            Text("Works on smart TV browsers, computers and tablets on the same Wi-Fi.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let address = model.browserMirrorAddress {
                HStack {
                    Text(address)
                        .font(.system(.title3, design: .monospaced).bold())
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = address
                        copied = true
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("Connect to Wi-Fi to get an address.")
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works").font(.headline)
            step(1, "Connect your iPhone and TV to the same Wi-Fi.")
            if model.mirrorTarget == .tv {
                step(2, "Choose your TV above.")
                step(3, "Tap Start Mirroring, then Start Broadcast.")
                step(4, "Your TV starts showing your screen after a few seconds.")
            } else {
                step(2, "Tap Start Mirroring, then Start Broadcast.")
                step(3, "Open the address above in the browser on your TV or computer.")
            }
            Text("Smart TVs play the stream with a few seconds of delay. The browser option is closer to real time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}

/// Owns the system broadcast picker, which is the only way to start a screen broadcast.
/// It is kept invisible; `show()` taps its button on behalf of our own UI.
@MainActor
final class BroadcastPicker: ObservableObject {
    let view: RPSystemBroadcastPickerView = {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        if let appID = Bundle.main.bundleIdentifier {
            picker.preferredExtension = appID + ".Broadcast"
        }
        picker.showsMicrophoneButton = false
        return picker
    }()

    func show() {
        for case let button as UIButton in view.subviews {
            button.sendActions(for: .touchUpInside)
        }
    }
}

private struct BroadcastPickerHost: UIViewRepresentable {
    let picker: RPSystemBroadcastPickerView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.addSubview(picker)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
