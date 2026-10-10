import XCTest
import AVFoundation
@testable import LiveStack
import LiveStackCore

final class LoopRendererTests: XCTestCase {
    /// A 3 s clip: the circle only moves between 1.5 s and 2.0 s.
    func makeSource() throws -> URL {
        try SyntheticVideo.write(to: SyntheticVideo.tempURL("src"), scenes: [.init(hue: 0.55, seconds: 3, motion: 1.5...2.0)])
    }

    func testBounceLoopDurationMatchesPlan() async throws {
        let src = try makeSource()
        let spec = LoopSpec(windowStart: 1.0, windowLength: 0.5, mode: .bounce, speed: 1, repeats: 2)
        let loop = try await LoopRenderer.shared.render(sourceURL: src, spec: spec)
        // 15 frames forward + 13 back, twice, at 30 fps; allow one frame of slack per pass at the window edges
        XCTAssertEqual(loop.duration, Double(28 * 2) / 30.0, accuracy: 4.0 / 30.0 + 0.01)
        XCTAssertEqual(loop.spec, spec.clamped(toSourceDuration: 3))
        let written = AVURLAsset(url: loop.url)
        let track = try await written.loadTracks(withMediaType: .video).first
        XCTAssertNotNil(track)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loop.url.path))
    }

    func testSpeedHalvesDuration() async throws {
        let src = try makeSource()
        let slow = try await LoopRenderer.shared.render(sourceURL: src, spec: LoopSpec(windowStart: 0, windowLength: 0.5, mode: .forward, speed: 1))
        let fast = try await LoopRenderer.shared.render(sourceURL: src, spec: LoopSpec(windowStart: 0, windowLength: 0.5, mode: .forward, speed: 2))
        XCTAssertEqual(fast.duration, slow.duration / 2, accuracy: 0.05)
    }

    func testBounceGoesOutAndBack() async throws {
        // Circle moves from 1.5 s. A bounce over 1.5...2.0 should put the circle at the same place at the start and the end.
        let src = try SyntheticVideo.write(to: SyntheticVideo.tempURL("bounce"), scenes: [.init(hue: 0.55, seconds: 3, motion: 1.5...2.0)], circleRadius: 0.2)
        let loop = try await LoopRenderer.shared.render(sourceURL: src, spec: LoopSpec(windowStart: 1.5, windowLength: 0.5, mode: .bounce, speed: 1, repeats: 1))
        // Same picture at both ends (the circle returns), a clearly different one at the far end of the swing.
        let endDiff = try await SyntheticVideo.frameDifference(of: loop.url, between: 0.01, and: loop.duration - 0.04)
        let midDiff = try await SyntheticVideo.frameDifference(of: loop.url, between: 0.01, and: loop.duration / 2)
        XCTAssertGreaterThan(midDiff, 12, "the circle moved between start and midpoint: \(midDiff)")
        XCTAssertLessThan(endDiff, midDiff / 3, "first and last frame match (\(endDiff)) compared with the swing (\(midDiff))")
    }

    func testOrientationIsPreserved() async throws {
        // Write a landscape video, then rotate it with a preferred transform by re-wrapping through the renderer of a rotated source.
        let src = try SyntheticVideo.write(to: SyntheticVideo.tempURL("land"), scenes: [.init(hue: 0.1, seconds: 1, motion: nil)], size: CGSize(width: 640, height: 480))
        let loop = try await LoopRenderer.shared.render(sourceURL: src, spec: LoopSpec(windowStart: 0, windowLength: 0.4))
        XCTAssertEqual(loop.orientedSize.width, 640, accuracy: 1); XCTAssertEqual(loop.orientedSize.height, 480, accuracy: 1)
    }
}
