import SwiftUI

/// Shows which TV is connected, with a button to choose one.
struct DeviceStatusBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: model.selectedDevice == nil ? "tv.slash" : "tv.fill")
                    .font(.title3)
                    .foregroundStyle(model.selectedDevice == nil ? Color.secondary : Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedDevice?.name ?? "No TV connected")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(model.selectedDevice?.subtitle.nilIfEmpty ?? "Tap to find your TV")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.selectedDevice == nil ? "Connect" : "Change")
                    .font(.subheadline.bold())
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPicker) {
            DevicePickerView(discovery: model.discovery)
                .environmentObject(model)
        }
    }
}

struct DevicePickerView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var discovery: DeviceDiscovery
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(discovery.devices) { device in
                        Button {
                            model.selectedDevice = device
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "tv")
                                    .font(.title3)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).foregroundStyle(.primary)
                                    Text(device.subtitle.nilIfEmpty ?? device.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.id == model.selectedDevice?.id {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }

                    if discovery.isScanning {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for TVs…").foregroundStyle(.secondary)
                        }
                    } else if discovery.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No TVs found").font(.headline)
                            Text(discovery.errorMessage
                                 ?? "Make sure your TV is on and connected to the same Wi-Fi network as this iPhone.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("TVs on your Wi-Fi")
                } footer: {
                    Text("Works with smart TVs that support DLNA / UPnP — most Samsung, LG, Sony, Philips, "
                         + "Panasonic, Hisense and TCL models, plus many TV boxes and game consoles.")
                }

                if model.selectedDevice != nil {
                    Section {
                        Button("Disconnect", role: .destructive) {
                            model.selectedDevice = nil
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Connect to TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await discovery.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(discovery.isScanning)
                }
            }
            .task { await discovery.scan() }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
