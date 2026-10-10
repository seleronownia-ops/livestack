import XCTest
@testable import LiveStack
import LiveStackCore

final class MotionAnalyzerTests: XCTestCase {
    func testEnergyPeaksWhereTheCircleMoves() async throws {
        let src = try SyntheticVideo.write(to: SyntheticVideo.tempURL("motion"), scenes: [.init(hue: 0.3, seconds: 3, motion: 1.5...2.0)])
        let a = try await MotionAnalyzer.analyze(url: src)
        XCTAssertEqual(a.duration, 3, accuracy: 0.05)
        XCTAssertEqual(a.sourceFPS, 30, accuracy: 0.5)
        XCTAssertEqual(a.energy.count, 24, "8 samples per second over 3 s")
        XCTAssertEqual(a.filmstrip.count, MotionAnalyzer.filmstripCount)
        let still = a.energy[2...10].reduce(0, +) / 9
        let moving = a.energy[13...15].reduce(0, +) / 3
        XCTAssertGreaterThan(moving, still * 3 + 1, "moving stretch is clearly livelier: \(a.energy)")
        let spec = AutoCut.auto(energy: a.energy, energyFPS: MotionAnalyzer.samplesPerSecond, duration: a.duration, index: 0)
        XCTAssertGreaterThanOrEqual(spec.windowStart, 1.3)
        XCTAssertLessThanOrEqual(spec.windowStart + spec.windowLength, 2.3)
    }
}
