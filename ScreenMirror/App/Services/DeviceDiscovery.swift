import Foundation

/// Finds TVs with SSDP (the UPnP discovery protocol).
@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published private(set) var devices: [TVDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil
        defer { isScanning = false }

        let locations: [URL]
        do {
            locations = try await SSDPClient.search(timeout: 4)
        } catch {
            errorMessage = "Couldn't search your network. Make sure Wi-Fi is on and Screen Mirror is allowed "
                + "Local Network access in Settings › Privacy & Security."
            return
        }

        await withTaskGroup(of: TVDevice?.self) { group in
            for location in locations {
                group.addTask { try? await DeviceDescriptionLoader.load(from: location) }
            }
            for await device in group {
                guard let device else { continue }
                if let index = devices.firstIndex(where: { $0.id == device.id }) {
                    devices[index] = device
                } else {
                    devices.append(device)
                }
            }
        }
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum SSDPClient {
    enum SSDPError: Error {
        case socket(Int32)
        case send(Int32)
    }

    private static let searchTargets = [
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:schemas-upnp-org:service:AVTransport:1",
    ]

    /// Multicasts M-SEARCH requests and collects the description URLs of devices that answer.
    /// Sending multicast on iOS requires the com.apple.developer.networking.multicast entitlement.
    static func search(timeout: TimeInterval) async throws -> [URL] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try searchBlocking(timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func searchBlocking(timeout: TimeInterval) throws -> [URL] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SSDPError.socket(errno) }
        defer { close(fd) }

        var ttl: UInt8 = 4
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))
        var receiveTimeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(1900).bigEndian
        address.sin_addr.s_addr = inet_addr("239.255.255.250")

        // UDP is lossy: send each search twice.
        for round in 0..<2 {
            for target in searchTargets {
                let message = Array(searchMessage(target: target).utf8)
                let sent = withUnsafePointer(to: address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, message, message.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if sent < 0 { throw SSDPError.send(errno) }
            }
            if round == 0 { usleep(150_000) }
        }

        var seen = Set<URL>()
        var locations: [URL] = []
        var buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0,
                  let response = String(bytes: buffer[0..<count], encoding: .utf8),
                  let location = parseLocation(response) else { continue }
            if seen.insert(location).inserted {
                locations.append(location)
            }
        }
        return locations
    }

    private static func searchMessage(target: String) -> String {
        "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\n"
            + "ST: \(target)\r\n"
            + "USER-AGENT: iOS UPnP/1.1 ScreenMirror/1.0\r\n\r\n"
    }

    private static func parseLocation(_ response: String) -> URL? {
        for line in response.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "location" else { continue }
            return URL(string: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
