import CoreGraphics
import UIKit
import XCTest
@testable import Quillmark

final class PresentationToolsTests: XCTestCase {
    private func subpathCount(in path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { elementPointer in
            if elementPointer.pointee.type == .moveToPoint {
                count += 1
            }
        }
        return count
    }

    private func polylinePoints(_ corners: [CGPoint], step: CGFloat = 4) -> [CGPoint] {
        var out: [CGPoint] = []
        for i in 0..<(corners.count - 1) {
            let a = corners[i]
            let b = corners[i + 1]
            let len = hypot(b.x - a.x, b.y - a.y)
            let steps = max(2, Int(ceil(len / step)))
            for k in 0..<steps {
                let t = CGFloat(k) / CGFloat(steps)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = corners.last { out.append(last) }
        return out
    }

    // MARK: ShapeRecognizer (Draw & Hold)

    func testRecognizesStraightLineAndSnapsNearHorizontal() {
        // 3 degrees off horizontal -> snaps to exact horizontal.
        let endY = 100 + 200 * tan(3 * CGFloat.pi / 180)
        let pts = polylinePoints([CGPoint(x: 20, y: 100), CGPoint(x: 220, y: endY)])
        guard case let .line(start, end) = ShapeRecognizer.recognize(pts) else {
            return XCTFail("Expected straight line")
        }
        XCTAssertEqual(start.x, 20, accuracy: 0.5)
        XCTAssertEqual(start.y, 100, accuracy: 0.5)
        XCTAssertEqual(end.y, 100, accuracy: 0.5, "should snap 3° line to horizontal")
    }

    func testRecognizesShortAndLongArrows() {
        let shortArrow = polylinePoints([
            CGPoint(x: 20, y: 100),
            CGPoint(x: 140, y: 100),
            CGPoint(x: 120, y: 84),
        ])
        guard case let .arrow(start1, end1) = ShapeRecognizer.recognize(shortArrow) else {
            return XCTFail("Expected short arrow")
        }
        XCTAssertEqual(start1.x, 20, accuracy: 1)
        XCTAssertEqual(end1.x, 140, accuracy: 2)

        // Long shaft with modest barb should still recognize as arrow, not line.
        let longArrow = polylinePoints([
            CGPoint(x: 0, y: 50),
            CGPoint(x: 300, y: 50),
            CGPoint(x: 282, y: 38),
        ])
        guard case let .arrow(start2, end2) = ShapeRecognizer.recognize(longArrow) else {
            return XCTFail("Expected long arrow")
        }
        XCTAssertEqual(start2.x, 0, accuracy: 1)
        XCTAssertEqual(end2.x, 300, accuracy: 2)
    }

    func testRecognizesCircleAndEllipse() {
        let circlePts = (0...64).map { i -> CGPoint in
            let theta = 2 * CGFloat.pi * CGFloat(i) / 64
            return CGPoint(x: 150 + 60 * cos(theta), y: 150 + 57 * sin(theta))
        }
        guard case let .ellipse(center, rx, ry, _) = ShapeRecognizer.recognize(circlePts) else {
            return XCTFail("Expected circle")
        }
        XCTAssertEqual(center.x, 150, accuracy: 3)
        XCTAssertEqual(center.y, 150, accuracy: 3)
        XCTAssertEqual(rx, ry, accuracy: 0.01, "near-circle should snap to exact circle")

        let ellipsePts = (0...64).map { i -> CGPoint in
            let theta = 2 * CGFloat.pi * CGFloat(i) / 64
            return CGPoint(x: 200 + 90 * cos(theta), y: 120 + 40 * sin(theta))
        }
        guard case let .ellipse(_, erx, ery, _) = ShapeRecognizer.recognize(ellipsePts) else {
            return XCTFail("Expected ellipse")
        }
        XCTAssertGreaterThan(max(erx, ery) / min(erx, ery), 1.8)
    }

    func testRecognizesRectangleAndTriangle() {
        // Rectangle starting at the midpoint of the top edge.
        let rectPts = polylinePoints([
            CGPoint(x: 150, y: 50),
            CGPoint(x: 250, y: 50),
            CGPoint(x: 250, y: 150),
            CGPoint(x: 50, y: 150),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 148, y: 51),
        ])
        guard case let .polygon(rectVerts) = ShapeRecognizer.recognize(rectPts) else {
            return XCTFail("Expected rectangle polygon")
        }
        XCTAssertEqual(rectVerts.count, 4)

        // Equilateral-ish triangle.
        let triPts = polylinePoints([
            CGPoint(x: 150, y: 40),
            CGPoint(x: 230, y: 180),
            CGPoint(x: 70, y: 180),
            CGPoint(x: 152, y: 43),
        ])
        guard case let .polygon(triVerts) = ShapeRecognizer.recognize(triPts) else {
            return XCTFail("Expected triangle polygon")
        }
        XCTAssertEqual(triVerts.count, 3)
    }

    func testTooShortStrokeReturnsNil() {
        let tiny = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 1), CGPoint(x: 4, y: 2), CGPoint(x: 5, y: 2)]
        XCTAssertNil(ShapeRecognizer.recognize(tiny))
    }

    func testShapeAdjustmentAndSampleGeneration() {
        let shapes: [RecognizedShape] = [
            .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 10)),
            .arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 10)),
            .ellipse(center: CGPoint(x: 100, y: 100), rx: 40, ry: 40, rotation: 0),
            .polygon(vertices: [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 80, y: 60), CGPoint(x: 0, y: 60)]),
        ]
        for shape in shapes {
            let adjusted = shape.adjusted(to: CGPoint(x: 200, y: 100), initialAnchor: CGPoint(x: 110, y: 10))
            let samples = adjusted.samples(radius: 1.5)
            XCTAssertFalse(samples.isEmpty)
            let path = StrokeOutline.path(for: samples)
            let box = path.boundingBox
            XCTAssertFalse(box.isNull)
            XCTAssertTrue(box.width.isFinite && box.height.isFinite)
            XCTAssertGreaterThan(box.width, 5)
        }
    }

    // MARK: Line Styles & Eraser on Composite Shapes

    func testDashedAndDottedLineStylesProduceMultipleSubpaths() {
        let points = (0..<80).map { i in
            InkPoint(x: Float(i) * 3, y: 50, force: 0.5, t: Float(i) / 240)
        }
        let solid = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0.2,
                              points: points, tool: .pen, lineStyle: .solid)
        let dashed = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0.2,
                               points: points, tool: .pen, lineStyle: .dashed)
        let dotted = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0.2,
                               points: points, tool: .pen, lineStyle: .dotted)

        XCTAssertEqual(subpathCount(in: solid.outlinePath()), 1)
        XCTAssertGreaterThan(subpathCount(in: dashed.outlinePath()), 4)
        XCTAssertGreaterThan(subpathCount(in: dotted.outlinePath()), 10)
        XCTAssertTrue(dashed.outlinePath().boundingBox.width.isFinite)
        XCTAssertTrue(dotted.outlinePath().boundingBox.width.isFinite)
    }

    func testEraserHandlesSnappedShapeWithSubpathBreaks() {
        let arrow = RecognizedShape.arrow(start: CGPoint(x: 0, y: 50), end: CGPoint(x: 120, y: 50))
        let samples = arrow.samples(radius: 1.5)
        XCTAssertTrue(samples.contains { $0.radius == 0 }, "arrow samples contain subpath breaks")

        let stroke = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 3, smoothing: 0,
                               points: [], tool: .pen, baked: samples, lineStyle: .solid)
        let cache = StrokeGeometryCache()

        // Pixel erase middle of shaft: should split cleanly without keeping sentinel break samples.
        let pixelResult = EraserEngine.erase([stroke], from: CGPoint(x: 55, y: 50), to: CGPoint(x: 65, y: 50),
                                             radius: 8, mode: .pixel, highlighterOnly: false, cache: cache)
        XCTAssertTrue(pixelResult.changed)
        XCTAssertGreaterThanOrEqual(pixelResult.strokes.count, 2)
        for piece in pixelResult.strokes {
            XCTAssertFalse(piece.outlinePath().boundingBox.isNull)
            XCTAssertTrue(piece.baked?.allSatisfy { $0.radius > 0 } ?? false)
        }

        // Stroke erase: removes the entire arrow.
        let wholeResult = EraserEngine.erase([stroke], from: CGPoint(x: 60, y: 50), to: CGPoint(x: 60, y: 50),
                                             radius: 6, mode: .stroke, highlighterOnly: false, cache: cache)
        XCTAssertTrue(wholeResult.changed)
        XCTAssertTrue(wholeResult.strokes.isEmpty)
    }

    // MARK: Laser Pointer

    func testLaserTrailStaysVisibleWhileTouchingAndFadesOnLift() {
        let engine = LaserPointerEngine()
        engine.begin(at: CGPoint(x: 10, y: 10), color: ToolSettings.laserPalette[0], now: 10.0)
        engine.move(to: CGPoint(x: 60, y: 20), now: 10.1)
        engine.move(to: CGPoint(x: 110, y: 30), now: 10.2)

        // Even 5 seconds later while still holding the pen down, the full trail remains intact.
        let held = engine.frame(at: 15.2)
        XCTAssertTrue(held.isActive)
        XCTAssertNotNil(held.glowPath)
        XCTAssertNotNil(held.corePath)
        XCTAssertEqual(held.opacity, 1.0, accuracy: 0.001)
        XCTAssertEqual(engine.samples.count, 3)

        // Lifting the pen starts the smooth fade-out.
        engine.end(now: 15.2)
        let midFade = engine.frame(at: 15.2 + LaserPointerEngine.liftFadeDuration * 0.5)
        XCTAssertTrue(midFade.isActive)
        XCTAssertEqual(midFade.opacity, 0.5, accuracy: 0.05)

        let expired = engine.frame(at: 15.2 + LaserPointerEngine.liftFadeDuration + 0.05)
        XCTAssertFalse(expired.isActive)
        XCTAssertTrue(engine.samples.isEmpty)
    }

    func testLaserCancelClearsImmediately() {
        let engine = LaserPointerEngine()
        engine.begin(at: CGPoint(x: 20, y: 20), color: ToolSettings.laserPalette[1], now: 5.0)
        engine.move(to: CGPoint(x: 150, y: 80), now: 5.1)
        XCTAssertTrue(engine.frame(at: 5.2).isActive)

        engine.cancel()
        XCTAssertFalse(engine.frame(at: 5.2).isActive)
    }

    // MARK: Cover Tape & Backward Compatibility

    func testTapeToggleDoesNotPolluteUndoStack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "tape", pdfData: Data(), layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())

        let tape = InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.tapePalette[0],
                             width: 26, smoothing: 0.7,
                             points: [InkPoint(x: 10, y: 10), InkPoint(x: 120, y: 10)],
                             tool: .tape, lineStyle: .solid, revealed: false)
        session.addStroke(tape, page: 0)
        XCTAssertTrue(session.canUndo)
        XCTAssertFalse(session.strokes(onPage: 0)[0].isRevealed)

        session.toggleTape(id: tape.id, page: 0)
        XCTAssertTrue(session.strokes(onPage: 0)[0].isRevealed)

        session.setAllTapesRevealed(false)
        XCTAssertFalse(session.strokes(onPage: 0)[0].isRevealed)

        session.setAllTapesRevealed(true)
        XCTAssertTrue(session.strokes(onPage: 0)[0].isRevealed)

        // One undo must remove the tape stroke itself, proving toggles were not pushed to undo.
        session.undo()
        XCTAssertTrue(session.strokes(onPage: 0).isEmpty)
        XCTAssertFalse(session.canUndo)
    }

    func testTapeHorizontalSnapAndBackwardCompatibleDecoding() throws {
        let slanted = [InkPoint(x: 0, y: 40), InkPoint(x: 100, y: 46)] // ~3.4°
        let snapped = StrokeProcessor.straightened(slanted, spacing: 5, snapAngleDegrees: 8)
        XCTAssertEqual(snapped.last?.y ?? 0, 40, accuracy: 0.01)

        // Decode a v0.2 JSON stroke that lacks lineStyle and revealed fields.
        let legacyJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "pen": "fountain",
          "color": { "r": 0.1, "g": 0.1, "b": 0.1, "a": 1.0 },
          "width": 2.0,
          "smoothing": 0.45,
          "points": [{ "x": 10, "y": 20, "force": 0.5, "azimuth": 0, "altitude": 1.5, "t": 0 }]
        }
        """
        let decoded = try JSONDecoder().decode(InkStroke.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.resolvedLineStyle, .solid)
        XCTAssertFalse(decoded.isTape)
        XCTAssertFalse(decoded.isRevealed)
    }

    func testToolSettingsPersistenceRoundTrip() {
        let suiteName = "quillmark.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var settings = ToolSettings()
        settings.kind = .tape
        settings.lineStyle = .dashed
        settings.drawAndHold = false
        settings.tapeWidth = 42
        settings.tapeStraight = false
        settings.laserColor = ToolSettings.laserPalette[2]
        settings.save(to: defaults)

        let loaded = ToolSettings.load(from: defaults)
        XCTAssertEqual(loaded, settings)
    }
}
