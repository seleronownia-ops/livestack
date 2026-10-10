import Foundation
import AVFoundation
import CoreVideo
import UIKit

/// Writes small test videos with known content: a solid hue per scene and a circle moving only in a chosen window,
/// so tests can read colours back and know what they should see.
enum SyntheticVideo {
    struct Scene {
        let hue: CGFloat          // 0...1
        let seconds: Double
        /// Time range (relative to the scene start) in which the circle moves; outside it stays still.
        let motion: ClosedRange<Double>?
    }

    @discardableResult
    static func write(to url: URL, scenes: [Scene], fps: Int32 = 30, size: CGSize = CGSize(width: 480, height: 640)) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var frame = 0
        for scene in scenes {
            let count = Int((scene.seconds * Double(fps)).rounded())
            for k in 0..<count {
                let t = Double(k) / Double(fps)
                let moving = scene.motion.map { $0.contains(t) } ?? false
                let phase = moving ? t * 4 : 0
                let buffer = try pixelBuffer(size: size, hue: scene.hue, phase: phase, pool: adaptor.pixelBufferPool)
                while !input.isReadyForMoreMediaData { usleep(1000) }
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
                frame += 1
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? NSError(domain: "SyntheticVideo", code: 1) }
        return url
    }

    static func pixelBuffer(size: CGSize, hue: CGFloat, phase: Double, pool: CVPixelBufferPool?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) }
        if buffer == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        }
        guard let pb = buffer else { throw NSError(domain: "SyntheticVideo", code: 2) }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(UIColor(hue: hue, saturation: 0.85, brightness: 0.75, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let r = size.width * 0.12
        let cx = size.width / 2 + cos(phase) * size.width * 0.3, cy = size.height / 2 + sin(phase) * size.height * 0.3
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        return pb
    }

    /// Average colour of a frame at `time` in the video at `url`, as (r, g, b) in 0...255.
    static func averageColor(of url: URL, at time: Double, region: CGRect? = nil) async throws -> (r: Double, g: Double, b: Double) {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let image = try await gen.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        return averageColor(of: image, region: region)
    }

    static func averageColor(of image: CGImage, region: CGRect? = nil) -> (r: Double, g: Double, b: Double) {
        let w = 32, h = 32
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .low
            if let region {
                // Draw only the requested part of the image, scaled into the whole context.
                let crop = image.cropping(to: CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height), width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height))) ?? image
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            } else {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: bytes.count, by: 4) { r += Double(bytes[i]); g += Double(bytes[i + 1]); b += Double(bytes[i + 2]) }
        let n = Double(w * h)
        return (r / n, g / n, b / n)
    }

    /// Mean absolute per-pixel difference (0...255, averaged over RGB) between two frames of a video.
    static func frameDifference(of url: URL, between t1: Double, and t2: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let a = try await gen.image(at: CMTime(seconds: t1, preferredTimescale: 600)).image
        let b = try await gen.image(at: CMTime(seconds: t2, preferredTimescale: 600)).image
        let pa = rgbBytes(of: a), pb = rgbBytes(of: b)
        var sum = 0
        for i in 0..<min(pa.count, pb.count) { sum += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(sum) / Double(max(1, min(pa.count, pb.count)))
    }

    static func rgbBytes(of image: CGImage) -> [UInt8] {
        let w = 32, h = 32
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var out: [UInt8] = []
        out.reserveCapacity(w * h * 3)
        for i in stride(from: 0, to: bytes.count, by: 4) { out.append(bytes[i]); out.append(bytes[i + 1]); out.append(bytes[i + 2]) }
        return out
    }

    /// Hue (0...1) of an average colour.
    static func hue(_ c: (r: Double, g: Double, b: Double)) -> Double {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(red: c.r / 255, green: c.g / 255, blue: c.b / 255, alpha: 1).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return Double(h)
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double { let d = abs(a - b); return min(d, 1 - d) }

    static func tempURL(_ name: String, _ ext: String = "mov") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).\(ext)")
    }
}
