import CoreGraphics
import UIKit
import XCTest
@testable import Quillmark

final class GeometryConstructionTests: XCTestCase {
    private func subpathCount(in path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { elementPointer in
            if elementPointer.pointee.type == .moveToPoint {
                count += 1
            }
        }
        return count
    }

    // MARK: Parametric Primitives & Persistence

    func testGeometricPrimitiveRoundTripAndTranslation() throws {
        let primitives: [GeometricPrimitive] = [
            .segment(a: CGPoint(x: 10, y: 20), b: CGPoint(x: 110, y: 80), startArrow: .none, endArrow: .open),
            .circle(center: CGPoint(x: 100, y: 100), radius: 50, showCenterMark: true),
            .arc(center: CGPoint(x: 120, y: 120), radius: 60, startAngle: 0, endAngle: .pi / 2, clockwise: true, showCenterMark: true),
            .ellipse(center: CGPoint(x: 80, y: 90), rx: 40, ry: 20, rotation: 0.4),
            .polygon(vertices: [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 25, y: 40)], closed: true),
        ]
        for prim in primitives {
            let stroke = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0,
                                   points: [], tool: .pen, lineStyle: .solid, geometry: prim)
            let data = try JSONEncoder().encode(stroke)
            let decoded = try JSONDecoder().decode(InkStroke.self, from: data)
            XCTAssertEqual(decoded.geometry, prim)

            let shifted = decoded.translated(by: CGPoint(x: 30, y: -15))
            XCTAssertEqual(shifted.geometry, prim.translated(by: CGPoint(x: 30, y: -15)))
            XCTAssertFalse(shifted.outlinePath().boundingBox.isNull)
        }
    }

    func testCircleCenterMarkCreatesSeparateSubpathAndEraserSplitsCleanly() {
        let withMark = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: [],
                                 tool: .pen, lineStyle: .solid,
                                 geometry: .circle(center: CGPoint(x: 100, y: 100), radius: 50, showCenterMark: true))
        let withoutMark = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: [],
                                    tool: .pen, lineStyle: .solid,
                                    geometry: .circle(center: CGPoint(x: 100, y: 100), radius: 50, showCenterMark: false))

        XCTAssertEqual(subpathCount(in: withMark.outlinePath()), 2)
        XCTAssertEqual(subpathCount(in: withoutMark.outlinePath()), 1)

        // Pixel-erasing part of a parametric circle clears `geometry` on the remaining fragments.
        let cache = StrokeGeometryCache()
        let pixel = EraserEngine.erase([withoutMark], from: CGPoint(x: 150, y: 95), to: CGPoint(x: 150, y: 105),
                                       radius: 10, mode: .pixel, highlighterOnly: false, cache: cache)
        XCTAssertTrue(pixel.changed)
        XCTAssertFalse(pixel.strokes.isEmpty)
        XCTAssertTrue(pixel.strokes.allSatisfy { $0.geometry == nil && !($0.baked ?? []).isEmpty })

        // Stroke-erasing removes the whole circle.
        let whole = EraserEngine.erase([withoutMark], from: CGPoint(x: 150, y: 100), to: CGPoint(x: 150, y: 100),
                                       radius: 6, mode: .stroke, highlighterOnly: false, cache: cache)
        XCTAssertTrue(whole.changed)
        XCTAssertTrue(whole.strokes.isEmpty)
    }

    // MARK: Analytic Intersections & Compass-and-Straightedge Bisector

    func testPerpendicularBisectorCircleIntersections() {
        // Classic 3-4-5 construction: A=(100,200), B=(300,200), r=125 -> intersections at (200,125) and (200,275).
        let a = CGPoint(x: 100, y: 200)
        let b = CGPoint(x: 300, y: 200)
        let primitives: [GeometricPrimitive] = [
            .segment(a: a, b: b),
            .circle(center: a, radius: 125, showCenterMark: true),
            .circle(center: b, radius: 125, showCenterMark: true),
        ]
        let snaps = GeometrySnapEngine.snapPoints(from: primitives)
        let intersections = snaps.filter { $0.kind == .intersection }

        XCTAssertTrue(intersections.contains { hypot($0.point.x - 200, $0.point.y - 125) < 0.5 },
                      "expected top intersection (200, 125)")
        XCTAssertTrue(intersections.contains { hypot($0.point.x - 200, $0.point.y - 275) < 0.5 },
                      "expected bottom intersection (200, 275)")
    }

    func testSegmentAndArcIntersectionsRespectArcSpan() {
        // Horizontal line through circle center (100,100), r=50 crosses at (50,100) [π] and (150,100) [0].
        // Top-right arc from -π/2 to +π/2 only contains (150,100), NOT (50,100).
        let seg = GeometrySnapEngine.Segment(a: CGPoint(x: 20, y: 100), b: CGPoint(x: 180, y: 100))
        let rightArc = GeometrySnapEngine.CircularCurve(center: CGPoint(x: 100, y: 100), radius: 50,
                                                        startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        let hits = GeometrySnapEngine.intersect(seg, rightArc)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].x, 150, accuracy: 0.1)
        XCTAssertEqual(hits[0].y, 100, accuracy: 0.1)

        // Segment x Segment crossing at (60, 60)
        let s1 = GeometrySnapEngine.Segment(a: CGPoint(x: 20, y: 20), b: CGPoint(x: 100, y: 100))
        let s2 = GeometrySnapEngine.Segment(a: CGPoint(x: 20, y: 100), b: CGPoint(x: 100, y: 20))
        let cross = GeometrySnapEngine.intersect(s1, s2)
        XCTAssertEqual(cross?.x ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(cross?.y ?? 0, 60, accuracy: 0.01)
    }

    // MARK: One-Handed Virtual Compass & Sweep

    func testCompassSnapResizeLockAndSweep() {
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        var compass = CompassState(center: CGPoint(x: 400, y: 400), radius: 100, armAngle: 0,
                                   isRadiusLocked: false, showCenterMark: true)

        XCTAssertEqual(compass.hitTest(CGPoint(x: 400, y: 400), in: bounds), .needle)
        XCTAssertEqual(compass.hitTest(compass.resizeHandleCenter, in: bounds), .resizeHandle)
        XCTAssertEqual(compass.hitTest(compass.penFoot, in: bounds), .drawCircle)

        let buttons = compass.buttonFrames(in: bounds)
        XCTAssertEqual(compass.hitTest(CGPoint(x: buttons.lock.midX, y: buttons.lock.midY), in: bounds), .lockButton)
        XCTAssertEqual(compass.hitTest(CGPoint(x: buttons.centerMark.midX, y: buttons.centerMark.midY), in: bounds), .centerMarkButton)
        XCTAssertEqual(compass.hitTest(CGPoint(x: buttons.fullCircle.midX, y: buttons.fullCircle.midY), in: bounds), .fullCircleButton)

        // Snap needle onto A=(250, 300), then measure exact distance to B=(400, 300) -> radius == 150.
        let pointA = CGPoint(x: 250, y: 300)
        let pointB = CGPoint(x: 400, y: 300)
        let snaps = [SnapPoint(point: pointA, kind: .endpoint), SnapPoint(point: pointB, kind: .endpoint)]
        let snappedCenter = compass.moveCenter(to: CGPoint(x: 254, y: 298), snapPoints: snaps)
        XCTAssertEqual(snappedCenter?.point, pointA)
        XCTAssertEqual(compass.center, pointA)

        let snappedRadius = compass.resize(withHandleAt: CGPoint(x: 396, y: 302), snapPoints: snaps)
        XCTAssertEqual(snappedRadius?.point, pointB)
        XCTAssertEqual(compass.radius, 150, accuracy: 0.01)

        // Locking radius prevents any resize and disables resize hit zone.
        compass.isRadiusLocked = true
        _ = compass.resize(withHandleAt: CGPoint(x: 500, y: 300), snapPoints: snaps)
        XCTAssertEqual(compass.radius, 150, accuracy: 0.01)
        XCTAssertNotEqual(compass.hitTest(compass.resizeHandleCenter, in: bounds), .resizeHandle)

        // Sweep 90° crossing the ±π branch cut (135° -> 225° in UIKit angles) -> produces an arc.
        var arcSweep = CompassSweep(startAngle: 135 * .pi / 180)
        for deg in stride(from: 150.0, through: 225.0, by: 15.0) {
            let rad = CGFloat(deg) * .pi / 180
            arcSweep.advance(to: CGPoint(x: 250 + 150 * cos(rad), y: 300 + 150 * sin(rad)), center: pointA)
        }
        XCTAssertEqual(arcSweep.sweepDegrees, 90)
        XCTAssertFalse(arcSweep.isFullCircle)
        guard case let .arc(_, r, _, _, cw, mark) = arcSweep.primitive(center: pointA, radius: 150, showCenterMark: true) else {
            return XCTFail("Expected partial arc")
        }
        XCTAssertEqual(r, 150, accuracy: 0.01)
        XCTAssertTrue(cw)
        XCTAssertTrue(mark)

        // Sweep 355° -> auto-closes into a full circle!
        var fullSweep = CompassSweep(startAngle: 0)
        for deg in stride(from: 15.0, through: 355.0, by: 15.0) {
            let rad = CGFloat(deg) * .pi / 180
            fullSweep.advance(to: CGPoint(x: 250 + 150 * cos(rad), y: 300 + 150 * sin(rad)), center: pointA)
        }
        XCTAssertTrue(fullSweep.isFullCircle)
        guard case let .circle(center, radius, _) = fullSweep.primitive(center: pointA, radius: 150, showCenterMark: true) else {
            return XCTFail("Expected auto-closed circle")
        }
        XCTAssertEqual(center, pointA)
        XCTAssertEqual(radius, 150, accuracy: 0.01)
    }

    func testOverlayPassesThroughNonControlPointsAndSessionTogglesCompass() throws {
        let overlay = GeometryToolOverlayView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        overlay.compass = CompassState(center: CGPoint(x: 500, y: 400), radius: 100, armAngle: 0)
        overlay.aid = .compass
        XCTAssertTrue(overlay.point(inside: CGPoint(x: 500, y: 400), with: nil), "needle handle intercepts")
        XCTAssertFalse(overlay.point(inside: CGPoint(x: 600, y: 400), with: nil), "draw circle passes finger scrolling through")
        XCTAssertFalse(overlay.point(inside: CGPoint(x: 50, y: 50), with: nil))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "aid", pdfData: Data(), layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        session.tool.select(.eraser)
        session.toggleGeometryAid(.compass)
        XCTAssertEqual(session.geometryAid, .compass)
        XCTAssertEqual(session.tool.kind, .pen, "enabling compass switches away from eraser to pen")
        session.toggleGeometryAid(.compass)
        XCTAssertEqual(session.geometryAid, .none)
    }
}
