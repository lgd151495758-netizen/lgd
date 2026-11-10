import CoreGraphics
import XCTest
@testable import Quillmark

final class StrokeGeometryTests: XCTestCase {
    private func horizontalLine(count: Int, spacing: Float = 2, force: Float = 0.5, jitter: Float = 0,
                                dt: Float = 1 / 240) -> [InkPoint] {
        (0..<count).map { i in
            InkPoint(x: Float(i) * spacing, y: 100 + (i % 2 == 0 ? jitter : -jitter), force: force, t: Float(i) * dt)
        }
    }

    private func meanRadius(_ samples: [StrokeSample]) -> CGFloat {
        let middle = samples.dropFirst(samples.count / 4).dropLast(samples.count / 4)
        return middle.map(\.radius).reduce(0, +) / CGFloat(max(1, middle.count))
    }

    func testEmptyInputProducesNothing() {
        XCTAssertTrue(StrokeProcessor.samples(for: [], pen: .fountain, width: 2, smoothing: 0.5, finished: true).isEmpty)
        XCTAssertTrue(StrokeOutline.path(for: []).isEmpty)
    }

    func testSinglePointBecomesDotOfNominalWidth() {
        let samples = StrokeProcessor.samples(for: [InkPoint(x: 10, y: 10)], pen: .ballpoint, width: 2,
                                              smoothing: 0.5, finished: true)
        XCTAssertEqual(samples.count, 1)
        let box = StrokeOutline.path(for: samples).boundingBox
        XCTAssertEqual(box.width, 2, accuracy: 0.01)
        XCTAssertEqual(box.midX, 10, accuracy: 0.01)
    }

    func testSmoothingReducesJitter() {
        let points = horizontalLine(count: 80, jitter: 3)
        func deviation(_ smoothing: Float) -> CGFloat {
            let samples = StrokeProcessor.samples(for: points, pen: .ballpoint, width: 2, smoothing: smoothing, finished: true)
            let inner = samples.dropFirst(5).dropLast(2)
            return inner.map { abs($0.point.y - 100) }.reduce(0, +) / CGFloat(inner.count)
        }
        XCTAssertLessThan(deviation(0.9), deviation(0) * 0.6)
    }

    func testStrokeEndsAtThePen() {
        let points = horizontalLine(count: 40)
        let samples = StrokeProcessor.samples(for: points, pen: .fountain, width: 2, smoothing: 0.8, finished: true)
        let last = try? XCTUnwrap(samples.last)
        XCTAssertEqual(last?.point.x ?? 0, CGFloat(points.last!.x), accuracy: 0.001)
        XCTAssertEqual(last?.point.y ?? 0, CGFloat(points.last!.y), accuracy: 0.001)
    }

    func testFountainPenWidensWithPressure() {
        let light = StrokeProcessor.samples(for: horizontalLine(count: 60, force: 0.2), pen: .fountain, width: 2, smoothing: 0.4, finished: true)
        let heavy = StrokeProcessor.samples(for: horizontalLine(count: 60, force: 0.9), pen: .fountain, width: 2, smoothing: 0.4, finished: true)
        XCTAssertGreaterThan(meanRadius(heavy), meanRadius(light) * 1.8)
    }

    func testBallpointIsLessPressureSensitiveThanBrush() {
        func ratio(_ pen: PenKind) -> CGFloat {
            let light = StrokeProcessor.samples(for: horizontalLine(count: 60, force: 0.2), pen: pen, width: 2, smoothing: 0.4, finished: true)
            let heavy = StrokeProcessor.samples(for: horizontalLine(count: 60, force: 0.9), pen: pen, width: 2, smoothing: 0.4, finished: true)
            return meanRadius(heavy) / meanRadius(light)
        }
        XCTAssertLessThan(ratio(.ballpoint), 1.5)
        XCTAssertGreaterThan(ratio(.brush), ratio(.fountain))
    }

    func testFastFountainStrokesAreThinner() {
        let slow = StrokeProcessor.samples(for: horizontalLine(count: 60, spacing: 0.6), pen: .fountain, width: 2, smoothing: 0.2, finished: true)
        let fast = StrokeProcessor.samples(for: horizontalLine(count: 60, spacing: 10), pen: .fountain, width: 2, smoothing: 0.2, finished: true)
        XCTAssertLessThan(meanRadius(fast), meanRadius(slow))
    }

    func testOutlineIsFiniteForIrregularInput() {
        var generator = SystemRandomNumberGenerator()
        var points: [InkPoint] = []
        for i in 0..<300 {
            points.append(InkPoint(x: Float.random(in: 0...500, using: &generator),
                                   y: Float.random(in: 0...700, using: &generator),
                                   force: Float.random(in: 0...1, using: &generator),
                                   t: Float(i) / 240))
        }
        points.append(points[points.count - 1]) // duplicate point
        for pen in PenKind.allCases {
            let stroke = InkStroke(id: UUID(), pen: pen, color: .ink, width: 2, smoothing: 0.5, points: points)
            let box = stroke.outlinePath().boundingBox
            XCTAssertFalse(box.isNull)
            XCTAssertTrue(box.width.isFinite && box.height.isFinite)
            XCTAssertGreaterThan(box.width, 10)
        }
    }

    func testPathScalesWithTransform() {
        let stroke = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0.3,
                               points: horizontalLine(count: 30))
        let base = stroke.outlinePath().boundingBox
        let scaled = stroke.outlinePath(transform: CGAffineTransform(scaleX: 2, y: 2)).boundingBox
        XCTAssertEqual(scaled.width, base.width * 2, accuracy: 0.01)
    }

    func testForceNormalization() {
        XCTAssertEqual(PenModel.normalizedForce(raw: 1, maximum: 4, isStylus: false), 0.5)
        XCTAssertEqual(PenModel.normalizedForce(raw: 0, maximum: 4, isStylus: true), 0)
        XCTAssertEqual(PenModel.normalizedForce(raw: 4, maximum: 4, isStylus: true), 1)
        XCTAssertLessThan(PenModel.normalizedForce(raw: 0.5, maximum: 4, isStylus: true),
                          PenModel.normalizedForce(raw: 1.5, maximum: 4, isStylus: true))
    }

    func testPageMapping() {
        XCTAssertEqual(PageMapping.scale(viewSize: CGSize(width: 1190.56, height: 1683.78),
                                         pageSize: CGSize(width: 595.28, height: 841.89)), 2, accuracy: 0.0001)
        XCTAssertEqual(PageMapping.scale(viewSize: .zero, pageSize: CGSize(width: 100, height: 100)), 1)
    }
}
