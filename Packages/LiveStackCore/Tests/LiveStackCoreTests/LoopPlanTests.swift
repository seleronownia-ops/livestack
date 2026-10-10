import XCTest
@testable import LiveStackCore

final class LoopPlanTests: XCTestCase {
    let fps = 30.0
    let duration = 3.0

    func testWindowTimesCoverExactlyTheWindow() {
        let spec = LoopSpec(windowStart: 1.0, windowLength: 0.5)
        let times = LoopPlan.windowTimes(spec: spec, sourceFPS: fps, sourceDuration: duration)
        XCTAssertEqual(times.count, 15)
        XCTAssertEqual(times.first!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(times.last!, 1.0 + 14.0 / 30.0, accuracy: 1e-9)
        for (a, b) in zip(times, times.dropFirst()) { XCTAssertEqual(b - a, 1.0 / 30.0, accuracy: 1e-9) }
    }

    func testWindowIsClampedToSource() {
        let spec = LoopSpec(windowStart: 2.8, windowLength: 1.0)
        let times = LoopPlan.windowTimes(spec: spec, sourceFPS: fps, sourceDuration: duration)
        XCTAssertGreaterThanOrEqual(times.count, 2)
        XCTAssertLessThan(times.last!, duration)
        XCTAssertGreaterThanOrEqual(times.first!, 0)
        XCTAssertEqual(times.first!, 2.0, accuracy: 1e-9, "window slides back so its full length fits")
    }

    func testBounceIsPalindromicAndRepeats() {
        let spec = LoopSpec(windowStart: 0, windowLength: 0.3, mode: .bounce, repeats: 2)
        let play = LoopPlan.playTimes(spec: spec, sourceFPS: fps, sourceDuration: duration)
        let fwd = LoopPlan.windowTimes(spec: spec, sourceFPS: fps, sourceDuration: duration)
        XCTAssertEqual(fwd.count, 9)
        XCTAssertEqual(play.count, (9 + 7) * 2)
        let one = Array(play.prefix(16))
        XCTAssertEqual(one[0], fwd[0]); XCTAssertEqual(one[8], fwd[8]); XCTAssertEqual(one[15], fwd[1])
        XCTAssertEqual(Array(play.suffix(16)), one, "second repeat is identical")
        XCTAssertLessThan(one[9], one[8], "after the peak the frames step backwards")
        XCTAssertEqual(one[1...7].map { $0 }, one[9...15].reversed().map { $0 }, "the way back mirrors the way out")
    }

    func testForwardAndReverse() {
        let spec = LoopSpec(windowStart: 0.5, windowLength: 0.2, mode: .forward)
        let fwd = LoopPlan.playTimes(spec: spec, sourceFPS: fps, sourceDuration: duration)
        XCTAssertEqual(fwd, fwd.sorted())
        var rev = spec; rev.mode = .reverse
        XCTAssertEqual(LoopPlan.playTimes(spec: rev, sourceFPS: fps, sourceDuration: duration), fwd.reversed())
    }

    func testDurationFollowsSpeedAndRepeats() {
        let base = LoopSpec(windowStart: 0, windowLength: 0.5, mode: .bounce, speed: 1, repeats: 1)
        let d1 = LoopPlan.duration(spec: base, sourceFPS: fps, sourceDuration: duration)
        XCTAssertEqual(d1, Double(15 + 13) / 30.0, accuracy: 1e-9)
        var fast = base; fast.speed = 2
        XCTAssertEqual(LoopPlan.duration(spec: fast, sourceFPS: fps, sourceDuration: duration), d1 / 2, accuracy: 1e-9)
        var thrice = base; thrice.repeats = 3
        XCTAssertEqual(LoopPlan.duration(spec: thrice, sourceFPS: fps, sourceDuration: duration), d1 * 3, accuracy: 1e-9)
    }

    func testTinySourceStillHasTwoDistinctFrames() {
        let spec = LoopSpec(windowStart: 0, windowLength: 1)
        let times = LoopPlan.windowTimes(spec: spec, sourceFPS: fps, sourceDuration: 0.04)
        XCTAssertEqual(times.count, 2)
        XCTAssertNotEqual(times[0], times[1])
        XCTAssertLessThan(times[1], 0.04)
    }

    func testMinimumWindowIsEnforced() {
        let spec = LoopSpec(windowStart: 1, windowLength: 0.01)
        XCTAssertEqual(LoopPlan.windowTimes(spec: spec, sourceFPS: fps, sourceDuration: duration).count, 9)
    }
}

final class PlayOrderTests: XCTestCase {
    func testPlayOrderShapes() {
        XCTAssertEqual(LoopPlan.playOrder(count: 4, mode: .bounce, repeats: 1), [0, 1, 2, 3, 2, 1])
        XCTAssertEqual(LoopPlan.playOrder(count: 4, mode: .forward, repeats: 2), [0, 1, 2, 3, 0, 1, 2, 3])
        XCTAssertEqual(LoopPlan.playOrder(count: 3, mode: .reverse, repeats: 1), [2, 1, 0])
        XCTAssertEqual(LoopPlan.playOrder(count: 2, mode: .bounce, repeats: 1), [0, 1])
        XCTAssertEqual(LoopPlan.playOrder(count: 0, mode: .bounce, repeats: 3), [])
    }

    func testPlayOrderMatchesPlayTimes() {
        let spec = LoopSpec(windowStart: 0.4, windowLength: 0.5, mode: .bounce, repeats: 2)
        let fwd = LoopPlan.windowTimes(spec: spec, sourceFPS: 30, sourceDuration: 3)
        let viaOrder = LoopPlan.playOrder(count: fwd.count, mode: .bounce, repeats: 2).map { fwd[$0] }
        XCTAssertEqual(viaOrder, LoopPlan.playTimes(spec: spec, sourceFPS: 30, sourceDuration: 3))
    }
}
