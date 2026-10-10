import Foundation
import AVFoundation
import CoreVideo
import LiveStackCore

/// Renders one Live Photo window into a small H.264 file that plays the bounce exactly as specified.
/// Decoding and encoding happen one loop at a time, which is what the phone's decoders are happy with.
actor LoopRenderer {
    static let shared = LoopRenderer()

    func render(sourceURL: URL, spec: LoopSpec, outputURL: URL? = nil) async throws -> LoopAsset {
        let out = outputURL ?? AppPaths.temporaryFile("loop", ext: "mp4")
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: sourceURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LiveStackError.noVideoTrack }
        let (naturalSize, transform, nominalFPS) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let sourceFPS = nominalFPS > 1 ? Double(nominalFPS) : 30
        let clamped = spec.clamped(toSourceDuration: duration)

        let frameDuration = LoopPlan.frameDuration(spec: clamped, sourceFPS: sourceFPS)
        // Decode and encode off the cooperative pool: both block while the media pipeline works.
        try await Task.detached(priority: .userInitiated) {
            let frames = try Self.decodeWindow(asset: asset, track: track, start: clamped.windowStart, length: clamped.windowLength, sourceFPS: sourceFPS)
            guard frames.count >= 1 else { throw LiveStackError.readerFailed("no frames in the window") }
            let order = LoopPlan.playOrder(count: frames.count, mode: clamped.mode, repeats: clamped.repeats)
            try Self.encode(frames: frames, order: order, frameDuration: frameDuration, size: naturalSize, transform: transform, to: out)
        }.value
        let written = AVURLAsset(url: out)
        let writtenDuration = try await written.load(.duration).seconds
        return LoopAsset(url: out, duration: writtenDuration, naturalSize: naturalSize, preferredTransform: transform, spec: clamped)
    }

    /// Decodes the frames whose timestamps fall inside the window, in presentation order.
    nonisolated static func decodeWindow(asset: AVAsset, track: AVAssetTrack, start: Double, length: Double, sourceFPS: Double) throws -> [CVPixelBuffer] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { throw LiveStackError.readerFailed("cannot add output") }
        reader.add(output)
        let halfFrame = 0.5 / sourceFPS
        let quarterFrame = 0.25 / sourceFPS
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start - halfFrame), preferredTimescale: 600),
                                       duration: CMTime(seconds: length + 2 * halfFrame, preferredTimescale: 600))
        guard reader.startReading() else { throw LiveStackError.readerFailed(reader.error?.localizedDescription ?? "start failed") }
        var frames: [(Double, CVPixelBuffer)] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            // Frames whose timestamp lands inside the window, with a quarter frame of slack at both ends.
            if pts >= start - quarterFrame && pts < start + length - quarterFrame {
                frames.append((pts, buffer))
            }
        }
        if reader.status == .failed { throw LiveStackError.readerFailed(reader.error?.localizedDescription ?? "unknown") }
        return frames.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    nonisolated static func encode(frames: [CVPixelBuffer], order: [Int], frameDuration: Double, size: CGSize, transform: CGAffineTransform, to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(size.width.rounded()) & ~1, height = Int(size.height.rounded()) & ~1
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 16_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 15,
                AVVideoExpectedSourceFrameRateKey: Int((1 / frameDuration).rounded())
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        guard writer.canAdd(input) else { throw LiveStackError.writerFailed("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw LiveStackError.writerFailed(writer.error?.localizedDescription ?? "start failed") }
        writer.startSession(atSourceTime: .zero)
        for (k, idx) in order.enumerated() {
            while !input.isReadyForMoreMediaData { usleep(2_000) }
            let pts = CMTime(seconds: Double(k) * frameDuration, preferredTimescale: 90_000)
            if !adaptor.append(frames[idx], withPresentationTime: pts) {
                throw LiveStackError.writerFailed(writer.error?.localizedDescription ?? "append failed at frame \(k)")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: Double(order.count) * frameDuration, preferredTimescale: 90_000))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw LiveStackError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)") }
    }
}
