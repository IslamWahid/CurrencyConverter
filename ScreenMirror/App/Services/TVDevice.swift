import Foundation

/// A DLNA/UPnP media renderer on the local network (most Samsung, LG, Sony, Philips,
/// Panasonic, Hisense and TCL smart TVs, plus many Android TV boxes and Xbox).
struct TVDevice: Identifiable, Hashable, Codable {
    struct Service: Hashable, Codable {
        let serviceType: String
        let controlURL: URL
    }

    let id: String
    let name: String
    let manufacturer: String
    let model: String
    let location: URL
    let avTransport: Service
    let renderingControl: Service?

    var host: String { location.host ?? "" }

    var subtitle: String {
        [manufacturer, model].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

enum DeviceDescriptionLoader {
    enum LoadError: Error {
        case notARenderer
    }

    /// Downloads a UPnP device description and turns it into a `TVDevice` if it can play media.
    static func load(from location: URL) async throws -> TVDevice {
        var request = URLRequest(url: location, timeoutInterval: 4)
        request.setValue("ScreenMirror/1.0 UPnP/1.1", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)

        let parser = DeviceDescriptionParser()
        let xml = XMLParser(data: data)
        xml.shouldProcessNamespaces = true
        xml.delegate = parser
        xml.parse()

        let base = parser.urlBase.flatMap(URL.init(string:)) ?? location
        func service(containing name: String) -> TVDevice.Service? {
            guard let match = parser.services.first(where: { $0.type.contains(name) }),
                  let url = URL(string: match.controlURL, relativeTo: base)?.absoluteURL else { return nil }
            return TVDevice.Service(serviceType: match.type, controlURL: url)
        }

        guard let avTransport = service(containing: ":AVTransport:") else { throw LoadError.notARenderer }
        return TVDevice(
            id: parser.udn ?? location.absoluteString,
            name: parser.friendlyName ?? location.host ?? "TV",
            manufacturer: parser.manufacturer ?? "",
            model: parser.modelName ?? "",
            location: location,
            avTransport: avTransport,
            renderingControl: service(containing: ":RenderingControl:")
        )
    }
}

private final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
    var udn: String?
    var urlBase: String?
    var services: [(type: String, controlURL: String)] = []

    private var text = ""
    private var serviceType: String?
    private var controlURL: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        if elementName == "service" {
            serviceType = nil
            controlURL = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        // The first device in the description is the root device; keep its identity.
        switch elementName {
        case "friendlyName" where friendlyName == nil: friendlyName = value
        case "manufacturer" where manufacturer == nil: manufacturer = value
        case "modelName" where modelName == nil: modelName = value
        case "UDN" where udn == nil: udn = value
        case "URLBase": urlBase = value
        case "serviceType": serviceType = value
        case "controlURL": controlURL = value
        case "service":
            if let serviceType, let controlURL {
                services.append((serviceType, controlURL))
            }
        default: break
        }
    }
}
