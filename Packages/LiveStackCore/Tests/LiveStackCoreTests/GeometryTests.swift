import XCTest
@testable import LiveStackCore

final class GeometryTests: XCTestCase {
    let render = Size(width: 1080, height: 1920)

    func testFillCoversFrameAndIsCentred() {
        let src = Size(width: 1440, height: 1080)
        let t = FitMath.transform(source: src, render: render, mode: .fill)
        let tl = t.apply(x: 0, y: 0), br = t.apply(x: src.width, y: src.height)
        XCTAssertLessThanOrEqual(tl.x, 0); XCTAssertLessThanOrEqual(tl.y, 1e-9)
        XCTAssertGreaterThanOrEqual(br.x, render.width); XCTAssertGreaterThanOrEqual(br.y, render.height - 1e-9)
        let c = t.apply(x: src.width / 2, y: src.height / 2)
        XCTAssertEqual(c.x, 540, accuracy: 1e-9); XCTAssertEqual(c.y, 960, accuracy: 1e-9)
        XCTAssertEqual(br.y - tl.y, 1920, accuracy: 1e-9, "height is the binding dimension for a landscape source")
    }

    func testFitStaysInsideFrame() {
        let src = Size(width: 1440, height: 1080)
        let t = FitMath.transform(source: src, render: render, mode: .fit)
        let tl = t.apply(x: 0, y: 0), br = t.apply(x: src.width, y: src.height)
        XCTAssertEqual(tl.x, 0, accuracy: 1e-9); XCTAssertEqual(br.x, 1080, accuracy: 1e-9)
        XCTAssertGreaterThan(tl.y, 0); XCTAssertLessThan(br.y, 1920)
    }

    func testZoomKeepsCentreAndOffsetShifts() {
        let src = Size(width: 1080, height: 1440)
        let t = FitMath.transform(source: src, render: render, mode: .fill, zoom: 1.08, offsetX: -0.5)
        let c = t.apply(x: 540, y: 720)
        XCTAssertEqual(c.x, 540 - 0.5 * 1080, accuracy: 1e-9)
        XCTAssertEqual(c.y, 960, accuracy: 1e-9)
        let plain = FitMath.transform(source: src, render: render, mode: .fill)
        XCTAssertEqual(t.a / plain.a, 1.08, accuracy: 1e-9)
    }

    func testZoomFactors() {
        XCTAssertEqual(FitMath.zoomFactor(motion: .still, progress: 0.5), 1)
        XCTAssertEqual(FitMath.zoomFactor(motion: .zoomIn, progress: 0), 1)
        XCTAssertEqual(FitMath.zoomFactor(motion: .zoomIn, progress: 1), 1.08, accuracy: 1e-9)
        XCTAssertEqual(FitMath.zoomFactor(motion: .zoomOut, progress: 0), 1.08, accuracy: 1e-9)
        XCTAssertEqual(FitMath.zoomFactor(motion: .zoomOut, progress: 2), 1, accuracy: 1e-9)
    }

    func testConcatenationOrder() {
        let t = Transform2D.scale(2, 2).concatenating(.translation(10, 0))
        let p = t.apply(x: 1, y: 1)
        XCTAssertEqual(p.x, 12); XCTAssertEqual(p.y, 2)
    }

    func testTransitionEndpoints() {
        for style in TransitionStyle.allCases {
            let s0 = TransitionMath.states(style: style, rawProgress: 0)
            let s1 = TransitionMath.states(style: style, rawProgress: 1)
            XCTAssertEqual(s0.outgoing, LayerState(), "\(style) starts with the outgoing loop untouched")
            XCTAssertEqual(s1.incoming, LayerState(), "\(style) ends with the incoming loop at rest")
            if style == .slide {
                XCTAssertEqual(s0.incoming.offsetX, 1); XCTAssertEqual(s1.outgoing.offsetX, -1)
            }
            if style == .fade || style == .cut || style == .flash {
                XCTAssertEqual(s0.incoming.opacity, 0, accuracy: 1e-9, "\(style) incoming starts invisible")
            }
            if style == .zoom {
                XCTAssertFalse(TransitionMath.incomingOnTop(style: .zoom), "zoom reveals the incoming loop underneath")
                XCTAssertEqual(s1.outgoing.opacity, 0, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(TransitionMath.flashOpacity(rawProgress: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(TransitionMath.flashOpacity(rawProgress: 0), 0, accuracy: 1e-9)
    }

    func testStickerPoses() {
        let p = StickerPlacement(rotationDegrees: 5, animation: .pop)
        XCTAssertEqual(StickerMath.pose(p, tau: 0, progress: 0).scale, 0, accuracy: 1e-9)
        XCTAssertEqual(StickerMath.pose(p, tau: 1, progress: 0.5).scale, 1, accuracy: 1e-9)
        var w = p; w.animation = .wiggle
        XCTAssertEqual(StickerMath.pose(w, tau: 0, progress: 0).rotationDegrees, 5, accuracy: 1e-9)
        var d = p; d.animation = .drift
        XCTAssertEqual(StickerMath.pose(d, tau: 0, progress: 0).dx, -0.07, accuracy: 1e-9)
        XCTAssertEqual(StickerMath.pose(d, tau: 0, progress: 1).dx, 0.07, accuracy: 1e-9)
    }
}
