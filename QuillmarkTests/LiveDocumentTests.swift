import CoreGraphics
import XCTest
@testable import Quillmark

final class LiveDocumentTests: XCTestCase {
    private func line(fromX x0: Float, toX x1: Float, y: Float) -> InkStroke {
        let count = Int((x1 - x0) / 2)
        let points = (0...count).map { i in InkPoint(x: x0 + Float(i) * 2, y: y, force: 0.5, t: Float(i) / 240) }
        return InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: points, tool: .pen,
                         anchor: WebAnchor(selector: "#a", fingerprint: "A", tag: "P"))
    }

    func testSVGPathData() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 1, y: 2))
        path.addLine(to: CGPoint(x: 3.456, y: 4))
        path.addQuadCurve(to: CGPoint(x: 5, y: 6), control: CGPoint(x: 7, y: 8))
        path.closeSubpath()
        XCTAssertEqual(SVGPath.string(from: path), "M1 2L3.46 4Q7 8 5 6Z")
        XCTAssertEqual(SVGPath.format(.nan), "0")
    }

    func testCSSColor() {
        XCTAssertEqual(RGBAColor(1, 0, 0.5).cssString, "rgba(255,0,128,1.0)")
    }

    func testTranslateMovesPointsAndBakedSamples() {
        var stroke = line(fromX: 0, toX: 10, y: 5)
        stroke.baked = [StrokeSample(point: CGPoint(x: 1, y: 1), radius: 1)]
        let moved = stroke.translated(by: CGPoint(x: 10, y: -5))
        XCTAssertEqual(moved.points.first?.x, 10)
        XCTAssertEqual(moved.points.first?.y, 0)
        XCTAssertEqual(moved.baked?.first?.point, CGPoint(x: 11, y: -4))
        XCTAssertEqual(moved.translated(by: CGPoint(x: -10, y: 5)), stroke)
    }

    func testLiveEraserWorksInAnchorCoordinates() throws {
        // Stroke stored relative to its anchor, whose element currently sits at (100, 500).
        let stroke = line(fromX: 0, toX: 100, y: 10)
        let origin = CGPoint(x: 100, y: 500)
        let result = LiveEraser.erase([stroke], origins: [stroke.id: origin],
                                      from: CGPoint(x: 150, y: 490), to: CGPoint(x: 150, y: 530),
                                      radius: 5, mode: .pixel, highlighterOnly: false, cache: StrokeGeometryCache())
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.strokes.count, 2)
        for piece in result.strokes {
            XCTAssertEqual(piece.anchor, stroke.anchor, "pieces stay attached to the same element")
            XCTAssertEqual(result.newOrigins[piece.id], origin)
            let xs = try XCTUnwrap(piece.baked).map(\.point.x)
            XCTAssertTrue(xs.allSatisfy { $0 < 45 || $0 > 55 }, "cut happened at local x = 50")
        }
    }

    func testLiveEraserIgnoresStrokesWithoutPosition() {
        let stroke = line(fromX: 0, toX: 100, y: 10)
        let result = LiveEraser.erase([stroke], origins: [:], from: CGPoint(x: 50, y: 0), to: CGPoint(x: 50, y: 20),
                                      radius: 5, mode: .stroke, highlighterOnly: false, cache: StrokeGeometryCache())
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.strokes, [stroke])
    }

    func testAnchoredStrokeCoding() throws {
        let stroke = line(fromX: 0, toX: 10, y: 5)
        let data = try LibraryStore.encoder.encode(stroke)
        XCTAssertEqual(try LibraryStore.decoder.decode(InkStroke.self, from: data), stroke)
    }

    func testTitleExtraction() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("a.html")
        try "<html><head><TITLE lang=\"zh\">\n 羽签 &amp; 网页\n</TITLE></head></html>".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(HTMLImportService.htmlTitle(of: file), "羽签 & 网页")
        try "<p>no title</p>".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(HTMLImportService.htmlTitle(of: file))
    }

    func testLiveDocumentHasNoPDF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "live", pdfData: nil, layout: .live, sourceKind: .webURL,
                                              sourceURL: "https://example.com", stagedSource: nil,
                                              sourceEntry: "page.webarchive")
        XCTAssertEqual(LibraryStore(root: root).documents.first?.sourceEntry, "page.webarchive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.pdfURL(for: meta.id).path))
        XCTAssertNil(DocumentSession(meta: meta, library: library, tool: ToolSettings()).pdfDocument)
    }

    func testSameDocumentNavigation() {
        let base = URL(string: "https://example.com/a/page.html?x=1")!
        XCTAssertTrue(WebEditorViewController.isSameDocument(URL(string: "https://example.com/a/page.html?x=1#s2")!, base))
        XCTAssertFalse(WebEditorViewController.isSameDocument(URL(string: "https://example.com/other.html")!, base))
        XCTAssertFalse(WebEditorViewController.isSameDocument(base, nil))
    }
}
