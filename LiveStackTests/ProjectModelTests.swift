import XCTest
@testable import LiveStack
import LiveStackCore

@MainActor
final class ProjectModelTests: XCTestCase {
    func testImportAutoCutsAndBuildsReel() async throws {
        let model = ProjectModel()
        let src = try SyntheticVideo.write(to: SyntheticVideo.tempURL("import"), scenes: [.init(hue: 0.2, seconds: 3, motion: 1.5...2.0)])
        await model.importVideoFile(src, name: "Test")
        XCTAssertEqual(model.clips.count, 1)
        let clip = model.clips[0]
        XCTAssertNotNil(clip.loopAsset)
        XCTAssertEqual(clip.spec.windowLength, 0.53, accuracy: 1e-9)
        XCTAssertEqual(clip.spec.repeats, 3); XCTAssertEqual(clip.spec.speed, 1.5)
        XCTAssertGreaterThanOrEqual(clip.spec.windowStart, 1.3)
        // Reel builds after a short debounce.
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNotNil(model.reel)
        XCTAssertEqual(model.reel!.duration, clip.loopAsset!.duration, accuracy: 0.01)
    }

    func testShuffleResetAndSpecUpdatesRerender() async throws {
        let model = ProjectModel()
        for hue in [0.1, 0.5] {
            let src = try SyntheticVideo.write(to: SyntheticVideo.tempURL("two"), scenes: [.init(hue: hue, seconds: 2, motion: 0.5...1.0)])
            await model.importVideoFile(src)
        }
        XCTAssertEqual(model.clips.count, 2)
        let before = model.clips.map(\.spec)
        model.resetAll()
        XCTAssertTrue(model.clips.allSatisfy { $0.spec.windowStart == 0 && $0.spec.repeats == 1 && $0.spec.speed == 1 })
        model.shuffle(seed: 99)
        XCTAssertNotEqual(model.clips.map(\.spec), before)
        XCTAssertTrue(model.clips.allSatisfy { $0.spec.windowStart + $0.spec.windowLength <= $0.sourceDuration + 1e-6 })
        // Wait for the debounced re-render, then the loop files reflect the new specs.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        for c in model.clips { XCTAssertEqual(c.loopAsset?.spec, c.spec) }
        model.remove(model.clips[0].id)
        XCTAssertEqual(model.clips.count, 1)
        model.removeAll()
        XCTAssertTrue(model.clips.isEmpty)
    }

    func testExportVideoAndGIF() async throws {
        let model = ProjectModel()
        let src = try SyntheticVideo.write(to: SyntheticVideo.tempURL("exp"), scenes: [.init(hue: 0.8, seconds: 2, motion: nil)])
        await model.importVideoFile(src)
        try await Task.sleep(nanoseconds: 600_000_000)
        let video = await model.exportVideo()
        XCTAssertNotNil(video)
        XCTAssertEqual(video?.pathExtension, "mp4")
        let gif = await model.exportLoopGIF(model.clips[0].id)
        XCTAssertNotNil(gif)
        XCTAssertGreaterThan(ReelExporter.gifFrameCount(at: gif!), 5)
    }
}
