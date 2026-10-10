import XCTest
import AVFoundation
@testable import LiveStack
import LiveStackCore

final class ReelComposerTests: XCTestCase {
    /// Three loops with distinct hues: red-ish, green-ish, blue-ish.
    func makeLoops() async throws -> [LoopAsset] {
        var loops: [LoopAsset] = []
        for hue in [0.0, 0.33, 0.66] {
            let src = try SyntheticVideo.write(to: SyntheticVideo.tempURL("scene"), scenes: [.init(hue: hue, seconds: 1.5, motion: nil)])
            loops.append(try await LoopRenderer.shared.render(sourceURL: src, spec: LoopSpec(windowStart: 0.2, windowLength: 0.5, mode: .bounce, speed: 1, repeats: 2)))
        }
        return loops
    }

    func testCompositionMatchesTimeline() async throws {
        let loops = try await makeLoops()
        let settings = ReelSettings(frame: .portrait, fit: .fill, transition: .slide, transitionLength: 0.35)
        let reel = try await ReelComposer.compose(inputs: loops.map { .init(asset: $0, stickers: []) }, settings: settings)
        let expected = ReelTimeline.build(durations: loops.map(\.duration), transition: .slide, transitionLength: 0.35)
        XCTAssertEqual(reel.timeline, expected)
        let compDuration = try await reel.composition.load(.duration).seconds
        XCTAssertEqual(compDuration, expected.total, accuracy: 0.05)
        XCTAssertEqual(reel.videoComposition.renderSize, CGSize(width: 1080, height: 1920))
        XCTAssertEqual(reel.videoComposition.instructions.count, expected.spans().count)
        XCTAssertEqual(reel.composition.tracks(withMediaType: .video).count, 2)
    }

    func testExportedReelShowsEachLoopInOrder() async throws {
        let loops = try await makeLoops()
        let settings = ReelSettings(frame: .square, fit: .fill, transition: .fade, transitionLength: 0.3)
        let reel = try await ReelComposer.compose(inputs: loops.map { .init(asset: $0, stickers: []) }, settings: settings)
        let out = try await ReelExporter.exportVideo(reel, to: SyntheticVideo.tempURL("reel", "mp4"))
        let exported = AVURLAsset(url: out)
        XCTAssertEqual(try await exported.load(.duration).seconds, reel.duration, accuracy: 0.1)
        let track = try await exported.loadTracks(withMediaType: .video).first!
        XCTAssertEqual(try await track.load(.naturalSize), CGSize(width: 1080, height: 1080))
        for (i, item) in reel.timeline.items.enumerated() {
            let c = try await SyntheticVideo.averageColor(of: out, at: item.start + item.duration / 2)
            let hue = SyntheticVideo.hue(c)
            XCTAssertLessThan(SyntheticVideo.hueDistance(hue, [0.0, 0.33, 0.66][i]), 0.08, "loop \(i) shows its own colour at its midpoint, got hue \(hue)")
        }
        // Inside the first fade the picture is a blend of both colours: neither hue matches closely.
        let b = reel.timeline.items[1]
        let mid = b.start + (reel.timeline.items[0].end - b.start) / 2
        let blend = try await SyntheticVideo.averageColor(of: out, at: mid)
        let blendHue = SyntheticVideo.hue(blend)
        XCTAssertGreaterThan(SyntheticVideo.hueDistance(blendHue, 0.0), 0.03)
        XCTAssertGreaterThan(SyntheticVideo.hueDistance(blendHue, 0.33), 0.03)
    }

    func testSlideTransitionShowsBothSides() async throws {
        let loops = try await makeLoops()
        let settings = ReelSettings(frame: .square, fit: .fill, transition: .slide, transitionLength: 0.5)
        let reel = try await ReelComposer.compose(inputs: loops.map { .init(asset: $0, stickers: []) }, settings: settings)
        let out = try await ReelExporter.exportVideo(reel, to: SyntheticVideo.tempURL("slide", "mp4"))
        let b = reel.timeline.items[1]
        let mid = b.start + (reel.timeline.items[0].end - b.start) / 2
        let left = try await SyntheticVideo.averageColor(of: out, at: mid, region: CGRect(x: 0, y: 0, width: 0.4, height: 1))
        let right = try await SyntheticVideo.averageColor(of: out, at: mid, region: CGRect(x: 0.6, y: 0, width: 0.4, height: 1))
        XCTAssertLessThan(SyntheticVideo.hueDistance(SyntheticVideo.hue(left), 0.0), 0.08, "outgoing loop on the left")
        XCTAssertLessThan(SyntheticVideo.hueDistance(SyntheticVideo.hue(right), 0.33), 0.08, "incoming loop on the right")
    }

    func testStickerAndTitleAreBakedIntoExport() async throws {
        let loops = try await makeLoops()
        // A solid white sticker in the top-left quarter of the first loop; no animation so it is fully visible.
        UIGraphicsBeginImageContext(CGSize(width: 100, height: 100))
        UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let white = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        let sticker = Sticker(image: white, placement: StickerPlacement(x: 0.2, y: 0.2, size: 0.3, rotationDegrees: 0, animation: .still))
        let settings = ReelSettings(frame: .square, fit: .fill, transition: .cut, transitionLength: 0, title: "Lisbon", showTitle: true)
        let inputs = loops.enumerated().map { ReelComposer.Input(asset: $0.element, stickers: $0.offset == 0 ? [sticker] : []) }
        let reel = try await ReelComposer.compose(inputs: inputs, settings: settings)
        let out = try await ReelExporter.exportVideo(reel, to: SyntheticVideo.tempURL("stick", "mp4"))
        let items = reel.timeline.items
        let onFirst = try await SyntheticVideo.averageColor(of: out, at: items[0].start + items[0].duration * 0.5, region: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertGreaterThan(onFirst.r + onFirst.g + onFirst.b, 3 * 200, "white sticker covers the top-left of loop 1: \(onFirst)")
        let onSecond = try await SyntheticVideo.averageColor(of: out, at: items[1].start + items[1].duration * 0.5, region: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        XCTAssertLessThan(onSecond.r + onSecond.g + onSecond.b, 3 * 200, "sticker is gone on loop 2: \(onSecond)")
        // Title band (lower left) on loop 1 contains white text pixels, so it is brighter than the same band on loop 2.
        let titleBand1 = try await SyntheticVideo.averageColor(of: out, at: items[0].start + 0.9, region: CGRect(x: 0.05, y: 0.70, width: 0.6, height: 0.14))
        let titleBand2 = try await SyntheticVideo.averageColor(of: out, at: items[2].start + items[2].duration * 0.5, region: CGRect(x: 0.05, y: 0.70, width: 0.6, height: 0.14))
        XCTAssertGreaterThan(titleBand1.r + titleBand1.g + titleBand1.b, titleBand2.r + titleBand2.g + titleBand2.b + 30, "title brightens the band on loop 1: \(titleBand1) vs \(titleBand2)")
    }

    func testFlashTransitionPeaksWhite() async throws {
        let loops = try await makeLoops()
        let settings = ReelSettings(frame: .square, fit: .fill, transition: .flash, transitionLength: 0.5)
        let reel = try await ReelComposer.compose(inputs: loops.map { .init(asset: $0, stickers: []) }, settings: settings)
        let out = try await ReelExporter.exportVideo(reel, to: SyntheticVideo.tempURL("flash", "mp4"))
        let b = reel.timeline.items[1]
        let mid = b.start + (reel.timeline.items[0].end - b.start) / 2
        let c = try await SyntheticVideo.averageColor(of: out, at: mid)
        XCTAssertGreaterThan(c.r + c.g + c.b, 3 * 215, "frame is near white at the flash peak: \(c)")
    }

    func testGIFExport() async throws {
        let loops = try await makeLoops()
        let gif = try await ReelExporter.makeGIF(from: loops[0].url, fps: 12, maxSide: 240, to: SyntheticVideo.tempURL("loop", "gif"))
        let frames = ReelExporter.gifFrameCount(at: gif)
        XCTAssertEqual(frames, Int((loops[0].duration * 12).rounded(.down)), accuracy: 1)
        XCTAssertGreaterThan(try Data(contentsOf: gif).count, 1000)
    }

    func testEmptyReel() async throws {
        let reel = try await ReelComposer.compose(inputs: [], settings: ReelSettings())
        XCTAssertEqual(reel.duration, 0)
        XCTAssertTrue(reel.timeline.items.isEmpty)
    }
}
