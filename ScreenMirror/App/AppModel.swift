import SwiftUI

enum MirrorTarget: String, CaseIterable, Identifiable {
    case tv
    case browser

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tv: return "Smart TV"
        case .browser: return "Web Browser"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    struct Banner: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isError: Bool
    }

    @Published var selectedDevice: TVDevice? {
        didSet { saveSelectedDevice() }
    }
    @Published var mirrorTarget: MirrorTarget = .tv
    @Published private(set) var isMirroring = false
    @Published var banner: Banner?

    let discovery = DeviceDiscovery()
    let mediaServer = MediaServer()

    private var observers: [DarwinObserver] = []
    private var isMirroringToTV = false
    private static let selectedDeviceKey = "selectedDevice"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.selectedDeviceKey) {
            selectedDevice = try? JSONDecoder().decode(TVDevice.self, from: data)
        }
        isMirroring = MirrorState.isActive
        MediaStore.clear()
        mediaServer.startIfNeeded()
        observeBroadcast()
    }

    var browserMirrorAddress: String? {
        NetworkInfo.localIPv4().map { "http://\($0):\(SharedConfig.mirrorPort)" }
    }

    func didBecomeActive() {
        mediaServer.startIfNeeded()
        isMirroring = MirrorState.isActive
        // The "ready" signal may have arrived while the app was suspended.
        if MirrorState.isReady && mirrorTarget == .tv && !isMirroringToTV && selectedDevice != nil {
            sendMirrorToTV()
        }
    }

    // MARK: - Screen mirroring

    func sendMirrorToTV() {
        guard let device = requireDevice() else { return }
        guard let ip = NetworkInfo.localIPv4(),
              let url = URL(string: "http://\(ip):\(SharedConfig.mirrorPort)/live.m3u8") else {
            return showError("Connect your iPhone to the same Wi-Fi network as your TV.")
        }
        isMirroringToTV = true
        Task {
            do {
                try await DLNAController(device: device).load(
                    url: url, mimeType: "application/vnd.apple.mpegurl", title: "Screen Mirroring", kind: .video)
                show("Mirroring to \(device.name)")
            } catch {
                isMirroringToTV = false
                showError(error.localizedDescription)
            }
        }
    }

    func stopMirroring() {
        DarwinNotifier.post(SharedConfig.Notifications.stopRequested)
    }

    private func observeBroadcast() {
        observers = [
            DarwinObserver(name: SharedConfig.Notifications.broadcastStarted) { [weak self] in
                Task { @MainActor in self?.isMirroring = true }
            },
            DarwinObserver(name: SharedConfig.Notifications.streamReady) { [weak self] in
                Task { @MainActor in self?.mirrorStreamReady() }
            },
            DarwinObserver(name: SharedConfig.Notifications.broadcastFinished) { [weak self] in
                Task { @MainActor in self?.mirrorDidFinish() }
            },
        ]
    }

    private func mirrorStreamReady() {
        isMirroring = true
        if mirrorTarget == .tv && selectedDevice != nil {
            sendMirrorToTV()
        }
    }

    private func mirrorDidFinish() {
        isMirroring = false
        guard isMirroringToTV, let device = selectedDevice else { return }
        isMirroringToTV = false
        Task { try? await DLNAController(device: device).stop() }
    }

    // MARK: - Media casting

    func cast(file: URL, mimeType: String, kind: DLNAController.MediaKind, title: String) async {
        guard requireDevice() != nil else { return }
        guard let url = mediaServer.publish(file, mimeType: mimeType) else {
            return showError("Connect your iPhone to the same Wi-Fi network as your TV.")
        }
        await cast(url: url, mimeType: mimeType, kind: kind, title: title)
    }

    func cast(remoteURL: URL) async {
        let type = MediaPreparer.mediaType(for: remoteURL)
        await cast(url: remoteURL, mimeType: type.mimeType, kind: type.kind, title: remoteURL.lastPathComponent)
    }

    private func cast(url: URL, mimeType: String, kind: DLNAController.MediaKind, title: String) async {
        guard let device = requireDevice() else { return }
        do {
            try await DLNAController(device: device).load(url: url, mimeType: mimeType, title: title, kind: kind)
            show("Playing on \(device.name)")
        } catch {
            showError(error.localizedDescription)
        }
    }

    func play() { control { try await $0.play() } }
    func pause() { control { try await $0.pause() } }
    func stopPlayback() { control { try await $0.stop() } }
    func setVolume(_ volume: Int) { control { try await $0.setVolume(volume) } }

    private func control(_ action: @escaping (DLNAController) async throws -> Void) {
        guard let device = requireDevice() else { return }
        Task {
            do {
                try await action(DLNAController(device: device))
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func requireDevice() -> TVDevice? {
        if selectedDevice == nil { showError("Connect to a TV first.") }
        return selectedDevice
    }

    func show(_ message: String) {
        banner = Banner(message: message, isError: false)
    }

    func showError(_ message: String) {
        banner = Banner(message: message, isError: true)
    }

    private func saveSelectedDevice() {
        if let selectedDevice, let data = try? JSONEncoder().encode(selectedDevice) {
            UserDefaults.standard.set(data, forKey: Self.selectedDeviceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectedDeviceKey)
        }
    }
}
