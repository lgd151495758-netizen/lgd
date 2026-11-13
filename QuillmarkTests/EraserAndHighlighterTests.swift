import CoreGraphics
import UIKit
import XCTest
@testable import Quillmark

final class EraserAndHighlighterTests: XCTestCase {
    private func line(fromX x0: Float, toX x1: Float, y: Float, tool: InkTool = .pen) -> InkStroke {
        let count = Int((x1 - x0) / 2)
        let points = (0...count).map { i in InkPoint(x: x0 + Float(i) * 2, y: y, force: 0.5, t: Float(i) / 240) }
        return InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: points, tool: tool)
    }

    func testStrokeEraserRemovesOnlyTouchedStrokes() {
        let top = line(fromX: 0, toX: 100, y: 50)
        let bottom = line(fromX: 0, toX: 100, y: 200)
        let result = EraserEngine.erase([top, bottom], from: CGPoint(x: 50, y: 40), to: CGPoint(x: 50, y: 60),
                                        radius: 4, mode: .stroke, highlighterOnly: false, cache: StrokeGeometryCache())
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.strokes.map(\.id), [bottom.id])
    }

    func testMissChangesNothing() {
        let stroke = line(fromX: 0, toX: 100, y: 50)
        for mode in EraserMode.allCases {
            let result = EraserEngine.erase([stroke], from: CGPoint(x: 50, y: 120), to: CGPoint(x: 60, y: 130),
                                            radius: 4, mode: mode, highlighterOnly: false, cache: StrokeGeometryCache())
            XCTAssertFalse(result.changed)
            XCTAssertEqual(result.strokes, [stroke])
        }
    }

    func testPixelEraserSplitsStrokeInTwo() throws {
        let stroke = line(fromX: 0, toX: 100, y: 50)
        let result = EraserEngine.erase([stroke], from: CGPoint(x: 50, y: 30), to: CGPoint(x: 50, y: 70),
                                        radius: 5, mode: .pixel, highlighterOnly: false, cache: StrokeGeometryCache())
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.strokes.count, 2)
        let left = try XCTUnwrap(result.strokes.first?.baked)
        let right = try XCTUnwrap(result.strokes.last?.baked)
        XCTAssertLessThan(left.map(\.point.x).max()!, 50 - 5)
        XCTAssertGreaterThan(right.map(\.point.x).min()!, 50 + 5)
        XCTAssertEqual(left.first?.point.x ?? -1, 0, accuracy: 0.01, "untouched part keeps its geometry")
        XCTAssertTrue(result.strokes.allSatisfy { $0.color == stroke.color && $0.tool == .pen })
    }

    func testPixelEraserFragmentsCanBeErasedAgain() {
        let stroke = line(fromX: 0, toX: 100, y: 50)
        let cache = StrokeGeometryCache()
        let once = EraserEngine.erase([stroke], from: CGPoint(x: 50, y: 30), to: CGPoint(x: 50, y: 70),
                                      radius: 5, mode: .pixel, highlighterOnly: false, cache: cache)
        let twice = EraserEngine.erase(once.strokes, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 20, y: 70),
                                       radius: 5, mode: .pixel, highlighterOnly: false, cache: cache)
        XCTAssertTrue(twice.changed)
        XCTAssertEqual(twice.strokes.count, 3)
    }

    func testErasingWholeStrokeLeavesNothing() {
        let stroke = line(fromX: 0, toX: 10, y: 50)
        let result = EraserEngine.erase([stroke], from: CGPoint(x: -5, y: 50), to: CGPoint(x: 15, y: 50),
                                        radius: 6, mode: .pixel, highlighterOnly: false, cache: StrokeGeometryCache())
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.strokes.isEmpty)
    }

    func testHighlighterOnlyKeepsPenInk() {
        let pen = line(fromX: 0, toX: 100, y: 50)
        let marker = line(fromX: 0, toX: 100, y: 52, tool: .highlighter)
        let result = EraserEngine.erase([pen, marker], from: CGPoint(x: 50, y: 40), to: CGPoint(x: 50, y: 60),
                                        radius: 4, mode: .stroke, highlighterOnly: true, cache: StrokeGeometryCache())
        XCTAssertEqual(result.strokes.map(\.id), [pen.id])
    }

    func testFastEraserSweepDoesNotSkipStrokes() {
        // A single large jump crossing the stroke must still erase it (swept capsule, not two dots).
        let stroke = line(fromX: 0, toX: 100, y: 50)
        let result = EraserEngine.erase([stroke], from: CGPoint(x: 50, y: 0), to: CGPoint(x: 50, y: 100),
                                        radius: 2, mode: .stroke, highlighterOnly: false, cache: StrokeGeometryCache())
        XCTAssertTrue(result.strokes.isEmpty)
    }

    func testBakedStrokeSurvivesCoding() throws {
        let stroke = line(fromX: 0, toX: 100, y: 50)
        let pieces = EraserEngine.erase([stroke], from: CGPoint(x: 50, y: 30), to: CGPoint(x: 50, y: 70),
                                        radius: 5, mode: .pixel, highlighterOnly: false, cache: StrokeGeometryCache()).strokes
        let data = try LibraryStore.encoder.encode(pieces)
        let decoded = try LibraryStore.decoder.decode([InkStroke].self, from: data)
        XCTAssertEqual(decoded, pieces)
    }

    func testOldFilesWithoutToolDecodeAsPen() throws {
        let json = """
        {"id":"\(UUID().uuidString)","pen":"fountain","color":{"r":0,"g":0,"b":0,"a":1},
         "width":2,"smoothing":0.4,"points":[{"x":1,"y":2,"force":0.5,"azimuth":0,"altitude":1.5,"t":0}]}
        """
        let stroke = try JSONDecoder().decode(InkStroke.self, from: Data(json.utf8))
        XCTAssertFalse(stroke.isHighlighter)
        XCTAssertNil(stroke.baked)
    }

    func testHighlighterHasConstantWidth() {
        var points: [InkPoint] = []
        for i in 0..<60 {
            points.append(InkPoint(x: Float(i) * 3, y: 10, force: i % 2 == 0 ? 0.1 : 1.0, t: Float(i) / 240))
        }
        let samples = StrokeProcessor.samples(for: points, pen: .brush, width: 14, smoothing: 0.7,
                                              finished: true, highlighter: true)
        let radii = samples.map(\.radius)
        XCTAssertEqual(radii.min() ?? 0, 7, accuracy: 0.001)
        XCTAssertEqual(radii.max() ?? 0, 7, accuracy: 0.001)
    }

    func testStraightenedHighlighterIsALine() {
        let wobbly = (0..<50).map { i in InkPoint(x: Float(i) * 4, y: 100 + Float(i % 5), t: Float(i) / 240) }
        let straight = StrokeProcessor.straightened(wobbly)
        XCTAssertEqual(straight.first?.x, wobbly.first?.x)
        XCTAssertEqual(straight.last?.x, wobbly.last?.x)
        XCTAssertEqual(straight.last?.y, wobbly.last?.y)
        let slope = (straight.last!.y - straight.first!.y) / (straight.last!.x - straight.first!.x)
        for p in straight {
            XCTAssertEqual(p.y, straight.first!.y + slope * (p.x - straight.first!.x), accuracy: 0.001)
        }
    }

    func testDensifyLimitsSpacing() {
        let samples = [StrokeSample(point: .zero, radius: 1), StrokeSample(point: CGPoint(x: 10, y: 0), radius: 3)]
        let dense = StrokeProcessor.densified(samples, maxSpacing: 1)
        XCTAssertGreaterThanOrEqual(dense.count, 11)
        for i in 1..<dense.count {
            XCTAssertLessThanOrEqual(dense[i].point.x - dense[i - 1].point.x, 1.0001)
        }
        XCTAssertEqual(dense.last, samples.last)
    }

    func testPencilDoubleTapToggles() {
        var tool = ToolSettings()
        tool.select(.highlighter)
        tool.toggleEraser()
        XCTAssertEqual(tool.kind, .eraser)
        tool.toggleEraser()
        XCTAssertEqual(tool.kind, .highlighter, "double-tap returns to the tool in use before the eraser")

        tool.select(.pen)
        tool.switchToPrevious()
        XCTAssertEqual(tool.kind, .highlighter)
        tool.switchToPrevious()
        XCTAssertEqual(tool.kind, .pen)
    }

    func testEraseIsOneUndoStep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("erase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { $0.beginPage() }
        let meta = try library.createDocument(title: "e", pdfData: pdf, layout: .pagedA4, sourceKind: .htmlFile,
                                              sourceURL: nil, stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        let stroke = line(fromX: 0, toX: 100, y: 50)
        session.addStroke(stroke, page: 0)

        let before = session.strokes(onPage: 0)
        let after = EraserEngine.erase(before, from: CGPoint(x: 50, y: 30), to: CGPoint(x: 50, y: 70), radius: 5,
                                       mode: .pixel, highlighterOnly: false, cache: StrokeGeometryCache()).strokes
        session.replaceStrokes(onPage: 0, before: before, after: after)
        XCTAssertEqual(session.strokes(onPage: 0).count, 2)
        session.undo()
        XCTAssertEqual(session.strokes(onPage: 0), [stroke])
        session.redo()
        XCTAssertEqual(session.strokes(onPage: 0), after)
    }
}
