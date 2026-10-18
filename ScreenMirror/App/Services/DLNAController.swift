import Foundation

/// Remote-controls a TV over UPnP AVTransport / RenderingControl (SOAP).
struct DLNAController {
    enum MediaKind {
        case video, image, audio

        var upnpClass: String {
            switch self {
            case .video: return "object.item.videoItem"
            case .image: return "object.item.imageItem.photo"
            case .audio: return "object.item.audioItem.musicTrack"
            }
        }
    }

    enum DLNAError: LocalizedError {
        case noVolumeControl
        case badResponse
        case actionFailed(action: String, status: Int, detail: String?)

        var errorDescription: String? {
            switch self {
            case .noVolumeControl:
                return "This TV doesn't allow volume control from the phone."
            case .badResponse:
                return "The TV sent an unexpected response."
            case let .actionFailed(action, status, detail):
                let reason = detail.map { " (\($0))" } ?? ""
                return "The TV rejected \(action): error \(status)\(reason)."
            }
        }
    }

    let device: TVDevice

    /// Tells the TV to fetch `url` and start playing it.
    func load(url: URL, mimeType: String, title: String, kind: MediaKind) async throws {
        // Many TVs refuse a new URI while something is already playing.
        try? await stop()
        let metadata = Self.didl(url: url, mimeType: mimeType, title: title, kind: kind)
        try await invoke(device.avTransport, "SetAVTransportURI", [
            ("InstanceID", "0"),
            ("CurrentURI", url.absoluteString),
            ("CurrentURIMetaData", metadata),
        ])
        try await play()
    }

    func play() async throws {
        try await invoke(device.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
    }

    func pause() async throws {
        try await invoke(device.avTransport, "Pause", [("InstanceID", "0")])
    }

    func stop() async throws {
        try await invoke(device.avTransport, "Stop", [("InstanceID", "0")])
    }

    func setVolume(_ volume: Int) async throws {
        guard let service = device.renderingControl else { throw DLNAError.noVolumeControl }
        try await invoke(service, "SetVolume", [
            ("InstanceID", "0"),
            ("Channel", "Master"),
            ("DesiredVolume", "\(max(0, min(100, volume)))"),
        ])
    }

    // MARK: - SOAP

    private func invoke(_ service: TVDevice.Service, _ action: String, _ arguments: [(String, String)]) async throws {
        let body = arguments.map { "<\($0.0)>\(Self.escape($0.1))</\($0.0)>" }.joined()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\
        <u:\(action) xmlns:u="\(service.serviceType)">\(body)</u:\(action)>\
        </s:Body></s:Envelope>
        """

        var request = URLRequest(url: service.controlURL, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(service.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(envelope.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DLNAError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw DLNAError.actionFailed(action: action, status: http.statusCode,
                                         detail: Self.faultDescription(in: data))
        }
    }

    private static func didl(url: URL, mimeType: String, title: String, kind: MediaKind) -> String {
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" "
            + "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" "
            + "xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"0\" parentID=\"-1\" restricted=\"1\">"
            + "<dc:title>\(escape(title))</dc:title>"
            + "<upnp:class>\(kind.upnpClass)</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mimeType):*\">\(escape(url.absoluteString))</res>"
            + "</item></DIDL-Lite>"
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func faultDescription(in data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8),
              let start = xml.range(of: "<errorDescription>"),
              let end = xml.range(of: "</errorDescription>", range: start.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}
