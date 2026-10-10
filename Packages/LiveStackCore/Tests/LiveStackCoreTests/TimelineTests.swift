import XCTest
@testable import LiveStackCore

final class TimelineTests: XCTestCase {
    func testCutHasNoOverlap() {
        let tl = ReelTimeline.build(durations: [2, 3, 1], transition: .cut, transitionLength: 0.35)
        XCTAssertEqual(tl.items.map(\.start), [0, 2, 5])
        XCTAssertEqual(tl.total, 6)
        XCTAssertTrue(tl.spans().allSatisfy { !$0.isTransition })
    }

    func testOverlapShortensTotal() {
        let tl = ReelTimeline.build(durations: [2, 2, 2], transition: .slide, transitionLength: 0.35)
        XCTAssertEqual(tl.items[1].start, 1.65, accuracy: 1e-9)
        XCTAssertEqual(tl.items[2].start, 3.30, accuracy: 1e-9)
        XCTAssertEqual(tl.total, 6 - 0.7, accuracy: 1e-9)
    }

    func testOverlapNeverEatsMoreThanHalfAClip() {
        let tl = ReelTimeline.build(durations: [0.4, 2], transition: .fade, transitionLength: 0.5)
        XCTAssertEqual(tl.items[1].start, 0.2, accuracy: 1e-9)
    }

    func testSpansPartitionTheReel() {
        let tl = ReelTimeline.build(durations: [2, 1.5, 2.5, 1], transition: .zoom, transitionLength: 0.35)
        let spans = tl.spans()
        XCTAssertEqual(spans.first?.start, 0)
        XCTAssertEqual(spans.last?.end ?? -1, tl.total, accuracy: 1e-9)
        for (a, b) in zip(spans, spans.dropFirst()) { XCTAssertEqual(a.end, b.start, accuracy: 1e-9) }
        XCTAssertEqual(spans.filter(\.isTransition).count, 3)
        for s in spans where s.isTransition {
            XCTAssertEqual(s.duration, 0.35, accuracy: 1e-9)
            XCTAssertEqual(s.items[0] + 1, s.items[1], "outgoing listed first")
        }
        XCTAssertEqual(spans.map(\.items), [[0], [0, 1], [1], [1, 2], [2], [2, 3], [3]])
    }

    func testSampleInsideTransition() {
        let tl = ReelTimeline.build(durations: [2, 2], transition: .fade, transitionLength: 0.4)
        let s = tl.sample(at: 1.7)!
        XCTAssertEqual(s.a.index, 0); XCTAssertEqual(s.b?.index, 1)
        XCTAssertEqual(s.progress, 0.25, accuracy: 1e-9)
        let solo = tl.sample(at: 0.5)!
        XCTAssertNil(solo.b)
        let end = tl.sample(at: 99)!
        XCTAssertEqual(end.a.index, 1, "past the end clamps to the last loop")
    }

    func testEmpty() {
        let tl = ReelTimeline.build(durations: [], transition: .slide, transitionLength: 0.35)
        XCTAssertNil(tl.sample(at: 0)); XCTAssertEqual(tl.total, 0); XCTAssertTrue(tl.spans().isEmpty)
    }
}
