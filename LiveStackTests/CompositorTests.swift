import XCTest
import CoreImage
import AVFoundation
@testable import LiveStack
import LiveStackCore

/// Drives the compositor directly with synthetic source frames, without the export pipeline in the way.
final class CompositorTests: XCTestCase {
    let context = CIContext()

    func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: CGSize) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: CGRect(origin: .zero, size: size))
    }

    func rendered(_ image: CIImage, size: CGSize) -> CGImage {
        context.createCGImage(image, from: CGRect(origin: .zero, size: size))!
    }

    func makePlan(settings: ReelSettings, stickers: [Sticker] = []) -> ReelRenderPlan {
        let timeline = ReelTimeline.build(durations: [2, 2], transition: settings.transition, transitionLength: settings.transitionLength)
        let art = stickers.compactMap { s -> ReelRenderPlan.StickerArt? in s.image.cgImage.map { ReelRenderPlan.StickerArt(image: CIImage(cgImage: $0), placement: s.placement, aspect: s.aspect) } }
        let items = (0..<2).map { i in
            ReelRenderPlan.Item(trackID: CMPersistentTrackID(i + 1), timeline: timeline.items[i], upright: .identity, naturalSize: CGSize(width: 480, height: 640),
                                orientedSize: Size(width: 480, height: 640), motion: .still, stickers: i == 0 ? art : [])
        }
        return ReelRenderPlan(items: items, timeline: timeline, settings: settings, renderSize: CGSize(width: 540, height: 540))
    }

    func testTitleArtHasBrightPixels() {
        let cg = TitleArt.render("Lisbon", width: 464, fontSize: 46)
        XCTAssertNotNil(cg)
        let c = SyntheticVideo.averageColor(of: cg!)
        XCTAssertGreaterThan(c.r + c.g + c.b, 60, "white text shows up in the average: \(c)")
    }

    func testTitleIsDrawnOverTheFirstLoop() {
        let settings = ReelSettings(frame: .square, fit: .fill, transition: .cut, transitionLength: 0, title: "Lisbon", showTitle: true, frameRate: 10)
        let plan = makePlan(settings: settings)
        XCTAssertNotNil(plan.titleImage)
        let instr = ReelInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), itemIndices: [0], plan: plan)
        let size = plan.renderSize
        let withTitle = rendered(ReelCompositor.render(instruction: instr, time: 0.9) { _ in self.solid(0.2, 0.1, 0.1, size: CGSize(width: 480, height: 640)) }, size: size)
        let before = rendered(ReelCompositor.render(instruction: instr, time: 0.0) { _ in self.solid(0.2, 0.1, 0.1, size: CGSize(width: 480, height: 640)) }, size: size)
        let region = CGRect(x: plan.titleOrigin.x / size.width, y: plan.titleOrigin.y / size.height, width: min(1, plan.titleImage!.extent.width / size.width), height: min(1, plan.titleImage!.extent.height / size.height))
        let a = SyntheticVideo.averageColor(of: withTitle, region: region)
        let b = SyntheticVideo.averageColor(of: before, region: region)
        XCTAssertGreaterThan(a.r + a.g + a.b, b.r + b.g + b.b + 30, "title region brighter at 0.9 s than at 0 s: \(a) vs \(b)")
        // Outside the title region the frame is untouched.
        let top = SyntheticVideo.averageColor(of: withTitle, region: CGRect(x: 0, y: 0, width: 1, height: 0.3))
        XCTAssertEqual(top.r, 51, accuracy: 6); XCTAssertEqual(top.g, 25.5, accuracy: 6)
    }

    func testFillTransformCoversTheFrame() {
        let plan = makePlan(settings: ReelSettings(frame: .square, fit: .fill, transition: .cut, transitionLength: 0, frameRate: 10))
        let instr = ReelInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), itemIndices: [0], plan: plan)
        let img = rendered(ReelCompositor.render(instruction: instr, time: 0.5) { _ in self.solid(0, 0.6, 0.2, size: CGSize(width: 480, height: 640)) }, size: plan.renderSize)
        for region in [CGRect(x: 0, y: 0, width: 0.1, height: 0.1), CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1), CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)] {
            let c = SyntheticVideo.averageColor(of: img, region: region)
            XCTAssertEqual(c.g, 153, accuracy: 8, "green fills \(region): \(c)")
            XCTAssertLessThan(c.r, 10)
        }
    }

    func testSlideMidpointShowsBothLoops() {
        let plan = makePlan(settings: ReelSettings(frame: .square, fit: .fill, transition: .slide, transitionLength: 0.5, frameRate: 10))
        let a = plan.timeline.items[0], b = plan.timeline.items[1]
        let mid = b.start + (a.end - b.start) / 2
        let instr = ReelInstruction(timeRange: CMTimeRange(start: CMTime(seconds: b.start, preferredTimescale: 600), end: CMTime(seconds: a.end, preferredTimescale: 600)), itemIndices: [0, 1], plan: plan)
        let img = rendered(ReelCompositor.render(instruction: instr, time: mid) { id in id == 1 ? self.solid(1, 0, 0, size: CGSize(width: 480, height: 640)) : self.solid(0, 0, 1, size: CGSize(width: 480, height: 640)) }, size: plan.renderSize)
        let left = SyntheticVideo.averageColor(of: img, region: CGRect(x: 0, y: 0.4, width: 0.4, height: 0.2))
        let right = SyntheticVideo.averageColor(of: img, region: CGRect(x: 0.6, y: 0.4, width: 0.4, height: 0.2))
        XCTAssertGreaterThan(left.r, 200, "outgoing red on the left: \(left)"); XCTAssertLessThan(left.b, 40)
        XCTAssertGreaterThan(right.b, 200, "incoming blue on the right: \(right)"); XCTAssertLessThan(right.r, 40)
    }

    func testStickerPopsInAtItsPlace() {
        UIGraphicsBeginImageContext(CGSize(width: 50, height: 50))
        UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 50, height: 50))
        let white = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        let sticker = Sticker(image: white, placement: StickerPlacement(x: 0.25, y: 0.25, size: 0.2, rotationDegrees: 0, animation: .pop))
        let plan = makePlan(settings: ReelSettings(frame: .square, fit: .fill, transition: .cut, transitionLength: 0, frameRate: 10), stickers: [sticker])
        let instr = ReelInstruction(timeRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600)), itemIndices: [0], plan: plan)
        let src: (CMPersistentTrackID) -> CIImage? = { _ in self.solid(0, 0, 0.5, size: CGSize(width: 480, height: 640)) }
        let early = rendered(ReelCompositor.render(instruction: instr, time: 0.0, source: src), size: plan.renderSize)
        let late = rendered(ReelCompositor.render(instruction: instr, time: 1.0, source: src), size: plan.renderSize)
        let spot = CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)
        let e = SyntheticVideo.averageColor(of: early, region: spot), l = SyntheticVideo.averageColor(of: late, region: spot)
        XCTAssertLessThan(e.r, 30, "sticker not yet popped at 0 s: \(e)")
        XCTAssertGreaterThan(l.r, 220, "sticker fully shown at 1 s: \(l)")
    }
}
