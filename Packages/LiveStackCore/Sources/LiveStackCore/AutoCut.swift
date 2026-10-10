import Foundation

/// Deterministic xorshift generator so shuffles can be reproduced in tests.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    /// Uniform in 0..<1.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func pick<T>(_ options: [T]) -> T { options[Int(unit() * Double(options.count)) % options.count] }
}

public enum MotionEnergy {
    /// Mean absolute difference between neighbouring frames of equal length. Index 0 copies index 1.
    public static func energy(frames: [[UInt8]]) -> [Double] {
        guard frames.count > 1 else { return frames.isEmpty ? [] : [0] }
        var e = [0.0]
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            let n = min(a.count, b.count)
            guard n > 0 else { e.append(0); continue }
            var sum = 0
            for k in 0..<n { sum += abs(Int(a[k]) - Int(b[k])) }
            e.append(Double(sum) / Double(n))
        }
        e[0] = e[1]
        return tameSpikes(e)
    }

    /// Caps single frame spikes so one stray frame cannot dominate window scores.
    public static func tameSpikes(_ e: [Double]) -> [Double] {
        guard !e.isEmpty else { return e }
        let sorted = e.sorted()
        let median = sorted[sorted.count / 2]
        let cap = max(median * 3, 4)
        return e.map { min($0, cap) }
    }
}

public enum AutoCut {
    public struct Window: Equatable, Sendable {
        public let start: Double
        public let score: Double
    }

    /// Scores every window start (stepping by the energy sample period) by summed motion energy inside it.
    public static func windowScores(energy: [Double], energyFPS: Double, duration: Double, windowLength: Double) -> [Window] {
        guard !energy.isEmpty, energyFPS > 0 else { return [] }
        let step = 1.0 / energyFPS
        let samples = max(1, Int((windowLength * energyFPS).rounded()))
        var out: [Window] = []
        var a = 0
        while a + samples <= energy.count {
            let start = Double(a) * step
            if start + windowLength > duration + step * 0.5 { break }
            var sc = 0.0
            for i in a..<(a + samples) { sc += energy[i] }
            out.append(Window(start: start, score: sc))
            a += 1
        }
        if out.isEmpty { out.append(Window(start: 0, score: energy.reduce(0, +))) }
        return out
    }

    public static func bestWindow(energy: [Double], energyFPS: Double, duration: Double, windowLength: Double) -> Double {
        let scores = windowScores(energy: energy, energyFPS: energyFPS, duration: duration, windowLength: windowLength)
        return scores.max { $0.score < $1.score }?.start ?? 0
    }

    /// The default cut: liveliest half second, bounced three times at 1.5x, alternating zoom direction by position.
    public static func auto(energy: [Double], energyFPS: Double, duration: Double, index: Int) -> LoopSpec {
        let length = min(0.53, duration)
        let start = bestWindow(energy: energy, energyFPS: energyFPS, duration: duration, windowLength: length)
        return LoopSpec(windowStart: start, windowLength: length, mode: .bounce, speed: 1.5, repeats: 3, motion: index % 2 == 0 ? .zoomIn : .zoomOut)
            .clamped(toSourceDuration: duration)
    }

    /// A random but sensible cut: a window near the liveliest moments, random length, pace and motion.
    public static func shuffle(energy: [Double], energyFPS: Double, duration: Double, rng: inout SeededRNG) -> LoopSpec {
        let length = min(duration, 0.35 + rng.unit() * 0.45)
        let scores = windowScores(energy: energy, energyFPS: energyFPS, duration: duration, windowLength: length)
        let top = Array(scores.sorted { $0.score > $1.score }.prefix(max(3, scores.count * 3 / 10)))
        let start = top.isEmpty ? 0 : rng.pick(top).start
        let mode: LoopMode = rng.unit() < 0.15 ? .forward : .bounce
        return LoopSpec(windowStart: start, windowLength: length, mode: mode,
                        speed: rng.pick([1, 1.5, 1.5, 2]), repeats: rng.pick([2, 3, 3, 4]),
                        motion: rng.pick([.still, .zoomIn, .zoomOut]))
            .clamped(toSourceDuration: duration)
    }

    /// The whole clip, one bounce, normal speed.
    public static func full(duration: Double) -> LoopSpec {
        LoopSpec(windowStart: 0, windowLength: duration, mode: .bounce, speed: 1, repeats: 1, motion: .still)
    }

    /// Reel-level shuffle: new order plus a transition style and length.
    public static func shuffleOrder(count: Int, rng: inout SeededRNG) -> [Int] {
        var order = Array(0..<count)
        guard count > 1 else { return order }
        for i in stride(from: count - 1, to: 0, by: -1) {
            let j = Int(rng.unit() * Double(i + 1)) % (i + 1)
            order.swapAt(i, j)
        }
        return order
    }

    public static func shuffleTransition(rng: inout SeededRNG) -> (TransitionStyle, Double) {
        (rng.pick([.slide, .zoom, .flash, .fade, .slide]), rng.pick([0.2, 0.35]))
    }
}
