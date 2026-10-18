import Foundation

/// Serves photos and videos picked in the app so the TV can download them.
final class MediaServer {
    private let lock = NSLock()
    private var files: [String: (url: URL, mimeType: String)] = [:]
    private lazy var server = HTTPServer(port: SharedConfig.mediaPort, label: "media-server") { [weak self] request in
        self?.route(request) ?? .notFound
    }

    /// Starts the server, or restarts it if iOS tore the listener down while the app was suspended.
    func startIfNeeded() {
        guard !server.isListening else { return }
        do {
            try server.start()
        } catch {
            NSLog("MediaServer failed to start: \(error)")
        }
    }

    /// Makes `file` downloadable and returns the URL the TV should load.
    func publish(_ file: URL, mimeType: String) -> URL? {
        guard let ip = NetworkInfo.localIPv4() else { return nil }
        startIfNeeded()
        let ext = file.pathExtension.isEmpty ? "bin" : file.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        lock.withLock { files[name] = (file, mimeType) }
        return URL(string: "http://\(ip):\(SharedConfig.mediaPort)/media/\(name)")
    }

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        let parts = request.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "media",
              let entry = lock.withLock({ files[String(parts[1])] }) else { return .notFound }
        let isImage = entry.mimeType.hasPrefix("image/")
        return .file(entry.url, contentType: entry.mimeType, headers: [
            "transferMode.dlna.org": isImage ? "Interactive" : "Streaming",
            "contentFeatures.dlna.org": "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000",
        ])
    }
}
