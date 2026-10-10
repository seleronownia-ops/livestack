import Foundation

/// How a loop plays its window of frames.
public enum LoopMode: String, Codable, CaseIterable, Sendable {
    case bounce, forward, reverse

    public var label: String {
        switch self {
        case .bounce: return "Bounce"
        case .forward: return "Forward"
        case .reverse: return "Reverse"
        }
    }
}

/// Slow Ken Burns style zoom applied across a loop.
public enum CameraMotion: String, Codable, CaseIterable, Sendable {
    case still, zoomIn, zoomOut

    public var label: String {
        switch self {
        case .still: return "Still"
        case .zoomIn: return "Zoom in"
        case .zoomOut: return "Zoom out"
        }
    }
}

public enum TransitionStyle: String, Codable, CaseIterable, Sendable {
    case cut, fade, slide, zoom, flash

    public var label: String { rawValue.capitalized }
}

public enum FitMode: String, Codable, CaseIterable, Sendable {
    case fill, fit

    public var label: String {
        switch self {
        case .fill: return "Crop to fill"
        case .fit: return "Fit on black"
        }
    }
}

public enum StickerAnimation: String, Codable, CaseIterable, Sendable {
    case still, pop, float, wiggle, drift

    public var label: String {
        switch self {
        case .still: return "Still"
        case .pop: return "Pop in"
        case .float: return "Float"
        case .wiggle: return "Wiggle"
        case .drift: return "Drift"
        }
    }
}

/// Output frame shapes. Width is always 1080.
public enum ReelFrame: String, Codable, CaseIterable, Sendable {
    case portrait = "9:16"
    case fourFive = "4:5"
    case square = "1:1"

    public var size: Size {
        switch self {
        case .portrait: return Size(width: 1080, height: 1920)
        case .fourFive: return Size(width: 1080, height: 1350)
        case .square: return Size(width: 1080, height: 1080)
        }
    }
}

public struct Size: Equatable, Codable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

/// Everything that decides how one Live Photo becomes a loop.
public struct LoopSpec: Equatable, Codable, Sendable {
    /// Start of the bounce window, seconds into the source video.
    public var windowStart: Double
    /// Length of the window in seconds.
    public var windowLength: Double
    public var mode: LoopMode
    public var speed: Double
    public var repeats: Int
    public var motion: CameraMotion

    public init(windowStart: Double, windowLength: Double, mode: LoopMode = .bounce, speed: Double = 1, repeats: Int = 1, motion: CameraMotion = .still) {
        self.windowStart = windowStart
        self.windowLength = windowLength
        self.mode = mode
        self.speed = speed
        self.repeats = repeats
        self.motion = motion
    }

    public static let speeds: [Double] = [0.5, 1, 1.5, 2]
    public static let repeatOptions: [Int] = [1, 2, 3, 4, 6]
    public static let minimumWindow: Double = 0.3
    public static let maximumWindow: Double = 1.5

    /// A copy whose window is clamped inside a source of the given duration.
    public func clamped(toSourceDuration duration: Double) -> LoopSpec {
        var s = self
        s.windowLength = min(max(s.windowLength, min(LoopSpec.minimumWindow, duration)), duration)
        s.windowStart = min(max(s.windowStart, 0), max(0, duration - s.windowLength))
        s.repeats = max(1, s.repeats)
        s.speed = max(0.25, s.speed)
        return s
    }
}

/// Reel wide settings.
public struct ReelSettings: Equatable, Codable, Sendable {
    public var frame: ReelFrame
    public var fit: FitMode
    public var transition: TransitionStyle
    public var transitionLength: Double
    public var title: String
    public var showTitle: Bool
    public var frameRate: Double

    public init(frame: ReelFrame = .portrait, fit: FitMode = .fill, transition: TransitionStyle = .slide, transitionLength: Double = 0.35, title: String = "", showTitle: Bool = false, frameRate: Double = 30) {
        self.frame = frame
        self.fit = fit
        self.transition = transition
        self.transitionLength = transitionLength
        self.title = title
        self.showTitle = showTitle
        self.frameRate = frameRate
    }

    public static let transitionLengths: [Double] = [0.2, 0.35, 0.5]
}
