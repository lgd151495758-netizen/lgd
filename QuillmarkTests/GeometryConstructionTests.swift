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
            .parabola(vertex: CGPoint(x: 120, y: 180), axisAngle: -.pi / 2, halfWidth: 60, height: 90),
            .axes(origin: CGPoint(x: 150, y: 150), xMin: -80, xMax: 100, yMin: -90, yMax: 70, tickSpacing: 25),
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

    // MARK: v0.8 Standard Math Shapes, Shading & Vertex Editing

    func testAllStandardShapePresetsBuildValidGeometryAndInvariants() {
        let start = CGPoint(x: 40, y: 40)
        let end = CGPoint(x: 200, y: 160)

        for preset in ShapePreset.allCases {
            let built = ShapeBuilder.build(preset: preset, from: start, to: end)
            let fill: RGBAColor? = preset.supportsFill ? ToolSettings.palette[1] : nil
            let stroke = InkStroke(id: UUID(), pen: .ballpoint, color: ToolSettings.palette[1], width: 2,
                                   smoothing: 0, points: [], tool: .pen, lineStyle: .solid,
                                   geometry: built.primitive, fillColor: fill)
            let outlineBox = stroke.outlinePath().boundingBox
            XCTAssertFalse(outlineBox.isNull, "preset \(preset) must produce non-null outline")
            XCTAssertTrue(outlineBox.width.isFinite && outlineBox.height.isFinite)
            XCTAssertGreaterThan(built.primitive.controlHandles().count, 1)
            XCTAssertEqual(stroke.fillPath() != nil, preset.supportsFill)
        }

        // Exact equilateral triangle: all 3 sides equal.
        if case let .polygon(v, true) = ShapeBuilder.build(preset: .equilateralTriangle, from: start, to: end).primitive {
            XCTAssertEqual(v.count, 3)
            let s01 = hypot(v[1].x - v[0].x, v[1].y - v[0].y)
            let s12 = hypot(v[2].x - v[1].x, v[2].y - v[1].y)
            let s20 = hypot(v[0].x - v[2].x, v[0].y - v[2].y)
            XCTAssertEqual(s01, s12, accuracy: 0.01)
            XCTAssertEqual(s12, s20, accuracy: 0.01)
        } else {
            XCTFail("Expected equilateral triangle polygon")
        }

        // Exact right triangle: legs perpendicular (dot product == 0).
        if case let .polygon(v, true) = ShapeBuilder.build(preset: .rightTriangle, from: start, to: end).primitive {
            let leg1 = CGPoint(x: v[0].x - v[1].x, y: v[0].y - v[1].y)
            let leg2 = CGPoint(x: v[2].x - v[1].x, y: v[2].y - v[1].y)
            XCTAssertEqual(leg1.x * leg2.x + leg1.y * leg2.y, 0, accuracy: 0.01)
        } else {
            XCTFail("Expected right triangle polygon")
        }

        // Exact rhombus: all 4 sides equal.
        if case let .polygon(v, true) = ShapeBuilder.build(preset: .rhombus, from: start, to: end).primitive {
            XCTAssertEqual(v.count, 4)
            let sides = (0..<4).map { i -> CGFloat in
                let a = v[i], b = v[(i + 1) % 4]
                return hypot(b.x - a.x, b.y - a.y)
            }
            XCTAssertEqual(sides[0], sides[1], accuracy: 0.01)
            XCTAssertEqual(sides[1], sides[2], accuracy: 0.01)
            XCTAssertEqual(sides[2], sides[3], accuracy: 0.01)
        } else {
            XCTFail("Expected rhombus polygon")
        }

        // Near-square rectangle snaps to exact square.
        if case let .polygon(v, true) = ShapeBuilder.build(preset: .rectangle,
                                                           from: CGPoint(x: 10, y: 10),
                                                           to: CGPoint(x: 112, y: 110)).primitive {
            let w = hypot(v[1].x - v[0].x, v[1].y - v[0].y)
            let h = hypot(v[2].x - v[1].x, v[2].y - v[1].y)
            XCTAssertEqual(w, h, accuracy: 0.01)
        } else {
            XCTFail("Expected square rectangle")
        }

        // Regular pentagon & regular hexagon presets produce exact equal sides.
        for (preset, expectedSides) in [(ShapePreset.pentagon, 5), (ShapePreset.hexagon, 6)] {
            if case let .polygon(v, true) = ShapeBuilder.build(preset: preset, from: start, to: end).primitive {
                XCTAssertEqual(v.count, expectedSides)
                let sides = (0..<expectedSides).map { i -> CGFloat in
                    let a = v[i], b = v[(i + 1) % expectedSides]
                    return hypot(b.x - a.x, b.y - a.y)
                }
                for s in sides.dropFirst() {
                    XCTAssertEqual(s, sides[0], accuracy: 0.01)
                }
            } else {
                XCTFail("Expected regular \(expectedSides)-gon for \(preset)")
            }
        }

        // Parabola preset: vertex at start, opens UP when dragged upward, DOWN when dragged downward.
        if case let .parabola(vUp, aUp, hwUp, hUp) = ShapeBuilder.build(preset: .parabola,
                                                                        from: CGPoint(x: 200, y: 200),
                                                                        to: CGPoint(x: 270, y: 110)).primitive {
            XCTAssertEqual(vUp, CGPoint(x: 200, y: 200))
            XCTAssertEqual(aUp, -CGFloat.pi / 2, accuracy: 0.01)
            XCTAssertEqual(hwUp, 70, accuracy: 0.01)
            XCTAssertEqual(hUp, 90, accuracy: 0.01)
        } else {
            XCTFail("Expected upward parabola preset")
        }
        if case let .parabola(_, aDown, _, _) = ShapeBuilder.build(preset: .parabola,
                                                                   from: CGPoint(x: 200, y: 200),
                                                                   to: CGPoint(x: 270, y: 290)).primitive {
            XCTAssertEqual(aDown, CGFloat.pi / 2, accuracy: 0.01)
        } else {
            XCTFail("Expected downward parabola preset")
        }
    }

    func testVertexEditingSnappingAxesHandlesAndOverlayHitTesting() {
        let tri = GeometricPrimitive.polygon(vertices: [
            CGPoint(x: 100, y: 40),
            CGPoint(x: 180, y: 160),
            CGPoint(x: 20, y: 160),
        ], closed: true)
        XCTAssertTrue(tri.hitTestBody(CGPoint(x: 100, y: 120)))
        XCTAssertFalse(tri.hitTestBody(CGPoint(x: 300, y: 300)))

        // Dragging vertex 0 near an intersection snaps straight to it.
        let targetSnap = SnapPoint(point: CGPoint(x: 130, y: 55), kind: .intersection)
        let moved = tri.movingHandle(at: 0, to: CGPoint(x: 133, y: 52), snapPoints: [targetSnap], snapThreshold: 10)
        XCTAssertEqual(moved.snapped, targetSnap)
        if case let .polygon(verts, _) = moved.primitive {
            XCTAssertEqual(verts[0], targetSnap.point)
        } else {
            XCTFail("Expected polygon")
        }

        // Axes origin handle slides origin while preserving outer frame; right arm extends cleanly.
        let axes = GeometricPrimitive.axes(origin: CGPoint(x: 200, y: 200),
                                           xMin: -100, xMax: 100, yMin: -100, yMax: 100, tickSpacing: 25)
        let origBox = axes.boundingBox()
        let shiftedOrigin = axes.movingHandle(at: 0, to: CGPoint(x: 170, y: 230), snapPoints: []).primitive
        XCTAssertEqual(shiftedOrigin.boundingBox().minX, origBox.minX, accuracy: 0.01)
        XCTAssertEqual(shiftedOrigin.boundingBox().maxX, origBox.maxX, accuracy: 0.01)
        XCTAssertEqual(shiftedOrigin.boundingBox().minY, origBox.minY, accuracy: 0.01)
        XCTAssertEqual(shiftedOrigin.boundingBox().maxY, origBox.maxY, accuracy: 0.01)

        // Axes participate in snap points with origin as `.center`.
        let axisSnaps = GeometrySnapEngine.snapPoints(from: [axes])
        XCTAssertTrue(axisSnaps.contains { $0.kind == .center && $0.point == CGPoint(x: 200, y: 200) })

        // Parabola vertex snaps onto axes origin O; arm handle flips opening direction across vertex.
        let para = GeometricPrimitive.parabola(vertex: CGPoint(x: 196, y: 203), axisAngle: -.pi / 2,
                                               halfWidth: 60, height: 80)
        XCTAssertTrue(para.hitTestBody(CGPoint(x: 196, y: 203)))
        XCTAssertFalse(para.hitTestBody(CGPoint(x: 400, y: 400)))
        let snappedPara = para.movingHandle(at: 0, to: CGPoint(x: 197, y: 202), snapPoints: axisSnaps, snapThreshold: 10)
        XCTAssertEqual(snappedPara.snapped?.point, CGPoint(x: 200, y: 200))
        let flippedPara = snappedPara.primitive.movingHandle(at: 1, to: CGPoint(x: 280, y: 310), snapPoints: [])
        if case let .parabola(fv, fa, fhw, fh) = flippedPara.primitive {
            XCTAssertEqual(fv, CGPoint(x: 200, y: 200))
            XCTAssertEqual(fa, CGFloat.pi / 2, accuracy: 0.01)
            XCTAssertEqual(fhw, 80, accuracy: 0.01)
            XCTAssertEqual(fh, 110, accuracy: 0.01)
        } else {
            XCTFail("Expected flipped parabola")
        }

        // SelectedShapeOverlay hit-tests handles & action bar accurately.
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let overlay = SelectedShapeOverlay(strokeID: UUID(), handles: tri.controlHandles(),
                                           boundingBox: tri.boundingBox(), lineStyle: .solid,
                                           supportsFill: true, isFilled: false,
                                           isCircularWithCenterMark: false, showsCenterMark: false)
        XCTAssertEqual(overlay.hitTest(CGPoint(x: 100, y: 40), in: bounds, bodyHit: true), .handle(0))
        let buttons = overlay.actionButtons(in: bounds)
        XCTAssertEqual(buttons.count, 4)
        let fillBtn = buttons[1]
        XCTAssertEqual(overlay.hitTest(CGPoint(x: fillBtn.1.midX, y: fillBtn.1.midY), in: bounds, bodyHit: false),
                       .action(.toggleFillOrCenter))
    }

    // MARK: v1.5.2 Smart Auto-Measuring Protractor

    func testProtractorStateAnglesHitTestingReflexAndStamping() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        var pro = ProtractorState(center: CGPoint(x: 420, y: 380), radius: 132,
                                  ray1Angle: 0, ray2Angle: -.pi / 3)

        // Default 60° readout & reflex toggle (60° <-> 300°).
        XCTAssertEqual(pro.measuredDegrees, 60.0, accuracy: 0.05)
        XCTAssertEqual(pro.formattedDegrees, "60°")
        XCTAssertFalse(pro.isRightAngle)
        pro.cycleAngle()
        XCTAssertTrue(pro.measureReflex)
        XCTAssertEqual(pro.measuredDegrees, 300.0, accuracy: 0.05)
        pro.cycleAngle()
        XCTAssertFalse(pro.measureReflex)
        XCTAssertEqual(pro.measuredDegrees, 60.0, accuracy: 0.05)

        // Rotating both rays together preserves the exact measured angle.
        pro.rotateBoth(by: 0.73)
        XCTAssertEqual(pro.measuredDegrees, 60.0, accuracy: 0.05)

        // Hit-testing all handles, outer ring, and floating action bar buttons.
        XCTAssertEqual(pro.hitTest(pro.center, in: bounds), .center)
        XCTAssertEqual(pro.hitTest(pro.ray1HandleCenter, in: bounds), .ray1Handle)
        XCTAssertEqual(pro.hitTest(pro.ray2HandleCenter, in: bounds), .ray2Handle)
        let buttons = pro.buttonFrames(in: bounds)
        XCTAssertEqual(pro.hitTest(CGPoint(x: buttons.autoDetect.midX, y: buttons.autoDetect.midY), in: bounds), .autoDetectButton)
        XCTAssertEqual(pro.hitTest(CGPoint(x: buttons.cycleAngle.midX, y: buttons.cycleAngle.midY), in: bounds), .cycleAngleButton)
        XCTAssertEqual(pro.hitTest(CGPoint(x: buttons.stampAngle.midX, y: buttons.stampAngle.midY), in: bounds), .stampAngleButton)
        XCTAssertEqual(pro.hitTest(CGPoint(x: buttons.close.midX, y: buttons.close.midY), in: bounds), .closeButton)

        // Non-90° stamp produces a permanent vector arc.
        guard case .arc = pro.stampPrimitive(center: pro.center, radius: 32) else {
            return XCTFail("Expected .arc primitive for 60° angle stamp")
        }

        // Exact 90° angle displays right-angle indicator and stamps a crisp ∟ 3-point open polyline.
        pro.ray1Angle = 0
        pro.ray2Angle = -.pi / 2
        XCTAssertTrue(pro.isRightAngle)
        XCTAssertEqual(pro.formattedDegrees, "90° 直角")
        guard case let .polygon(verts, false) = pro.stampPrimitive(center: pro.center, radius: 32) else {
            return XCTFail("Expected 3-vertex open polyline ∟ for 90° stamp")
        }
        XCTAssertEqual(verts.count, 3)

        // Overlay intercepts protractor handles and passes unrelated touches through.
        let overlay = GeometryToolOverlayView(frame: bounds)
        overlay.protractor = pro
        overlay.aid = .protractor
        XCTAssertTrue(overlay.point(inside: pro.center, with: nil))
        XCTAssertTrue(overlay.point(inside: pro.ray2HandleCenter, with: nil))
        XCTAssertFalse(overlay.point(inside: CGPoint(x: 40, y: 40), with: nil))

        // Session switches cleanly between compass and protractor via shared aid state.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pro-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(root: root)
        let meta = try library.createDocument(title: "pro", pdfData: Data(), layout: .live,
                                              sourceKind: .htmlFile, sourceURL: nil, stagedSource: nil)
        let session = DocumentSession(meta: meta, library: library, tool: ToolSettings())
        session.toggleGeometryAid(.compass)
        XCTAssertEqual(session.geometryAid, .compass)
        session.toggleGeometryAid(.protractor)
        XCTAssertEqual(session.geometryAid, .protractor)
        session.toggleGeometryAid(.protractor)
        XCTAssertEqual(session.geometryAid, .none)
    }

    func testProtractorVectorAutoAngleDetectionOnTrianglesCrossingsAndFreehand() {
        // 1. Equilateral triangle vertex -> exact 60.0°
        let eqPrim = ShapeBuilder.build(preset: .equilateralTriangle,
                                        from: CGPoint(x: 100, y: 100),
                                        to: CGPoint(x: 260, y: 240)).primitive
        guard case let .polygon(eqVerts, true) = eqPrim else {
            return XCTFail("Expected equilateral triangle")
        }
        let eqStroke = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0,
                                 points: [], tool: .pen, lineStyle: .solid, geometry: eqPrim)
        let eqRays = ProtractorAngleDetector.detectVectorRays(at: eqVerts[0], from: [eqStroke])
        var pro = ProtractorState(center: eqVerts[0])
        XCTAssertTrue(pro.applyDetectedRays(eqRays, source: .vector))
        XCTAssertEqual(pro.measuredDegrees, 60.0, accuracy: 0.05)

        // 2. X-intersection at 50° / 130° -> starts at 50°, cycles to supplementary 130°!
        let crossCenter = CGPoint(x: 300, y: 300)
        let rad50 = 50.0 * CGFloat.pi / 180
        let seg1 = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: [], tool: .pen,
                             geometry: .segment(a: CGPoint(x: 180, y: 300), b: CGPoint(x: 420, y: 300)))
        let seg2 = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: [], tool: .pen,
                             geometry: .segment(a: CGPoint(x: crossCenter.x - 100 * cos(rad50), y: crossCenter.y - 100 * sin(rad50)),
                                                b: CGPoint(x: crossCenter.x + 100 * cos(rad50), y: crossCenter.y + 100 * sin(rad50))))
        let crossRays = ProtractorAngleDetector.detectVectorRays(at: crossCenter, from: [seg1, seg2])
        XCTAssertEqual(crossRays.count, 4)
        XCTAssertTrue(pro.applyDetectedRays(crossRays, source: .vector))
        XCTAssertEqual(pro.measuredDegrees, 50.0, accuracy: 0.05)
        pro.cycleAngle()
        XCTAssertEqual(pro.measuredDegrees, 130.0, accuracy: 0.05)

        // 3. Hand-drawn straight strokes forming a 45° corner.
        let v = CGPoint(x: 200, y: 200)
        let rawH = (0...10).map { i in InkPoint(x: Float(v.x) + Float(i * 10), y: Float(v.y)) }
        let rawD = (0...10).map { i in InkPoint(x: Float(v.x) + Float(i * 8), y: Float(v.y) - Float(i * 8)) }
        let sH = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: rawH, tool: .pen)
        let sD = InkStroke(id: UUID(), pen: .ballpoint, color: .ink, width: 2, smoothing: 0, points: rawD, tool: .pen)
        let freeRays = ProtractorAngleDetector.detectVectorRays(at: v, from: [sH, sD])
        XCTAssertTrue(pro.applyDetectedRays(freeRays, source: .vector))
        XCTAssertEqual(pro.measuredDegrees, 45.0, accuracy: 0.5)
    }

    func testProtractorImageAutoAngleDetectionOnLightAndDarkDiagrams() throws {
        func renderAnglePatch(background: UIColor, stroke: UIColor, vertex: CGPoint,
                              anglesDeg: [CGFloat], addLabelNoise: Bool) -> CGImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 144, height: 144), format: format)
            let image = renderer.image { rendererCtx in
                let ctx = rendererCtx.cgContext
                background.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 144, height: 144))

                ctx.setStrokeColor(stroke.cgColor)
                ctx.setLineWidth(2.2)
                ctx.setLineCap(.round)
                for deg in anglesDeg {
                    let rad = deg * .pi / 180
                    ctx.move(to: vertex)
                    ctx.addLine(to: CGPoint(x: vertex.x + 68 * cos(rad), y: vertex.y + 68 * sin(rad)))
                }
                ctx.strokePath()

                if addLabelNoise {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: stroke,
                    ]
                    ("A" as NSString).draw(at: CGPoint(x: vertex.x - 18, y: vertex.y - 6), withAttributes: attrs)
                }
            }
            return image.cgImage!
        }

        // 1. Light PDF diagram: asymmetric 60° angle (0° right, -60° up-right) + nearby "A" text noise,
        //    with user drop point intentionally 4px off the exact corner!
        let trueVertex = CGPoint(x: 72, y: 72)
        let lightPatch = renderAnglePatch(background: .white, stroke: .black,
                                          vertex: trueVertex, anglesDeg: [0, -60], addLabelNoise: true)
        let droppedPoint = CGPoint(x: 76, y: 74)
        let lightDetected = try XCTUnwrap(ProtractorAngleDetector.detectImageRays(in: lightPatch, center: droppedPoint))
        var pro = ProtractorState(center: droppedPoint)
        XCTAssertTrue(pro.applyDetectedRays(lightDetected.rayAngles, source: .image))
        XCTAssertEqual(pro.measuredDegrees, 60.0, accuracy: 1.5,
                       "printed light PDF 60° corner should auto-measure accurately even when dropped slightly off-center")

        // 2. Dark HTML courseware diagram: chalk-white 90° corner on charcoal dark canvas.
        let darkPatch = renderAnglePatch(background: UIColor(white: 0.10, alpha: 1),
                                         stroke: UIColor(white: 0.96, alpha: 1),
                                         vertex: trueVertex, anglesDeg: [20, 110], addLabelNoise: false)
        let darkDetected = try XCTUnwrap(ProtractorAngleDetector.detectImageRays(in: darkPatch, center: trueVertex))
        XCTAssertTrue(pro.applyDetectedRays(darkDetected.rayAngles, source: .image))
        XCTAssertEqual(pro.measuredDegrees, 90.0, accuracy: 1.5,
                       "dark-theme HTML 90° corner should auto-measure accurately")
    }
}
