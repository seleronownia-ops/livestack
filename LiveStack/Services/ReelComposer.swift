import Foundation
import AVFoundation
import QuartzCore
import UIKit
import LiveStackCore

/// The reel: loops laid on two alternating tracks, transitions as transform and opacity ramps,
/// stickers, title and flashes as Core Animation layers that work both in the player and in the export.
struct ComposedReel {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let timeline: ReelTimeline
    let renderSize: CGSize
    private let overlayBuilder: () -> CALayer

    init(composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, timeline: ReelTimeline, renderSize: CGSize, overlayBuilder: @escaping () -> CALayer) {
        self.composition = composition
        self.videoComposition = videoComposition
        self.timeline = timeline
        self.renderSize = renderSize
        self.overlayBuilder = overlayBuilder
    }

    var duration: Double { timeline.total }

    /// A fresh overlay layer tree in render coordinates (origin top-left, like UIKit). Animations are in item time.
    func makeOverlayLayer() -> CALayer { overlayBuilder() }

    /// A player item for the live preview. Overlays go in an `AVSynchronizedLayer` on top of the player layer.
    func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }

    /// A copy of the video composition that bakes the overlays in, for export.
    func exportVideoComposition() -> AVMutableVideoComposition {
        let vc = videoComposition.mutableCopy() as! AVMutableVideoComposition
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        parent.addSublayer(makeOverlayLayer())
        vc.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        return vc
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
        guard !inputs.isEmpty else {
            let vc = AVMutableVideoComposition()
            vc.renderSize = renderSize
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
            return ComposedReel(composition: composition, videoComposition: vc, timeline: timeline, renderSize: renderSize, overlayBuilder: { CALayer() })
        }
        let tracks = [
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!,
            composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        ]
        var sourceTransforms: [CGAffineTransform] = []
        var orientedSizes: [Size] = []
        for (i, input) in inputs.enumerated() {
            let asset = AVURLAsset(url: input.asset.url)
            guard let srcTrack = try await asset.loadTracks(withMediaType: .video).first else { throw LiveStackError.noVideoTrack }
            let (natural, transform) = try await srcTrack.load(.naturalSize, .preferredTransform)
            let assetDuration = try await asset.load(.duration)
            let item = timeline.items[i]
            let range = CMTimeRange(start: .zero, duration: assetDuration)
            try tracks[i % 2].insertTimeRange(range, of: srcTrack, at: CMTime(seconds: item.start, preferredTimescale: 600))
            // Map the natural frame into an upright rectangle with its origin at (0, 0).
            let oriented = CGRect(origin: .zero, size: natural).applying(transform)
            let upright = transform.concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            sourceTransforms.append(upright)
            orientedSizes.append(Size(width: abs(oriented.width), height: abs(oriented.height)))
        }

        func layerTransform(index: Int, time: Double, state: LayerState) -> CGAffineTransform {
            let item = timeline.items[index]
            let zoom = FitMath.zoomFactor(motion: inputs[index].asset.spec.motion, progress: item.progress(at: time)) * state.zoom
            let fit = FitMath.transform(source: orientedSizes[index], render: Size(width: renderSize.width, height: renderSize.height), mode: settings.fit, zoom: zoom, offsetX: state.offsetX)
            return sourceTransforms[index].concatenating(CGAffineTransform(a: fit.a, b: fit.b, c: fit.c, d: fit.d, tx: fit.tx, ty: fit.ty))
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        let epsilon = 1e-4
        for span in splitFlash(timeline.spans(), style: settings.transition) {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: CMTime(seconds: span.start, preferredTimescale: 600), end: CMTime(seconds: span.end, preferredTimescale: 600))
            var layers: [AVMutableVideoCompositionLayerInstruction] = []
            if span.isTransition {
                let out = span.items[0], inc = span.items[1]
                let overlapStart = timeline.items[inc].start, overlapEnd = timeline.items[out].end
                func raw(_ t: Double) -> Double { overlapEnd > overlapStart ? (t - overlapStart) / (overlapEnd - overlapStart) : 1 }
                let s0 = TransitionMath.states(style: settings.transition, rawProgress: raw(span.start + epsilon))
                let s1 = TransitionMath.states(style: settings.transition, rawProgress: raw(span.end - epsilon))
                let outLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[out % 2])
                outLayer.setTransformRamp(fromStart: layerTransform(index: out, time: span.start, state: s0.outgoing), toEnd: layerTransform(index: out, time: span.end, state: s1.outgoing), timeRange: instruction.timeRange)
                outLayer.setOpacityRamp(fromStartOpacity: Float(s0.outgoing.opacity), toEndOpacity: Float(s1.outgoing.opacity), timeRange: instruction.timeRange)
                let inLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[inc % 2])
                inLayer.setTransformRamp(fromStart: layerTransform(index: inc, time: span.start, state: s0.incoming), toEnd: layerTransform(index: inc, time: span.end, state: s1.incoming), timeRange: instruction.timeRange)
                inLayer.setOpacityRamp(fromStartOpacity: Float(s0.incoming.opacity), toEndOpacity: Float(s1.incoming.opacity), timeRange: instruction.timeRange)
                layers = TransitionMath.incomingOnTop(style: settings.transition) ? [inLayer, outLayer] : [outLayer, inLayer]
            } else {
                let idx = span.items[0]
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: tracks[idx % 2])
                layer.setTransformRamp(fromStart: layerTransform(index: idx, time: span.start, state: LayerState()), toEnd: layerTransform(index: idx, time: span.end, state: LayerState()), timeRange: instruction.timeRange)
                layer.setOpacity(1, at: instruction.timeRange.start)
                layers = [layer]
            }
            instruction.layerInstructions = layers
            instruction.backgroundColor = UIColor.black.cgColor
            instructions.append(instruction)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        videoComposition.instructions = instructions

        let overlayInputs = inputs
        let overlayTimeline = timeline
        let overlaySettings = settings
        let builder: () -> CALayer = {
            OverlayBuilder.build(renderSize: renderSize, timeline: overlayTimeline, stickers: overlayInputs.map { $0.stickers }, settings: overlaySettings)
        }
        return ComposedReel(composition: composition, videoComposition: videoComposition, timeline: timeline, renderSize: renderSize, overlayBuilder: builder)
    }

    /// Flash and cut jump in the middle of the overlap, so their transition spans are split there
    /// to keep every ramp continuous.
    static func splitFlash(_ spans: [TimelineSpan], style: TransitionStyle) -> [TimelineSpan] {
        guard style == .flash || style == .cut else { return spans }
        var out: [TimelineSpan] = []
        for s in spans {
            if s.isTransition {
                let mid = (s.start + s.end) / 2
                out.append(TimelineSpan(start: s.start, end: mid, items: s.items))
                out.append(TimelineSpan(start: mid, end: s.end, items: s.items))
            } else {
                out.append(s)
            }
        }
        return out
    }
}

/// Builds the Core Animation layer tree for stickers, the title and flash transitions.
/// Coordinates: origin top-left, in render pixels. Time: item time, offset by `AVCoreAnimationBeginTimeAtZero`.
enum OverlayBuilder {
    static func build(renderSize: CGSize, timeline: ReelTimeline, stickers: [[Sticker]], settings: ReelSettings) -> CALayer {
        let root = CALayer()
        root.frame = CGRect(origin: .zero, size: renderSize)
        root.masksToBounds = true
        let total = max(timeline.total, 0.01)
        let W = renderSize.width, H = renderSize.height

        for (i, item) in timeline.items.enumerated() where i < stickers.count {
            for sticker in stickers[i] {
                root.addSublayer(stickerLayer(sticker, item: item, total: total, W: W, H: H))
            }
        }
        if settings.showTitle, !settings.title.trimmingCharacters(in: .whitespaces).isEmpty, let first = timeline.items.first {
            root.addSublayer(titleLayer(settings.title, first: first, total: total, W: W, H: H))
        }
        if settings.transition == .flash {
            let spans = timeline.spans().filter(\.isTransition)
            if !spans.isEmpty { root.addSublayer(flashLayer(spans: spans, total: total, size: renderSize)) }
        }
        return root
    }

    static func visibility(from start: Double, to end: Double, total: Double) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.calculationMode = .discrete
        let s = max(0, min(1, start / total)), e = max(s, min(1, end / total))
        // Key times must climb; drop the leading or trailing hidden stretch when it would be empty.
        if s <= 0 && e >= 1 { anim.values = [1]; anim.keyTimes = [0, 1] }
        else if s <= 0 { anim.values = [1, 0]; anim.keyTimes = [0, NSNumber(value: e), 1] }
        else if e >= 1 { anim.values = [0, 1]; anim.keyTimes = [0, NSNumber(value: s), 1] }
        else { anim.values = [0, 1, 0]; anim.keyTimes = [0, NSNumber(value: s), NSNumber(value: e), 1] }
        anim.duration = total
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        return anim
    }

    static func stickerLayer(_ sticker: Sticker, item: TimelineItem, total: Double, W: CGFloat, H: CGFloat) -> CALayer {
        let p = sticker.placement
        let layer = CALayer()
        let w = W * p.size
        let h = w / CGFloat(max(0.05, sticker.aspect))
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layer.position = CGPoint(x: W * p.x, y: H * p.y)
        layer.contents = sticker.image.cgImage
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = 1
        layer.opacity = 0
        layer.setValue(p.rotationDegrees * .pi / 180, forKeyPath: "transform.rotation.z")
        layer.add(visibility(from: item.start, to: item.end, total: total), forKey: "visible")

        let begin = AVCoreAnimationBeginTimeAtZero + item.start
        switch p.animation {
        case .still:
            break
        case .pop:
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = [0.0, 1.15, 0.95, 1.0]
            a.keyTimes = [0, 0.55, 0.8, 1]
            a.duration = 0.45
            a.beginTime = begin
            a.isRemovedOnCompletion = false
            a.fillMode = .both
            layer.add(a, forKey: "pop")
        case .float:
            let a = sampled(keyPath: "position.y", period: 1 / 0.8, samples: 24) { CGFloat(sin($0 * 2 * .pi)) * 0.02 * H }
            a.beginTime = begin
            a.repeatDuration = item.duration
            layer.add(a, forKey: "float")
        case .wiggle:
            let a = sampled(keyPath: "transform.rotation.z", period: 1 / 2.5, samples: 24) { CGFloat(sin($0 * 2 * .pi)) * 7 * .pi / 180 }
            a.beginTime = begin
            a.repeatDuration = item.duration
            layer.add(a, forKey: "wiggle")
        case .drift:
            let a = CABasicAnimation(keyPath: "position.x")
            a.fromValue = -0.07 * W
            a.toValue = 0.07 * W
            a.isAdditive = true
            a.duration = max(0.01, item.duration)
            a.beginTime = begin
            a.isRemovedOnCompletion = false
            a.fillMode = .both
            layer.add(a, forKey: "drift")
        }
        return layer
    }

    /// An additive animation that follows `f(phase)` for one period and repeats.
    static func sampled(keyPath: String, period: Double, samples: Int, f: (Double) -> CGFloat) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = (0...samples).map { f(Double($0) / Double(samples)) }
        a.keyTimes = (0...samples).map { NSNumber(value: Double($0) / Double(samples)) }
        a.duration = period
        a.isAdditive = true
        a.calculationMode = .linear
        a.isRemovedOnCompletion = false
        a.fillMode = .both
        return a
    }

    static func titleLayer(_ text: String, first: TimelineItem, total: Double, W: CGFloat, H: CGFloat) -> CALayer {
        let group = CALayer()
        group.frame = CGRect(x: 0, y: 0, width: W, height: H)
        let size = W * 0.085
        let descriptor = UIFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor.withDesign(.rounded) ?? UIFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor
        let font = UIFont(descriptor: descriptor, size: size)
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = font
        textLayer.fontSize = size
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.alignmentMode = .left
        textLayer.isWrapped = true
        textLayer.truncationMode = .end
        textLayer.contentsScale = 2
        textLayer.frame = CGRect(x: W * 0.07, y: H * 0.72, width: W * 0.86, height: size * 2.4)
        textLayer.shadowColor = UIColor.black.cgColor
        textLayer.shadowOpacity = 0.6
        textLayer.shadowRadius = size * 0.25
        textLayer.shadowOffset = CGSize(width: 0, height: size * 0.06)
        group.addSublayer(textLayer)
        let bar = CALayer()
        bar.backgroundColor = UIColor.white.cgColor
        bar.frame = CGRect(x: W * 0.07, y: H * 0.72 + size * 1.45, width: W * 0.16, height: max(3, size * 0.06))
        group.addSublayer(bar)

        let show = min(first.end, max(2.2, first.duration))
        let fade = 0.4
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 0, 1, 1, 0, 0]
        a.keyTimes = [0, NSNumber(value: 0.25 / total), NSNumber(value: min(1, (0.25 + fade) / total)), NSNumber(value: min(1, max(0, show - fade) / total)), NSNumber(value: min(1, show / total)), 1]
        a.duration = total
        a.beginTime = AVCoreAnimationBeginTimeAtZero
        a.isRemovedOnCompletion = false
        a.fillMode = .both
        group.opacity = 0
        group.add(a, forKey: "title")
        return group
    }

    static func flashLayer(spans: [TimelineSpan], total: Double, size: CGSize) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        layer.backgroundColor = UIColor.white.cgColor
        layer.opacity = 0
        var values: [NSNumber] = [0]
        var times: [NSNumber] = [0]
        for s in spans {
            let mid = (s.start + s.end) / 2
            values += [0, 1, 0]
            times += [NSNumber(value: s.start / total), NSNumber(value: mid / total), NSNumber(value: s.end / total)]
        }
        values.append(0); times.append(1)
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = values
        a.keyTimes = times
        a.duration = total
        a.beginTime = AVCoreAnimationBeginTimeAtZero
        a.isRemovedOnCompletion = false
        a.fillMode = .both
        layer.add(a, forKey: "flash")
        return layer
    }
}
