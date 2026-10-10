import Foundation
import UIKit
import LiveStackCore

/// A sticker layered over one loop.
struct Sticker: Identifiable, Equatable {
    let id: UUID
    var image: UIImage
    var placement: StickerPlacement

    init(id: UUID = UUID(), image: UIImage, placement: StickerPlacement = StickerPlacement()) {
        self.id = id
        self.image = image
        self.placement = placement
    }

    var aspect: Double { image.size.height > 0 ? Double(image.size.width / image.size.height) : 1 }

    static func == (lhs: Sticker, rhs: Sticker) -> Bool { lhs.id == rhs.id && lhs.placement == rhs.placement && lhs.image === rhs.image }
}

/// A rendered bounce loop on disk, ready to be dropped into the reel.
struct LoopAsset: Equatable {
    let url: URL
    let duration: Double
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
    /// The spec this file was rendered from; used to skip redundant renders.
    let spec: LoopSpec

    /// Size after the preferred transform (what the viewer sees).
    var orientedSize: CGSize {
        let r = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }
}

/// One Live Photo in the project.
struct LoopClip: Identifiable, Equatable {
    let id: UUID
    var name: String
    let assetIdentifier: String?
    let sourceURL: URL
    let sourceDuration: Double
    let sourceFPS: Double
    let orientedSize: CGSize
    /// Motion energy sampled at `MotionAnalyzer.samplesPerSecond`.
    let energy: [Double]
    /// Frames across the whole source, for the filmstrip.
    var filmstrip: [UIImage]
    var spec: LoopSpec
    var stickers: [Sticker]
    var loopAsset: LoopAsset?
    var thumbnail: UIImage?

    /// Estimated length in the reel before the loop file exists; the real file duration wins once rendered.
    var estimatedDuration: Double {
        loopAsset?.duration ?? LoopPlan.duration(spec: spec, sourceFPS: sourceFPS, sourceDuration: sourceDuration)
    }

    var summary: String {
        let mode: String
        switch spec.mode { case .bounce: mode = "bounce"; case .forward: mode = "forward"; case .reverse: mode = "reverse" }
        let speed = spec.speed == spec.speed.rounded() ? "\(Int(spec.speed))×" : "\(spec.speed)×"
        var parts = [String(format: "%.1f s in reel", estimatedDuration), mode, speed]
        if spec.repeats > 1 { parts.append("\(spec.repeats) times") }
        if !stickers.isEmpty { parts.append(stickers.count == 1 ? "1 sticker" : "\(stickers.count) stickers") }
        return parts.joined(separator: " · ")
    }
}

enum LiveStackError: LocalizedError {
    case noVideoTrack
    case noPairedVideo
    case readerFailed(String)
    case writerFailed(String)
    case exportFailed(String)
    case cancelled
    case nothingToExport

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "That file has no video track."
        case .noPairedVideo: return "This Live Photo has no motion video attached."
        case .readerFailed(let s): return "Could not read the video: \(s)"
        case .writerFailed(let s): return "Could not write the loop: \(s)"
        case .exportFailed(let s): return "Export failed: \(s)"
        case .cancelled: return "Stopped."
        case .nothingToExport: return "Add at least one Live Photo first."
        }
    }
}

enum AppPaths {
    static var work: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveStack", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func temporaryFile(_ name: String, ext: String) -> URL {
        work.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).\(ext)")
    }
    static func clearWork() {
        try? FileManager.default.removeItem(at: work)
    }
}
