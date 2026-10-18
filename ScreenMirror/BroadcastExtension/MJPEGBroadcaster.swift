import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Streams the screen as Motion-JPEG to web browsers. Low latency, works in any browser.
/// Only encodes while at least one browser is watching.
final class MJPEGBroadcaster {
    static let boundary = "mirrorframe"

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "mjpeg.encoder")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let minimumInterval: TimeInterval
    private let quality: Double
    private var clients: [ObjectIdentifier: HTTPStreamWriter] = [:]
    private var isEncoding = false
    private var lastFrameTime: TimeInterval = 0

    init(framesPerSecond: Double = 15, quality: Double) {
        minimumInterval = 1 / framesPerSecond
        self.quality = quality
    }

    func add(_ client: HTTPStreamWriter) {
        lock.withLock { clients[ObjectIdentifier(client)] = client }
    }

    func offer(_ pixelBuffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldEncode = lock.withLock { () -> Bool in
            clients = clients.filter { !$0.value.isClosed }
            guard !clients.isEmpty, !isEncoding, now - lastFrameTime >= minimumInterval else { return false }
            isEncoding = true
            lastFrameTime = now
            return true
        }
        guard shouldEncode else { return }

        queue.async { [self] in
            defer { lock.withLock { isEncoding = false } }
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            let scale = min(1, 1280 / image.extent.width)
            if scale < 1 {
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
            guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options) else {
                return
            }
            var part = Data("--\(Self.boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
            part.append(jpeg)
            part.append(Data("\r\n".utf8))

            let targets = lock.withLock { Array(clients.values) }
            for client in targets where !client.isBusy {
                client.write(part)
            }
        }
    }

    func closeAll() {
        let targets = lock.withLock { () -> [HTTPStreamWriter] in
            defer { clients.removeAll() }
            return Array(clients.values)
        }
        targets.forEach { $0.close() }
    }
}
