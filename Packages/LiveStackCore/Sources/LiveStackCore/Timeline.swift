import Foundation

public struct TimelineItem: Equatable, Sendable {
    public let index: Int
    public let start: Double
    public let duration: Double
    public var end: Double { start + duration }
    public init(index: Int, start: Double, duration: Double) { self.index = index; self.start = start; self.duration = duration }
    public func progress(at t: Double) -> Double { duration > 0 ? min(max((t - start) / duration, 0), 1) : 0 }
}

/// A stretch of the reel during which the same set of loops is on screen.
public struct TimelineSpan: Equatable, Sendable {
    public let start: Double
    public let end: Double
    /// Indices of the items visible during the span. Two items means a transition, listed outgoing first.
    public let items: [Int]
    public var duration: Double { end - start }
    public var isTransition: Bool { items.count == 2 }
}

/// Where each loop sits in the reel, with transitions overlapping neighbours.
public struct ReelTimeline: Equatable, Sendable {
    public let items: [TimelineItem]
    public let total: Double
    public let overlap: Double

    public static func build(durations: [Double], transition: TransitionStyle, transitionLength: Double) -> ReelTimeline {
        let requested = transition == .cut ? 0 : max(0, transitionLength)
        var items: [TimelineItem] = []
        var cursor = 0.0
        for (i, d) in durations.enumerated() {
            let dur = max(0, d)
            var start = cursor
            if i > 0 {
                let prev = items[i - 1]
                let allowed = min(requested, dur * 0.5, prev.duration * 0.5)
                start = max(0, cursor - allowed)
            }
            items.append(TimelineItem(index: i, start: start, duration: dur))
            cursor = start + dur
        }
        return ReelTimeline(items: items, total: cursor, overlap: requested)
    }

    /// The loop on screen at `t`, plus the incoming loop and eased-free progress when inside a transition.
    public func sample(at t: Double) -> (a: TimelineItem, b: TimelineItem?, progress: Double)? {
        guard !items.isEmpty else { return nil }
        let t = min(max(t, 0), max(0, total - 1e-6))
        var a: TimelineItem? = nil
        var b: TimelineItem? = nil
        for it in items where t >= it.start && t < it.end {
            if a == nil { a = it } else { b = it; break }
        }
        guard let first = a ?? items.last else { return nil }
        guard let second = b else { return (first, nil, 0) }
        let span = first.end - second.start
        let p = span > 0 ? min(max((t - second.start) / span, 0), 1) : 1
        return (first, second, p)
    }

    /// Non-overlapping spans that cover the reel, each with the loops visible in it.
    public func spans() -> [TimelineSpan] {
        guard !items.isEmpty else { return [] }
        var edges = Set<Double>()
        for it in items { edges.insert(it.start); edges.insert(it.end) }
        let sorted = edges.sorted()
        var out: [TimelineSpan] = []
        for k in 0..<(sorted.count - 1) {
            let s = sorted[k], e = sorted[k + 1]
            guard e - s > 1e-9 else { continue }
            let mid = (s + e) / 2
            let active = items.filter { $0.start <= mid && mid < $0.end }.sorted { $0.start < $1.start }.map { $0.index }
            guard !active.isEmpty else { continue }
            out.append(TimelineSpan(start: s, end: e, items: Array(active.prefix(2))))
        }
        return out
    }
}
