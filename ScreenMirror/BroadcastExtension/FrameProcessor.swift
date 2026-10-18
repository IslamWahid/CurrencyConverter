import CoreMedia
import CoreVideo
import ImageIO
import VideoToolbox

/// Turns ReplayKit screen frames into upright, letterboxed frames of a fixed (landscape) size,
/// so the encoder and the TV see one constant resolution whichever way the phone is held.
final class FrameProcessor {
    let outputWidth: Int
    let outputHeight: Int

    private var rotationSession: VTPixelRotationSession?
    private var transferSession: VTPixelTransferSession?
    private var pools: [String: CVPixelBufferPool] = [:]

    init(width: Int, height: Int) {
        outputWidth = width
        outputHeight = height
        VTPixelRotationSessionCreate(nil, &rotationSession)
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transferSession)
        if let transferSession {
            VTSessionSetProperty(transferSession, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: kVTScalingMode_Letterbox)
        }
    }

    deinit {
        if let rotationSession { VTPixelRotationSessionInvalidate(rotationSession) }
        if let transferSession { VTPixelTransferSessionInvalidate(transferSession) }
    }

    func process(_ source: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> CVPixelBuffer? {
        let format = CVPixelBufferGetPixelFormatType(source)
        var upright = source

        if let rotation = Self.rotation(for: orientation), let rotationSession {
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            let quarterTurn = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
            guard let rotated = makeBuffer(width: quarterTurn ? height : width,
                                           height: quarterTurn ? width : height,
                                           format: format) else { return nil }
            VTSessionSetProperty(rotationSession, key: kVTPixelRotationPropertyKey_Rotation, value: rotation)
            guard VTPixelRotationSessionRotateImage(rotationSession, source, rotated) == noErr else {
                return nil
            }
            upright = rotated
        }

        guard let transferSession,
              let output = makeBuffer(width: outputWidth, height: outputHeight, format: format),
              VTPixelTransferSessionTransferImage(transferSession, from: upright, to: output) == noErr else {
            return nil
        }
        return output
    }

    /// `RPVideoSampleOrientationKey` says how the frame must be rotated to appear upright.
    private static func rotation(for orientation: CGImagePropertyOrientation) -> CFString? {
        switch orientation {
        case .right, .rightMirrored: return kVTRotation_CW90
        case .left, .leftMirrored: return kVTRotation_CCW90
        case .down, .downMirrored: return kVTRotation_180
        default: return nil
        }
    }

    private func makeBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let key = "\(width)x\(height)x\(format)"
        if pools[key] == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            pools[key] = pool
        }
        guard let pool = pools[key] else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
