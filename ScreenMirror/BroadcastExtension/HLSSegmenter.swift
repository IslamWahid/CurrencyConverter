import AVFoundation
import UniformTypeIdentifiers

/// Holds the most recent fMP4 segments and renders the live HLS playlist that TVs play.
final class HLSPlaylistStore {
    private struct Segment {
        let sequence: Int
        let duration: Double
        let data: Data
    }

    private let lock = NSLock()
    private let maxSegments: Int
    private var initialization: Data?
    private var segments: [Segment] = []
    private var nextSequence = 0

    init(maxSegments: Int = 6) {
        self.maxSegments = maxSegments
    }

    func setInitialization(_ data: Data) {
        lock.withLock { initialization = data }
    }

    /// Returns the number of segments produced so far.
    @discardableResult
    func append(_ data: Data, duration: Double) -> Int {
        lock.withLock {
            segments.append(Segment(sequence: nextSequence, duration: duration, data: data))
            nextSequence += 1
            if segments.count > maxSegments { segments.removeFirst() }
            return nextSequence
        }
    }

    func initializationData() -> Data? {
        lock.withLock { initialization }
    }

    func segment(sequence: Int) -> Data? {
        lock.withLock { segments.first { $0.sequence == sequence }?.data }
    }

    func playlist() -> String {
        lock.withLock {
            let target = Int((segments.map(\.duration).max() ?? 1).rounded(.up))
            var lines = [
                "#EXTM3U",
                "#EXT-X-VERSION:6",
                "#EXT-X-TARGETDURATION:\(max(1, target))",
                "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.sequence ?? 0)",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-MAP:URI=\"init.mp4\"",
            ]
            for segment in segments {
                lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
                lines.append("seg\(segment.sequence).m4s")
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
}

/// Encodes frames to H.264 and cuts them into ~1 s fragmented-MP4 HLS segments in memory.
final class HLSSegmenter: NSObject, AVAssetWriterDelegate {
    var onSegment: ((Int) -> Void)?

    private let store: HLSPlaylistStore
    private let width: Int
    private let height: Int
    private let bitrate: Int
    private let frameRate: Int

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastTime = CMTime.invalid
    private var failed = false

    init(store: HLSPlaylistStore, width: Int, height: Int, bitrate: Int, frameRate: Int) {
        self.store = store
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.frameRate = frameRate
    }

    /// Not thread-safe: call from a single serial queue.
    func append(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        if writer == nil && !failed { startWriter(at: time) }
        guard let writer, writer.status == .writing,
              let input, input.isReadyForMoreMediaData,
              let adaptor else { return }
        if lastTime.isValid && time <= lastTime { return }
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            lastTime = time
        } else if let error = writer.error {
            NSLog("HLSSegmenter append failed: \(error)")
        }
    }

    func finish() {
        guard let writer, writer.status == .writing else { return }
        input?.markAsFinished()
        writer.finishWriting {}
    }

    private func startWriter(at time: CMTime) {
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = time
        writer.delegate = self

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        guard writer.canAdd(input) else {
            failed = true
            return
        }
        writer.add(input)
        guard writer.startWriting() else {
            NSLog("HLSSegmenter could not start: \(String(describing: writer.error))")
            failed = true
            return
        }
        writer.startSession(atSourceTime: time)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            store.setInitialization(segmentData)
        case .separable:
            let reported = segmentReport?.trackReports.first?.duration.seconds ?? 1
            let duration = reported.isFinite && reported > 0 ? reported : 1
            onSegment?(store.append(segmentData, duration: duration))
        @unknown default:
            break
        }
    }
}
