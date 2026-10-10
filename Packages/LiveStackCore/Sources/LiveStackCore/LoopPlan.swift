import Foundation

/// Turns a `LoopSpec` into the exact list of source timestamps to show, in order.
public enum LoopPlan {
    /// Source frame timestamps (seconds) for the window, forward order.
    public static func windowTimes(spec: LoopSpec, sourceFPS: Double, sourceDuration: Double) -> [Double] {
        let s = spec.clamped(toSourceDuration: sourceDuration)
        let step = 1.0 / sourceFPS
        let first = Int((s.windowStart * sourceFPS).rounded(.down))
        var times: [Double] = []
        var i = first
        while true {
            let t = Double(i) * step
            if t >= s.windowStart + s.windowLength - 1e-9 || t > sourceDuration - step * 0.5 { break }
            times.append(t)
            i += 1
        }
        if times.count < 2 {
            // Always keep at least two frames so a bounce has somewhere to go.
            let a = min(max(s.windowStart, 0), max(0, sourceDuration - step))
            times = [a, min(a + step, max(a, sourceDuration - step * 0.5))]
        }
        return times
    }

    /// Timestamps in play order after applying mode and repeats.
    public static func playTimes(spec: LoopSpec, sourceFPS: Double, sourceDuration: Double) -> [Double] {
        let fwd = windowTimes(spec: spec, sourceFPS: sourceFPS, sourceDuration: sourceDuration)
        let one: [Double]
        switch spec.mode {
        case .bounce:
            one = fwd.count > 2 ? fwd + fwd.dropFirst().dropLast().reversed() : fwd
        case .forward:
            one = fwd
        case .reverse:
            one = fwd.reversed()
        }
        var out: [Double] = []
        for _ in 0..<max(1, spec.repeats) { out.append(contentsOf: one) }
        return out
    }

    /// Seconds each played frame stays on screen.
    public static func frameDuration(spec: LoopSpec, sourceFPS: Double) -> Double {
        1.0 / (sourceFPS * max(0.25, spec.speed))
    }

    /// Length of the finished loop in seconds.
    public static func duration(spec: LoopSpec, sourceFPS: Double, sourceDuration: Double) -> Double {
        Double(playTimes(spec: spec, sourceFPS: sourceFPS, sourceDuration: sourceDuration).count) * frameDuration(spec: spec, sourceFPS: sourceFPS)
    }
}

public extension LoopPlan {
    /// Play order over `count` decoded window frames (indices), for renderers that work from real frames.
    static func playOrder(count: Int, mode: LoopMode, repeats: Int) -> [Int] {
        guard count > 0 else { return [] }
        let fwd = Array(0..<count)
        let one: [Int]
        switch mode {
        case .bounce: one = count > 2 ? fwd + fwd.dropFirst().dropLast().reversed() : fwd
        case .forward: one = fwd
        case .reverse: one = fwd.reversed()
        }
        var out: [Int] = []
        for _ in 0..<max(1, repeats) { out.append(contentsOf: one) }
        return out
    }
}
