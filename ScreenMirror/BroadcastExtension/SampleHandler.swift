import CoreMedia
import ImageIO
import ReplayKit

/// The broadcast upload extension. iOS hands it every screen frame while mirroring is on;
/// it serves them on the local network as HLS (for smart TVs) and MJPEG (for web browsers).
final class SampleHandler: RPBroadcastSampleHandler {
    private let frameQueue = DispatchQueue(label: "broadcast.frames")
    private let store = HLSPlaylistStore()
    private var settings = MirrorSettings()
    private var processor: FrameProcessor?
    private var segmenter: HLSSegmenter?
    private var mjpeg: MJPEGBroadcaster?
    private var server: HTTPServer?
    private var repeatTimer: DispatchSourceTimer?
    private var stopObserver: DarwinObserver?

    private var lastFrame: CVPixelBuffer?
    private var lastPushTime: TimeInterval = 0
    private var announcedReady = false
    private var isTornDown = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        settings = MirrorSettings.load()
        let size = settings.resolution.size
        processor = FrameProcessor(width: size.width, height: size.height)
        mjpeg = MJPEGBroadcaster(quality: settings.browserQuality)

        let segmenter = HLSSegmenter(store: store, width: size.width, height: size.height,
                                     bitrate: settings.bitrateMbps * 1_000_000, frameRate: settings.frameRate)
        segmenter.onSegment = { [weak self] count in self?.segmentProduced(count: count) }
        self.segmenter = segmenter

        let server = HTTPServer(port: SharedConfig.mirrorPort, label: "mirror-server") { [weak self] request in
            self?.route(request) ?? .notFound
        }
        do {
            try server.start()
        } catch {
            finishBroadcastWithError(Self.error("Could not start the mirroring server: \(error.localizedDescription)"))
            return
        }
        self.server = server

        startRepeatTimer()
        stopObserver = DarwinObserver(name: SharedConfig.Notifications.stopRequested) { [weak self] in
            self?.stopRequestedByApp()
        }

        MirrorState.markStopped()
        MirrorState.beat()
        DarwinNotifier.post(SharedConfig.Notifications.broadcastStarted)
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientationValue = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                               attachmentModeOut: nil) as? NSNumber
        let orientation = orientationValue.flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up

        frameQueue.sync {
            guard let processor, let frame = processor.process(pixelBuffer, orientation: orientation) else { return }
            lastFrame = frame
            push(frame, force: false)
        }
    }

    override func broadcastFinished() {
        tearDown()
    }

    // MARK: - Frames

    /// Called on `frameQueue`.
    private func push(_ frame: CVPixelBuffer, force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let interval = 1 / Double(settings.frameRate)
        guard force || now - lastPushTime >= interval * 0.9 else { return }
        lastPushTime = now
        segmenter?.append(frame, at: CMClockGetTime(CMClockGetHostTimeClock()))
        mjpeg?.offer(frame)
    }

    /// iOS only sends frames when the screen changes. Repeat the last one so the
    /// encoder keeps producing segments and TVs don't stall on a still screen.
    private func startRepeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: frameQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, let frame = self.lastFrame,
                  ProcessInfo.processInfo.systemUptime - self.lastPushTime > 0.2 else { return }
            self.push(frame, force: true)
        }
        timer.resume()
        repeatTimer = timer
    }

    private func segmentProduced(count: Int) {
        MirrorState.beat()
        // A few seconds of buffered video lets the TV's player start without stalling.
        if count >= 3 && !announcedReady {
            announcedReady = true
            MirrorState.markReady()
            DarwinNotifier.post(SharedConfig.Notifications.streamReady)
        }
    }

    // MARK: - HTTP

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        switch request.path {
        case "/", "/index.html":
            return .data(Data(MirrorWebPage.html.utf8), contentType: "text/html; charset=utf-8")
        case "/live.m3u8":
            return .data(Data(store.playlist().utf8), contentType: "application/vnd.apple.mpegurl",
                         headers: ["Cache-Control": "no-cache"])
        case "/init.mp4":
            guard let data = store.initializationData() else { return .notFound }
            return .data(data, contentType: "video/mp4")
        case "/mjpeg":
            guard let mjpeg else { return .notFound }
            return .stream(contentType: "multipart/x-mixed-replace; boundary=\(MJPEGBroadcaster.boundary)") { writer in
                mjpeg.add(writer)
            }
        default:
            if request.path.hasPrefix("/seg"), request.path.hasSuffix(".m4s"),
               let sequence = Int(request.path.dropFirst(4).dropLast(4)),
               let data = store.segment(sequence: sequence) {
                return .data(data, contentType: "video/iso.segment")
            }
            return .notFound
        }
    }

    // MARK: - Lifecycle

    private func stopRequestedByApp() {
        tearDown()
        finishBroadcastWithError(Self.error("Screen mirroring stopped."))
    }

    private func tearDown() {
        guard !isTornDown else { return }
        isTornDown = true
        frameQueue.sync {
            repeatTimer?.cancel()
            repeatTimer = nil
            segmenter?.finish()
            lastFrame = nil
        }
        mjpeg?.closeAll()
        server?.stop()
        stopObserver = nil
        MirrorState.markStopped()
        DarwinNotifier.post(SharedConfig.Notifications.broadcastFinished)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ScreenMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
