import XCTest
@testable import LiveStackCore

final class AutoCutTests: XCTestCase {
    /// 3 s at 8 samples/s: flat energy except a lively stretch from 1.5 s to 2.0 s.
    func makeEnergy() -> [Double] {
        (0..<24).map { i in (12...15).contains(i) ? 20.0 : 4.0 }
    }

    func testBestWindowLandsOnTheLivelyPart() {
        let start = AutoCut.bestWindow(energy: makeEnergy(), energyFPS: 8, duration: 3, windowLength: 0.5)
        XCTAssertEqual(start, 1.5, accuracy: 1e-9)
    }

    func testAutoSpecDefaults() {
        let spec = AutoCut.auto(energy: makeEnergy(), energyFPS: 8, duration: 3, index: 1)
        XCTAssertEqual(spec.windowStart, 1.5, accuracy: 1e-9)
        XCTAssertEqual(spec.windowLength, 0.53, accuracy: 1e-9)
        XCTAssertEqual(spec.mode, .bounce); XCTAssertEqual(spec.speed, 1.5); XCTAssertEqual(spec.repeats, 3); XCTAssertEqual(spec.motion, .zoomOut)
        XCTAssertEqual(AutoCut.auto(energy: makeEnergy(), energyFPS: 8, duration: 3, index: 0).motion, .zoomIn)
    }

    func testAutoOnShortClipIsClamped() {
        let spec = AutoCut.auto(energy: [3, 3, 3], energyFPS: 8, duration: 0.3, index: 0)
        XCTAssertEqual(spec.windowStart, 0); XCTAssertEqual(spec.windowLength, 0.3, accuracy: 1e-9)
    }

    func testSpikesAreTamed() {
        let e = MotionEnergy.tameSpikes([2, 2, 2, 200, 2, 2])
        XCTAssertEqual(e[3], 6, accuracy: 1e-9)
        XCTAssertEqual(e[0], 2)
    }

    func testEnergyFromFrames() {
        let still: [UInt8] = Array(repeating: 100, count: 16)
        var moved = still; moved[0] = 116; moved[1] = 84
        let e = MotionEnergy.energy(frames: [still, still, moved, moved])
        XCTAssertEqual(e.count, 4)
        XCTAssertEqual(e[1], 0); XCTAssertEqual(e[2], 2, accuracy: 1e-9); XCTAssertEqual(e[3], 0)
        XCTAssertEqual(e[0], e[1])
    }

    func testShuffleIsDeterministicAndInBounds() {
        var r1 = SeededRNG(seed: 42), r2 = SeededRNG(seed: 42)
        let a = AutoCut.shuffle(energy: makeEnergy(), energyFPS: 8, duration: 3, rng: &r1)
        let b = AutoCut.shuffle(energy: makeEnergy(), energyFPS: 8, duration: 3, rng: &r2)
        XCTAssertEqual(a, b)
        for seed in 1...200 {
            var r = SeededRNG(seed: UInt64(seed))
            let s = AutoCut.shuffle(energy: makeEnergy(), energyFPS: 8, duration: 3, rng: &r)
            XCTAssertGreaterThanOrEqual(s.windowStart, 0)
            XCTAssertLessThanOrEqual(s.windowStart + s.windowLength, 3 + 1e-9)
            XCTAssertGreaterThanOrEqual(s.windowLength, 0.35 - 1e-9); XCTAssertLessThanOrEqual(s.windowLength, 0.8 + 1e-9)
            XCTAssertTrue(LoopSpec.speeds.contains(s.speed)); XCTAssertTrue([2, 3, 4].contains(s.repeats))
        }
    }

    func testShuffleFavoursLivelyWindows() {
        var hits = 0
        for seed in 1...300 {
            var r = SeededRNG(seed: UInt64(seed))
            let s = AutoCut.shuffle(energy: makeEnergy(), energyFPS: 8, duration: 3, rng: &r)
            if s.windowStart + s.windowLength > 1.5 && s.windowStart < 2.0 { hits += 1 }
        }
        XCTAssertGreaterThan(hits, 240, "most shuffles overlap the lively stretch, got \(hits)")
    }

    func testShuffleOrderIsAPermutation() {
        var r = SeededRNG(seed: 7)
        let order = AutoCut.shuffleOrder(count: 9, rng: &r)
        XCTAssertEqual(order.sorted(), Array(0..<9))
        XCTAssertNotEqual(order, Array(0..<9))
    }

    func testFullSpec() {
        let f = AutoCut.full(duration: 2.9)
        XCTAssertEqual(f.windowStart, 0); XCTAssertEqual(f.windowLength, 2.9); XCTAssertEqual(f.repeats, 1); XCTAssertEqual(f.speed, 1)
    }

    func testClampedSpec() {
        let s = LoopSpec(windowStart: 5, windowLength: 0.1, repeats: 0).clamped(toSourceDuration: 3)
        XCTAssertEqual(s.windowLength, 0.3, accuracy: 1e-9); XCTAssertEqual(s.windowStart, 2.7, accuracy: 1e-9); XCTAssertEqual(s.repeats, 1)
    }
}
