import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Writes the reel to an MP4, and turns any video into an animated GIF.
enum ReelExporter {
    static func exportVideo(_ reel: ComposedReel, to url: URL? = nil, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let out = url ?? AppPaths.temporaryFile("reel", ext: "mp4")
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: reel.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw LiveStackError.exportFailed("no export session")
        }
        session.videoComposition = reel.exportVideoComposition()
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        let poll = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poll.cancel() }
        if #available(iOS 18, *) {
            try await session.export(to: out, as: .mp4)
        } else {
            await session.export()
            if session.status != .completed { throw LiveStackError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)") }
        }
        progress?(1)
        return out
    }

    /// Samples `video` at `fps` and writes a looping GIF no wider or taller than `maxSide`.
    static func makeGIF(from video: URL, fps: Double, maxSide: CGFloat, maxSeconds: Double = 15, to url: URL? = nil, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let out = url ?? AppPaths.temporaryFile("loop", ext: "gif")
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: video)
        let duration = min(try await asset.load(.duration).seconds, maxSeconds)
        let count = max(2, Int((duration * fps).rounded(.down)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }

        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw LiveStackError.exportFailed("could not create the GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps, kCGImagePropertyGIFUnclampedDelayTime: 1.0 / fps]] as CFDictionary
        var written = 0
        for await result in generator.images(for: times) {
            guard let image = try? result.image else { continue }
            CGImageDestinationAddImage(dest, image, frameProps)
            written += 1
            progress?(Double(written) / Double(count))
        }
        guard written >= 1, CGImageDestinationFinalize(dest) else { throw LiveStackError.exportFailed("could not finish the GIF") }
        return out
    }

    /// Number of frames in a GIF file.
    static func gifFrameCount(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }
}
