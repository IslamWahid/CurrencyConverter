import AVFoundation
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

/// Temporary files the app serves to the TV.
enum MediaStore {
    static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CastMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func makeFileURL(ext: String) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// A video picked from the photo library, copied into `MediaStore`.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let destination = MediaStore.makeFileURL(ext: ext)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return MovieFile(url: destination)
        }
    }
}

struct PreparedPhoto: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: UIImage
}

struct PreparedVideo {
    let url: URL
    let mimeType: String
    let thumbnail: UIImage?
}

enum MediaPreparer {
    enum PrepareError: LocalizedError {
        case unreadableImage

        var errorDescription: String? { "That photo couldn't be read." }
    }

    /// Re-encodes a photo as an upright JPEG no larger than 1080p — what TVs reliably show.
    static func preparePhoto(_ data: Data) throws -> PreparedPhoto {
        guard let image = UIImage(data: data),
              let jpeg = image.resized(maxDimension: 1920).jpegData(compressionQuality: 0.9) else {
            throw PrepareError.unreadableImage
        }
        let url = MediaStore.makeFileURL(ext: "jpg")
        try jpeg.write(to: url)
        return PreparedPhoto(url: url, thumbnail: image.resized(maxDimension: 800))
    }

    /// Converts a library video (often HEVC .mov) to H.264 .mp4, which nearly every TV plays.
    static func prepareVideo(_ source: URL) async -> PreparedVideo {
        let asset = AVURLAsset(url: source)
        let thumbnail = await thumbnail(for: asset)

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            return PreparedVideo(url: source, mimeType: mimeType(for: source), thumbnail: thumbnail)
        }
        let output = MediaStore.makeFileURL(ext: "mp4")
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }

        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            return PreparedVideo(url: source, mimeType: mimeType(for: source), thumbnail: thumbnail)
        }
        try? FileManager.default.removeItem(at: source)
        return PreparedVideo(url: output, mimeType: "video/mp4", thumbnail: thumbnail)
    }

    private static func thumbnail(for asset: AVAsset) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image)
    }

    /// Best-effort MIME type and media kind from a file extension.
    static func mediaType(for url: URL) -> (mimeType: String, kind: DLNAController.MediaKind) {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return ("image/jpeg", .image)
        case "png": return ("image/png", .image)
        case "gif": return ("image/gif", .image)
        case "mp3": return ("audio/mpeg", .audio)
        case "m4a", "aac": return ("audio/mp4", .audio)
        case "m3u8": return ("application/vnd.apple.mpegurl", .video)
        default: return (mimeType(for: url), .video)
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "avi": return "video/x-msvideo"
        default: return "video/mp4"
        }
    }
}

extension UIImage {
    /// Draws the image upright, scaled down to fit `maxDimension`.
    func resized(maxDimension: CGFloat) -> UIImage {
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
