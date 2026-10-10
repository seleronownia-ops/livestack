import Foundation
import AVFoundation
import CoreGraphics
import UIKit
import LiveStackCore

/// Reads a source video once: motion energy for auto cut, a filmstrip for the editor, and basic facts.
enum MotionAnalyzer {
    static let samplesPerSecond = 8.0
    static let filmstripCount = 16

    struct Analysis {
        let duration: Double
        let sourceFPS: Double
        let orientedSize: CGSize
        let energy: [Double]
        let filmstrip: [UIImage]
    }

    static func analyze(url: URL) async throws -> Analysis {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LiveStackError.noVideoTrack }
        let (naturalSize, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        let sourceFPS = fps > 1 ? Double(fps) : 30

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)
        generator.maximumSize = CGSize(width: 64, height: 64)

        var times: [CMTime] = []
        var t = 0.0
        while t < duration - 0.01 {
            times.append(CMTime(seconds: t, preferredTimescale: 600))
            t += 1.0 / samplesPerSecond
        }
        if times.isEmpty { times = [.zero] }

        var grays: [[UInt8]] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { grays.append(grayBytes(of: image, side: 32)) }
        }
        let energy = MotionEnergy.energy(frames: grays)

        let stripGenerator = AVAssetImageGenerator(asset: asset)
        stripGenerator.appliesPreferredTrackTransform = true
        stripGenerator.requestedTimeToleranceBefore = .zero
        stripGenerator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        stripGenerator.maximumSize = CGSize(width: 160, height: 160)
        let stripTimes = (0..<filmstripCount).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(filmstripCount), preferredTimescale: 600) }
        var strip: [UIImage] = []
        for await result in stripGenerator.images(for: stripTimes) {
            if let image = try? result.image { strip.append(UIImage(cgImage: image)) }
        }
        return Analysis(duration: duration, sourceFPS: sourceFPS, orientedSize: orientedSize, energy: energy, filmstrip: strip)
    }

    /// Downsamples an image to `side`×`side` 8-bit grey values.
    static func grayBytes(of image: CGImage, side: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: side * side)
        bytes.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return bytes
    }
}
