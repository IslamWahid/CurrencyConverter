import Foundation

/// Values shared between the app and the broadcast upload extension.
enum SharedConfig {
    /// App Group used to exchange settings and state with the extension.
    /// Injected into both Info.plists from the `APP_GROUP_ID` build setting in project.yml.
    static let appGroupID: String =
        Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String
        ?? "group.com.yourcompany.screenmirror"

    /// Port the broadcast extension serves the live mirror stream on.
    static let mirrorPort: UInt16 = 8080
    /// Port the app serves photos and videos on while casting them.
    static let mediaPort: UInt16 = 8090

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    enum Notifications {
        static let broadcastStarted = "com.screenmirror.broadcast.started"
        static let streamReady = "com.screenmirror.broadcast.ready"
        static let broadcastFinished = "com.screenmirror.broadcast.finished"
        static let stopRequested = "com.screenmirror.broadcast.stopRequested"
    }
}

/// Mirroring quality, chosen in the app and read by the extension when a broadcast starts.
struct MirrorSettings: Codable, Equatable {
    enum Resolution: String, Codable, CaseIterable, Identifiable {
        case hd720
        case hd1080

        var id: String { rawValue }
        var title: String {
            switch self {
            case .hd720: return "720p (smoother)"
            case .hd1080: return "1080p (sharper)"
            }
        }
        var size: (width: Int, height: Int) {
            switch self {
            case .hd720: return (1280, 720)
            case .hd1080: return (1920, 1080)
            }
        }
    }

    var resolution: Resolution = .hd720
    var bitrateMbps: Int = 4
    var frameRate: Int = 30
    /// JPEG quality of the browser (MJPEG) stream, 0...1.
    var browserQuality: Double = 0.6

    private static let key = "mirrorSettings"

    static func load() -> MirrorSettings {
        guard let data = SharedConfig.defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(MirrorSettings.self, from: data) else {
            return MirrorSettings()
        }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            SharedConfig.defaults.set(data, forKey: Self.key)
        }
    }
}

/// Liveness of the broadcast extension, written by the extension and read by the app.
enum MirrorState {
    private static let heartbeatKey = "mirrorHeartbeat"
    private static let readyKey = "mirrorReady"

    /// True while the extension is running and has produced output recently.
    static var isActive: Bool {
        let last = SharedConfig.defaults.double(forKey: heartbeatKey)
        return last > 0 && Date().timeIntervalSince1970 - last < 6
    }

    /// True once the extension has enough video buffered for a TV to start playing.
    static var isReady: Bool {
        isActive && SharedConfig.defaults.bool(forKey: readyKey)
    }

    static func beat() {
        SharedConfig.defaults.set(Date().timeIntervalSince1970, forKey: heartbeatKey)
    }

    static func markReady() {
        SharedConfig.defaults.set(true, forKey: readyKey)
    }

    static func markStopped() {
        SharedConfig.defaults.removeObject(forKey: heartbeatKey)
        SharedConfig.defaults.set(false, forKey: readyKey)
    }
}
