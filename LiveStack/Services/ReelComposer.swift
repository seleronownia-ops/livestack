import Foundation
import AVFoundation
import CoreImage
import UIKit
import LiveStackCore

/// The reel: loops laid on two alternating tracks, rendered frame by frame by `ReelCompositor`,
/// which draws transitions, camera motion, stickers, the title and flashes straight from the core maths.
/// The same compositor runs in the preview player and in the export, so they cannot disagree.
struct ComposedReel {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let timeline: ReelTimeline
    let renderSize: CGSize
    let plan: ReelRenderPlan

    var duration: Double { timeline.total }

    func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }

    /// The export uses the very same video composition as the preview.
    func exportVideoComposition() -> AVMutableVideoComposition { videoComposition }
}

/// Everything the compositor needs to draw any frame of the reel. Immutable once built.
final class ReelRenderPlan {
    struct Item {
        let trackID: CMPersistentTrackID
        let timeline: TimelineItem
        /// Maps the decoded frame (natural size, origin top-left) to an upright picture with origin (0, 0).
        let upright: CGAffineTransform
        let naturalSize: CGSize
        let orientedSize: Size
        let motion: CameraMotion
        let stickers: [StickerArt]
    }
    struct StickerArt {
        let image: CIImage
        let placement: StickerPlacement
        let aspect: Double
    }

    let items: [Item]
    let timeline: ReelTimeline
    let settings: ReelSettings
    let renderSize: CGSize
    let titleImage: CIImage?
    let titleOrigin: CGPoint

    init(items: [Item], timeline: ReelTimeline, settings: ReelSettings, renderSize: CGSize) {
        self.items = items
        self.timeline = timeline
        self.settings = settings
        self.renderSize = renderSize
        let W = renderSize.width, H = renderSize.height
        titleOrigin = CGPoint(x: W * 0.07, y: H * 0.72)
        if settings.showTitle, !settings.title.trimmingCharacters(in: .whitespaces).isEmpty, let cg = TitleArt.render(settings.title, width: W * 0.86, fontSize: W * 0.085) {
            titleImage = CIImage(cgImage: cg)
        } else {
            titleImage = nil
        }
    }

    /// Transform from the decoded frame into the render frame (origin top-left) at `time` for an item in `state`.
    func frameTransform(item index: Int, time: Double, state: LayerState) -> CGAffineTransform {
        let item = items[index]
        let zoom = FitMath.zoomFactor(motion: item.motion, progress: item.timeline.progress(at: time)) * state.zoom
        let fit = FitMath.transform(source: item.orientedSize, render: Size(width: renderSize.width, height: renderSize.height), mode: settings.fit, zoom: zoom, offsetX: state.offsetX)
        return item.upright.concatenating(CGAffineTransform(a: fit.a, b: fit.b, c: fit.c, d: fit.d, tx: fit.tx, ty: fit.ty))
    }

    /// Opacity of the title at `t`: fades in after a beat and out before the first loop ends.
    func titleOpacity(at t: Double) -> Double {
        guard titleImage != nil, let first = timeline.items.first else { return 0 }
        let show = min(first.end, max(2.2, first.duration))
        let fadeIn = min(max((t - 0.25) / 0.4, 0), 1), fadeOut = min(max((show - t) / 0.4, 0), 1)
        return min(fadeIn, fadeOut)
    }
}

/// A video composition instruction that carries the plan and the loops on screen during its span.
final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    /// Item indices on screen, outgoing first during a transition.
    let itemIndices: [Int]
    let plan: ReelRenderPlan

    init(timeRange: CMTimeRange, itemIndices: [Int], plan: ReelRenderPlan) {
        self.timeRange = timeRange
        self.itemIndices = itemIndices
        self.plan = plan
        self.requiredSourceTrackIDs = itemIndices.map { NSNumber(value: plan.items[$0].trackID) }
    }
}

/// Draws one output frame: the loops with their transforms and opacities, then stickers, title and flash.
final class ReelCompositor: NSObject, AVVideoCompositing {
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "LiveStack"])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    ]
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? ReelInstruction else {
            request.finish(with: LiveStackError.exportFailed("unexpected instruction"))
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: LiveStackError.exportFailed("no output buffer"))
            return
        }
        let image = Self.render(instruction: instruction, time: request.compositionTime.seconds) { trackID in
            request.sourceFrame(byTrackID: trackID).map { CIImage(cvPixelBuffer: $0) }
        }
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.plan.renderSize), colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    /// Builds the frame as a Core Image graph. Core Image's origin is bottom-left, the plan's is top-left,
    /// so every placement is flipped on the way in.
    static func render(instruction: ReelInstruction, time t: Double, source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let plan = instruction.plan
        let size = plan.renderSize
        let rect = CGRect(origin: .zero, size: size)
        var canvas = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
        let timeline = plan.timeline

        // Which loops are visible and in what state.
        var layers: [(index: Int, state: LayerState)] = []
        var flash = 0.0
        if instruction.itemIndices.count == 2 {
            let out = instruction.itemIndices[0], inc = instruction.itemIndices[1]
            let a = timeline.items[out], b = timeline.items[inc]
            let overlap = a.end - b.start
            let raw = overlap > 0 ? min(max((t - b.start) / overlap, 0), 1) : 1
            let states = TransitionMath.states(style: plan.settings.transition, rawProgress: raw)
            layers = TransitionMath.incomingOnTop(style: plan.settings.transition)
                ? [(out, states.outgoing), (inc, states.incoming)]
                : [(inc, states.incoming), (out, states.outgoing)]
            if plan.settings.transition == .flash { flash = TransitionMath.flashOpacity(rawProgress: raw) }
        } else if let only = instruction.itemIndices.first {
            layers = [(only, LayerState())]
        }

        for layer in layers where layer.state.opacity > 0.001 {
            let item = plan.items[layer.index]
            guard let frame = source(item.trackID) else { continue }
            let transform = plan.frameTransform(item: layer.index, time: t, state: layer.state)
            let flipped = flipY(height: frame.extent.height).concatenating(transform).concatenating(flipY(height: size.height))
            var picture = frame.transformed(by: flipped).cropped(to: rect)
            picture = picture.withOpacity(layer.state.opacity)
            canvas = picture.composited(over: canvas)
            // Stickers belong to their loop: same offset and opacity as the loop itself.
            let tau = t - item.timeline.start
            let progress = item.timeline.progress(at: t)
            for art in item.stickers {
                let pose = StickerMath.pose(art.placement, tau: tau, progress: progress)
                let w = size.width * art.placement.size * pose.scale
                let h = w / CGFloat(max(0.05, art.aspect))
                guard w > 0.5, h > 0.5 else { continue }
                let cx = size.width * (art.placement.x + pose.dx + layer.state.offsetX)
                let cy = size.height - size.height * (art.placement.y + pose.dy)
                let sticker = art.image
                    .transformed(by: CGAffineTransform(translationX: -art.image.extent.midX, y: -art.image.extent.midY))
                    .transformed(by: CGAffineTransform(scaleX: w / art.image.extent.width, y: h / art.image.extent.height))
                    .transformed(by: CGAffineTransform(rotationAngle: -pose.rotationDegrees * .pi / 180))
                    .transformed(by: CGAffineTransform(translationX: cx, y: cy))
                    .cropped(to: rect)
                canvas = sticker.withOpacity(layer.state.opacity).composited(over: canvas)
            }
        }

        if let title = plan.titleImage {
            let alpha = plan.titleOpacity(at: t)
            if alpha > 0.001 {
                let y = size.height - plan.titleOrigin.y - title.extent.height
                canvas = title.transformed(by: CGAffineTransform(translationX: plan.titleOrigin.x, y: y)).cropped(to: rect).withOpacity(alpha).composited(over: canvas)
            }
        }
        if flash > 0.001 {
            canvas = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(flash))).cropped(to: rect).composited(over: canvas)
        }
        return canvas
    }

    static func flipY(height: CGFloat) -> CGAffineTransform { CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height) }
}

extension CIImage {
    /// Fades the whole image, keeping colour premultiplied.
    func withOpacity(_ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return self }
        let a = CGFloat(max(0, alpha))
        return applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)
        ])
    }
}

/// Renders the reel title to an image once: heavy rounded type, white, soft shadow, short underline.
enum TitleArt {
    static func render(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGImage? {
        let descriptor = UIFont.systemFont(ofSize: fontSize, weight: .heavy).fontDescriptor.withDesign(.rounded) ?? UIFont.systemFont(ofSize: fontSize, weight: .heavy).fontDescriptor
        let font = UIFont(descriptor: descriptor, size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = fontSize * 0.25
        shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.06)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph, .shadow: shadow]
        let bounds = (text as NSString).boundingRect(with: CGSize(width: width, height: fontSize * 3), options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
        let pad = fontSize * 0.5
        let height = ceil(bounds.height) + pad * 2 + fontSize * 0.4
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: ceil(width) + pad * 2, height: height), format: format)
        let image = renderer.image { _ in
            (text as NSString).draw(with: CGRect(x: pad, y: pad, width: width, height: fontSize * 3), options: [.usesLineFragmentOrigin], attributes: attributes, context: nil)
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(x: pad, y: pad + ceil(bounds.height) + fontSize * 0.18, width: width * 0.18, height: max(3, fontSize * 0.06))).fill()
        }
        return image.cgImage
    }
}

enum ReelComposer {
    struct Input {
        let asset: LoopAsset
        let stickers: [Sticker]
    }

    static func compose(inputs: [Input], settings: ReelSettings) async throws -> ComposedReel {
        let frame = settings.frame.size
        let renderSize = CGSize(width: frame.width, height: frame.height)
        let timeline = ReelTimeline.build(durations: inputs.map { $0.asset.duration }, transition: settings.transition, transitionLength: settings.transitionLength)
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        videoComposition.customVideoCompositorClass = ReelCompositor.self
        guard !inputs.isEmpty else {
            let plan = ReelRenderPlan(items: [], timeline: timeline, settings: settings, renderSize: renderSize)
            return ComposedReel(composition: composition, videoComposition: videoComposition, timeline: timeline, renderSize: renderSize, plan: plan)
        }
        let tracks = [
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!,
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        ]
        var items: [ReelRenderPlan.Item] = []
        for (i, input) in inputs.enumerated() {
            let asset = AVURLAsset(url: input.asset.url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first else { throw LiveStackError.noVideoTrack }
            let (natural, transform) = try await srcTrack.load(.naturalSize, .preferredTransform)
            let assetDuration = try await asset.load(.duration)
            let item = timeline.items[i]
            try tracks[i % 2].insertTimeRange(CMTimeRange(start: .zero, duration: assetDuration), of: srcTrack, at: CMTime(seconds: item.start, preferredTimescale: 600))
            let oriented = CGRect(origin: .zero, size: natural).applying(transform)
            let upright = transform.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            let art = input.stickers.compactMap { s -> ReelRenderPlan.StickerArt? in
                guard let cg = s.image.cgImage else { return nil }
                return ReelRenderPlan.StickerArt(image: CIImage(cgImage: cg), placement: s.placement, aspect: s.aspect)
            }
            items.append(ReelRenderPlan.Item(trackID: tracks[i % 2].trackID, timeline: item, upright: upright, naturalSize: natural,
                                             orientedSize: Size(width: abs(oriented.width), height: abs(oriented.height)), motion: input.asset.spec.motion, stickers: art))
        }
        let plan = ReelRenderPlan(items: items, timeline: timeline, settings: settings, renderSize: renderSize)
        videoComposition.instructions = timeline.spans().map { span in
            ReelInstruction(timeRange: CMTimeRange(start: CMTime(seconds: span.start, preferredTimescale: 600), end: CMTime(seconds: span.end, preferredTimescale: 600)), itemIndices: span.items, plan: plan)
        }
        return ComposedReel(composition: composition, videoComposition: videoComposition, timeline: timeline, renderSize: renderSize, plan: plan)
    }
}
