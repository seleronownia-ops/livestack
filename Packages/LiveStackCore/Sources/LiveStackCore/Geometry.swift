import Foundation

/// A 2D affine transform that does not depend on CoreGraphics, so the maths can be tested anywhere.
public struct Transform2D: Equatable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double
    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    public static let identity = Transform2D()
    public static func translation(_ x: Double, _ y: Double) -> Transform2D { Transform2D(tx: x, ty: y) }
    public static func scale(_ sx: Double, _ sy: Double) -> Transform2D { Transform2D(a: sx, d: sy) }

    /// `self` applied first, then `other` (same convention as CGAffineTransform.concatenating).
    public func concatenating(_ o: Transform2D) -> Transform2D {
        Transform2D(
            a: a * o.a + b * o.c, b: a * o.b + b * o.d,
            c: c * o.a + d * o.c, d: c * o.b + d * o.d,
            tx: tx * o.a + ty * o.c + o.tx, ty: tx * o.b + ty * o.d + o.ty)
    }
    public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }
}

public enum FitMath {
    /// Scale factor that makes a source of `source` size fill or fit a `render` frame.
    public static func baseScale(source: Size, render: Size, mode: FitMode) -> Double {
        let sx = render.width / source.width, sy = render.height / source.height
        return mode == .fill ? max(sx, sy) : min(sx, sy)
    }

    /// Maps the oriented source rectangle (origin top-left, size `source`) into the render frame, centred,
    /// then zooms about the frame centre and shifts horizontally by `offsetX` (a fraction of the frame width).
    public static func transform(source: Size, render: Size, mode: FitMode, zoom: Double = 1, offsetX: Double = 0) -> Transform2D {
        let s = baseScale(source: source, render: render, mode: mode) * zoom
        let w = source.width * s, h = source.height * s
        let tx = (render.width - w) / 2 + offsetX * render.width
        let ty = (render.height - h) / 2
        return Transform2D.scale(s, s).concatenating(.translation(tx, ty))
    }

    /// Ken Burns zoom at `progress` (0...1) through a loop.
    public static func zoomFactor(motion: CameraMotion, progress: Double) -> Double {
        let q = min(max(progress, 0), 1)
        switch motion {
        case .still: return 1
        case .zoomIn: return 1 + 0.08 * q
        case .zoomOut: return 1.08 - 0.08 * q
        }
    }
}

public enum Easing {
    public static func inOut(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        return u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
    }
    public static func outBack(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
    }
}

/// What each of the two loops looks like part way through a transition.
public struct LayerState: Equatable, Sendable {
    public var opacity: Double
    public var zoom: Double
    /// Horizontal shift as a fraction of the frame width.
    public var offsetX: Double
    public init(opacity: Double = 1, zoom: Double = 1, offsetX: Double = 0) { self.opacity = opacity; self.zoom = zoom; self.offsetX = offsetX }
}

public enum TransitionMath {
    /// `rawProgress` runs 0...1 across the overlap. Returns outgoing and incoming layer states.
    public static func states(style: TransitionStyle, rawProgress: Double) -> (outgoing: LayerState, incoming: LayerState) {
        let raw = min(max(rawProgress, 0), 1)
        let p = Easing.inOut(raw)
        switch style {
        case .cut:
            return raw < 0.5 ? (LayerState(), LayerState(opacity: 0)) : (LayerState(opacity: 0), LayerState())
        case .fade:
            return (LayerState(), LayerState(opacity: p))
        case .slide:
            return (LayerState(offsetX: -p), LayerState(offsetX: 1 - p))
        case .zoom:
            return (LayerState(opacity: 1 - p, zoom: 1 + 0.35 * p), LayerState(zoom: 1.25 - 0.25 * p))
        case .flash:
            return raw < 0.5 ? (LayerState(), LayerState(opacity: 0)) : (LayerState(opacity: 0), LayerState())
        }
    }

    /// Opacity of the white flash layer during a flash transition.
    public static func flashOpacity(rawProgress: Double) -> Double {
        let raw = min(max(rawProgress, 0), 1)
        return pow(1 - abs(2 * raw - 1), 0.7)
    }

    /// Incoming layer drawn above the outgoing one?
    public static func incomingOnTop(style: TransitionStyle) -> Bool { style != .zoom }
}

/// Sticker placement over a loop, in frame fractions.
public struct StickerPlacement: Equatable, Codable, Sendable {
    /// Centre, as fractions of the frame width and height.
    public var x: Double
    public var y: Double
    /// Width as a fraction of the frame width.
    public var size: Double
    public var rotationDegrees: Double
    public var animation: StickerAnimation
    public init(x: Double = 0.5, y: Double = 0.62, size: Double = 0.38, rotationDegrees: Double = 0, animation: StickerAnimation = .pop) {
        self.x = x; self.y = y; self.size = size; self.rotationDegrees = rotationDegrees; self.animation = animation
    }
}

public struct StickerPose: Equatable, Sendable {
    public var scale: Double
    public var dx: Double
    public var dy: Double
    public var rotationDegrees: Double
}

public enum StickerMath {
    /// Pose at `tau` seconds into the loop, `progress` 0...1 through it. Offsets are frame fractions.
    public static func pose(_ p: StickerPlacement, tau: Double, progress: Double) -> StickerPose {
        var pose = StickerPose(scale: 1, dx: 0, dy: 0, rotationDegrees: p.rotationDegrees)
        switch p.animation {
        case .still: break
        case .pop: pose.scale = Easing.outBack(min(1, tau / 0.45))
        case .float: pose.dy = sin(tau * 2 * .pi * 0.8) * 0.02
        case .wiggle: pose.rotationDegrees += sin(tau * 2 * .pi * 2.5) * 7
        case .drift: pose.dx = (min(max(progress, 0), 1) - 0.5) * 0.14
        }
        return pose
    }
}
