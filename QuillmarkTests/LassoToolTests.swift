import CoreGraphics
import UIKit
import XCTest
@testable import Quillmark

final class LassoToolTests: XCTestCase {
    private func horizontalStroke(x0: Float, x1: Float, y: Float,
                                  color: RGBAColor = .ink,
                                  anchor: WebAnchor? = nil) -> InkStroke {
        let steps = max(4, Int((x1 - x0) / 3))
        let pts = (0...steps).map { i in
            InkPoint(x: x0 + (x1 - x0) * Float(i) / Float(steps), y: y, force: 0.5, t: Float(i) / 240)
        }
        return InkStroke(id: UUID(), pen: .ballpoint, color: color, width: 2, smoothing: 0,
                         points: pts, tool: .pen, anchor: anchor)
    }

    func testPointInPolygonConvexAndConcave() {
        let square = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100),
        ]
        XCTAssertTrue(LassoEngine.pointInPolygon(CGPoint(x: 50, y: 50), polygon: square))
        XCTAssertFalse(LassoEngine.pointInPolygon(CGPoint(x: 150, y: 50), polygon: square))

        // Concave U-shaped polygon: (50, 20) sits in the open notch (outside), (15, 50) is inside the left wall.
        let concaveU = [
            CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 70),
            CGPoint(x: 70, y: 70), CGPoint(x: 70, y: 0), CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100),
        ]
        XCTAssertFalse(LassoEngine.pointInPolygon(CGPoint(x: 50, y: 20), polygon: concaveU))
        XCTAssertTrue(LassoEngine.pointInPolygon(CGPoint(x: 15, y: 50), polygon: concaveU))
        XCTAssertTrue(LassoEngine.pointInPolygon(CGPoint(x: 50, y: 85), polygon: concaveU))
    }

    func testLassoSelectsEnclosedStrokesAndIgnoresOuterFrameAndHiddenStrokes() {
        let cache = StrokeGeometryCache()
        let anchor = WebAnchor(selector: "#p1", fingerprint: "p1", tag: "P")

        // Big outer circle centered at (200, 200), radius 120.
        let outerCircle = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0,
                                    points: [], tool: .pen, anchor: anchor,
                                    geometry: .circle(center: CGPoint(x: 200, y: 200), radius: 120, showCenterMark: false))
        // Small handwritten label inside the circle at document (185..215, 200) -> local (85..115, 100) with origin (100, 100).
        let innerLabel = horizontalStroke(x0: 85, x1: 115, y: 100, anchor: anchor)
        // Hidden stroke at the same location (omitted from visible `origins`).
        let hiddenStroke = horizontalStroke(x0: 85, x1: 115, y: 105, anchor: anchor)
        // Outside stroke far away.
        let outsideStroke = horizontalStroke(x0: 350, x1: 420, y: 350, anchor: anchor)

        let origins: [UUID: CGPoint] = [
            outerCircle.id: .zero,
            innerLabel.id: CGPoint(x: 100, y: 100),
            outsideStroke.id: CGPoint(x: 100, y: 100),
        ]

        // Small lasso loop strictly inside the big circle around (200, 200).
        let loop = [
            CGPoint(x: 170, y: 175),
            CGPoint(x: 230, y: 175),
            CGPoint(x: 230, y: 225),
            CGPoint(x: 170, y: 225),
        ]
        let selected = LassoEngine.selectStrokeIDs(from: [outerCircle, innerLabel, hiddenStroke, outsideStroke],
                                                   origins: origins, polygon: loop, cache: cache)
        XCTAssertEqual(selected, [innerLabel.id],
                       "lasso inside a large circle should pick only the inner label, never the outer frame or hidden strokes")
    }

    func testLassoSingleStrokeTapHitTest() {
        let cache = StrokeGeometryCache()
        let line = horizontalStroke(x0: 40, x1: 140, y: 80)
        let tri = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0,
                            points: [], tool: .pen,
                            geometry: .polygon(vertices: [
                                CGPoint(x: 220, y: 40), CGPoint(x: 280, y: 140), CGPoint(x: 160, y: 140),
                            ], closed: true))

        let hitLine = LassoEngine.hitTestSingleStroke(from: [line, tri], origins: [:],
                                                      at: CGPoint(x: 90, y: 84), tolerance: 12, cache: cache)
        XCTAssertEqual(hitLine, line.id)

        let hitTri = LassoEngine.hitTestSingleStroke(from: [line, tri], origins: [:],
                                                     at: CGPoint(x: 220, y: 110), tolerance: 12, cache: cache)
        XCTAssertEqual(hitTri, tri.id)

        let miss = LassoEngine.hitTestSingleStroke(from: [line, tri], origins: [:],
                                                   at: CGPoint(x: 400, y: 400), tolerance: 12, cache: cache)
        XCTAssertNil(miss)
    }

    func testLassoTransformScalesAndTranslatesAllStrokeTypes() throws {
        let pivot = CGPoint(x: 100, y: 100)
        let scale: CGFloat = 1.5
        let offset = CGPoint(x: 20, y: -10)

        // 1. Raw handwritten stroke (verify StrokeGeometryCache invalidates even when stroke.id stays identical)
        let cache = StrokeGeometryCache()
        let raw = horizontalStroke(x0: 100, x1: 200, y: 100)
        let beforeBox = cache.bounds(for: raw)
        XCTAssertEqual(beforeBox.minX, 99, accuracy: 1.5)
        let rawT = LassoEngine.transformStroke(raw, scale: scale, around: pivot, translation: offset)
        let afterBox = cache.bounds(for: rawT)
        XCTAssertEqual(rawT.points.first?.x ?? 0, 120, accuracy: 0.01)
        XCTAssertEqual(rawT.points.last?.x ?? 0, 270, accuracy: 0.01)
        XCTAssertEqual(rawT.points.last?.y ?? 0, 90, accuracy: 0.01)
        XCTAssertEqual(rawT.width, 3.0, accuracy: 0.01)
        XCTAssertEqual(afterBox.minX, 118.5, accuracy: 2.0, "cache must reflect transformed coordinates")
        XCTAssertEqual(afterBox.maxX, 271.5, accuracy: 2.0)

        // 2. Baked precise-eraser fragment
        let bakedSamples = [
            StrokeSample(point: CGPoint(x: 120, y: 100), radius: 2),
            StrokeSample(point: CGPoint(x: 160, y: 100), radius: 2),
        ]
        let baked = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 4, smoothing: 0,
                              points: [], tool: .pen, baked: bakedSamples)
        let bakedT = LassoEngine.transformStroke(baked, scale: scale, around: pivot, translation: offset)
        XCTAssertEqual(bakedT.baked?.first?.point.x ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(bakedT.baked?.last?.point.x ?? 0, 210, accuracy: 0.01)
        XCTAssertEqual(bakedT.baked?.first?.radius ?? 0, 3.0, accuracy: 0.01)

        // 3. Parametric circle, parabola, polygon, axes
        let primitives: [GeometricPrimitive] = [
            .circle(center: CGPoint(x: 140, y: 100), radius: 40, showCenterMark: true),
            .parabola(vertex: CGPoint(x: 120, y: 140), axisAngle: -.pi / 2, halfWidth: 50, height: 80),
            .polygon(vertices: [CGPoint(x: 100, y: 100), CGPoint(x: 140, y: 100), CGPoint(x: 120, y: 140)], closed: true),
            .axes(origin: CGPoint(x: 120, y: 120), xMin: -60, xMax: 60, yMin: -60, yMax: 60, tickSpacing: 24),
        ]
        for prim in primitives {
            let stroke = InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.palette[1], width: 2,
                                   smoothing: 0, points: [], tool: .pen, geometry: prim,
                                   fillColor: prim.supportsFill ? ToolSettings.palette[1] : nil)
            let transformed = LassoEngine.transformStroke(stroke, scale: scale, around: pivot, translation: offset)
            let data = try JSONEncoder().encode(transformed)
            let decoded = try JSONDecoder().decode(InkStroke.self, from: data)
            XCTAssertEqual(decoded, transformed)
            XCTAssertFalse(decoded.outlinePath().boundingBox.isNull)
        }

        // Verify exact scaled circle radius & center
        let circle = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: [],
                               tool: .pen, geometry: .circle(center: CGPoint(x: 140, y: 100), radius: 40, showCenterMark: false))
        let circleT = LassoEngine.transformStroke(circle, scale: scale, around: pivot, translation: offset)
        if case let .circle(c, r, _) = circleT.geometry {
            XCTAssertEqual(c.x, 180, accuracy: 0.01) // 100 + 40*1.5 + 20
            XCTAssertEqual(c.y, 90, accuracy: 0.01)  // 100 + 0 - 10
            XCTAssertEqual(r, 60, accuracy: 0.01)
        } else {
            XCTFail("Expected scaled circle geometry")
        }
    }

    func testLassoSelectionOverlayHitTestingAndActionBarClamping() {
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let overlay = LassoSelectionOverlay(
            strokeIDs: [UUID()],
            boundingBox: CGRect(x: 200, y: 200, width: 160, height: 100),
            activeColor: ToolSettings.palette[2]
        )

        // Corner handles & opposite pivot
        for (corner, pt) in overlay.handlePositions() {
            XCTAssertEqual(overlay.hitTest(pt, in: bounds), .handle(corner))
        }
        XCTAssertEqual(overlay.oppositeCorner(of: .bottomRight, in: overlay.boundingBox),
                       CGPoint(x: 200, y: 200))
        XCTAssertEqual(overlay.hitTest(CGPoint(x: 280, y: 250), in: bounds), .body)
        XCTAssertEqual(overlay.hitTest(CGPoint(x: 800, y: 600), in: bounds), .none)

        // Action bar contains all 6 color swatches + duplicate + delete
        let buttons = overlay.actionButtons(in: bounds)
        XCTAssertEqual(buttons.count, ToolSettings.palette.count + 2)
        for (action, rect) in buttons {
            XCTAssertEqual(overlay.hitTest(CGPoint(x: rect.midX, y: rect.midY), in: bounds), .action(action))
        }

        // Near top edge: action bar flips cleanly below the selection box
        let topOverlay = LassoSelectionOverlay(
            strokeIDs: [UUID()],
            boundingBox: CGRect(x: 200, y: 12, width: 140, height: 60),
            activeColor: nil
        )
        let flippedBar = topOverlay.actionBarFrame(in: bounds)
        XCTAssertGreaterThan(flippedBar.minY, topOverlay.paddedBox.maxY)
    }

    func testSimplifiedToolsDefaultsAndLegacyAnnotationsCompatibility() throws {
        let settings = ToolSettings()
        XCTAssertEqual(settings.kind, .pen)
        XCTAssertEqual(settings.pen, .ballpoint)
        XCTAssertTrue(ToolKind.allCases.contains(.lasso))
        XCTAssertEqual(ToolKind.allCases.count, 6)

        // Legacy annotations containing fountain pen, brush pen, and highlighter still decode cleanly.
        let legacyStrokesJSON = """
        [
          {"id":"11111111-1111-1111-1111-111111111111","pen":"fountain","color":{"r":0.1,"g":0.1,"b":0.1,"a":1},"width":2,"smoothing":0.4,"points":[{"x":0,"y":0,"force":0.5,"azimuth":0,"altitude":1.5,"t":0},{"x":40,"y":0,"force":0.5,"azimuth":0,"altitude":1.5,"t":0.1}]},
          {"id":"22222222-2222-2222-2222-222222222222","pen":"brush","color":{"r":0.8,"g":0.1,"b":0.1,"a":1},"width":3,"smoothing":0.4,"points":[{"x":0,"y":20,"force":0.5,"azimuth":0,"altitude":1.5,"t":0},{"x":40,"y":20,"force":0.5,"azimuth":0,"altitude":1.5,"t":0.1}]},
          {"id":"33333333-3333-3333-3333-333333333333","pen":"ballpoint","color":{"r":1,"g":0.88,"b":0.2,"a":1},"width":14,"smoothing":0.7,"tool":"highlighter","points":[{"x":0,"y":40,"force":0.5,"azimuth":0,"altitude":1.5,"t":0},{"x":60,"y":40,"force":0.5,"azimuth":0,"altitude":1.5,"t":0.1}]}
        ]
        """
        let decoded = try JSONDecoder().decode([InkStroke].self, from: Data(legacyStrokesJSON.utf8))
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].pen, .fountain)
        XCTAssertEqual(decoded[1].pen, .brush)
        XCTAssertTrue(decoded[2].isHighlighter)
        for s in decoded {
            XCTAssertFalse(s.outlinePath().boundingBox.isNull)
        }

        // Enabling compass while on Lasso switches cleanly to Pen.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lasso-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "lasso", pdfData: Data(), layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        session.tool.select(.lasso)
        session.toggleGeometryAid(.compass)
        XCTAssertEqual(session.tool.kind, .pen)
    }
}
