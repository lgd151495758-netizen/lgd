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

    func testRecognizesStraightLineWithFineHorizontalVerticalSnapOnly() {
        // 1.5° off horizontal -> snaps cleanly to 0°.
        let nearFlatY = 100 + 200 * tan(1.5 * CGFloat.pi / 180)
        let nearFlat = polylinePoints([CGPoint(x: 20, y: 100), CGPoint(x: 220, y: nearFlatY)])
        guard case let .line(start, end) = ShapeRecognizer.recognize(nearFlat) else {
            return XCTFail("Expected straight line")
        }
        XCTAssertEqual(start.x, 20, accuracy: 0.5)
        XCTAssertEqual(start.y, 100, accuracy: 0.5)
        XCTAssertEqual(end.y, 100, accuracy: 0.5, "1.5° line should snap to horizontal")

        // 3.5° off horizontal -> must NOT be pulled flat to 0° (fine control).
        let slightSlopeY = 100 + 200 * tan(3.5 * CGFloat.pi / 180)
        let slightSlope = polylinePoints([CGPoint(x: 20, y: 100), CGPoint(x: 220, y: slightSlopeY)])
        guard case let .line(_, slopeEnd) = ShapeRecognizer.recognize(slightSlope) else {
            return XCTFail("Expected slightly sloped line")
        }
        XCTAssertEqual(slopeEnd.y, slightSlopeY, accuracy: 0.5, "3.5° line must preserve its slope")

        // Live drag adjustment at 2.0° off horizontal must stay free (tolerance is 1.2°);
        // at 0.8° off horizontal it snaps cleanly to 0°.
        let base = RecognizedShape.line(start: CGPoint(x: 0, y: 100), end: CGPoint(x: 200, y: 100))
        let drag2deg = CGPoint(x: 200, y: 100 + 200 * tan(2.0 * CGFloat.pi / 180))
        if case let .line(_, adj2) = base.adjusted(to: drag2deg, initialAnchor: CGPoint(x: 200, y: 100)) {
            XCTAssertEqual(adj2.y, drag2deg.y, accuracy: 0.1, "2° live drag must not stick to 0°")
        } else {
            XCTFail("Expected adjusted line")
        }
        let drag44deg = CGPoint(x: 200 * cos(44 * CGFloat.pi / 180), y: 100 + 200 * sin(44 * CGFloat.pi / 180))
        if case let .line(_, adj44) = base.adjusted(to: drag44deg, initialAnchor: CGPoint(x: 200, y: 100)) {
            XCTAssertEqual(adj44.x, drag44deg.x, accuracy: 0.1, "44° must not snap to 45°")
            XCTAssertEqual(adj44.y, drag44deg.y, accuracy: 0.1)
        } else {
            XCTFail("Expected adjusted line")
        }
        let drag08deg = CGPoint(x: 200, y: 100 + 200 * tan(0.8 * CGFloat.pi / 180))
        if case let .line(_, adj08) = base.adjusted(to: drag08deg, initialAnchor: CGPoint(x: 200, y: 100)) {
            XCTAssertEqual(adj08.y, 100, accuracy: 0.01, "0.8° live drag should snap to 0°")
        } else {
            XCTFail("Expected adjusted line")
        }
        let drag89deg = CGPoint(x: 200 * cos(89.2 * CGFloat.pi / 180), y: 100 + 200 * sin(89.2 * CGFloat.pi / 180))
        if case let .line(_, adj89) = base.adjusted(to: drag89deg, initialAnchor: CGPoint(x: 200, y: 100)) {
            XCTAssertEqual(adj89.x, 0, accuracy: 0.01, "89.2° live drag should snap to 90°")
        } else {
            XCTFail("Expected adjusted line")
        }
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

    func testRecognizesCircleAndNeverEmitsEllipse() {
        let circlePts = (0...64).map { i -> CGPoint in
            let theta = 2 * CGFloat.pi * CGFloat(i) / 64
            return CGPoint(x: 150 + 60 * cos(theta), y: 150 + 57 * sin(theta))
        }
        guard case let .circle(center, radius) = ShapeRecognizer.recognize(circlePts) else {
            return XCTFail("Expected exact circle")
        }
        XCTAssertEqual(center.x, 150, accuracy: 3)
        XCTAssertEqual(center.y, 150, accuracy: 3)
        XCTAssertEqual(radius, 58.5, accuracy: 3)

        // Elongated oval must snap to an exact circle (never an ellipse).
        let ovalPts = (0...64).map { i -> CGPoint in
            let theta = 2 * CGFloat.pi * CGFloat(i) / 64
            return CGPoint(x: 200 + 90 * cos(theta), y: 120 + 40 * sin(theta))
        }
        guard case let .circle(ovalCenter, ovalRadius) = ShapeRecognizer.recognize(ovalPts) else {
            return XCTFail("Elongated oval must snap to circle, never ellipse")
        }
        XCTAssertEqual(ovalCenter.x, 200, accuracy: 4)
        XCTAssertEqual(ovalCenter.y, 120, accuracy: 4)
        XCTAssertGreaterThan(ovalRadius, 40)
    }

    func testRecognizesParabolaOpenDirectionsAndLiveFlip() {
        // 1. Upward-opening parabola (U-shape in UIKit +Y down): vertex (150, 200), halfW 80, height 128.
        let upPts = (0...48).map { i -> CGPoint in
            let s = -1 + 2 * CGFloat(i) / 48
            return CGPoint(x: 150 + 80 * s, y: 200 - 128 * s * s)
        }
        guard case let .parabola(upV, upAxis, upHW, upH) = ShapeRecognizer.recognize(upPts) else {
            return XCTFail("Expected upward parabola")
        }
        XCTAssertEqual(upV.x, 150, accuracy: 3)
        XCTAssertEqual(upV.y, 200, accuracy: 3)
        XCTAssertEqual(upAxis, -CGFloat.pi / 2, accuracy: 0.05)
        XCTAssertEqual(upHW, 80, accuracy: 5)
        XCTAssertEqual(upH, 128, accuracy: 6)

        // Plan A live drag: widen right arm -> vertex stays pinned, halfWidth/height update.
        let baseUp = RecognizedShape.parabola(vertex: CGPoint(x: 150, y: 200),
                                              axisAngle: -CGFloat.pi / 2, halfWidth: 80, height: 128)
        if case let .parabola(v1, a1, hw1, h1) = baseUp.adjusted(to: CGPoint(x: 270, y: 100),
                                                                 initialAnchor: CGPoint(x: 230, y: 72)) {
            XCTAssertEqual(v1, CGPoint(x: 150, y: 200))
            XCTAssertEqual(a1, -CGFloat.pi / 2, accuracy: 0.01)
            XCTAssertEqual(hw1, 120, accuracy: 0.5)
            XCTAssertEqual(h1, 100, accuracy: 0.5)
        } else {
            XCTFail("Expected widened parabola")
        }

        // Dragging below vertex flips opening direction smoothly to downward (+π/2).
        if case let .parabola(v2, a2, hw2, h2) = baseUp.adjusted(to: CGPoint(x: 230, y: 310),
                                                                 initialAnchor: CGPoint(x: 230, y: 72)) {
            XCTAssertEqual(v2, CGPoint(x: 150, y: 200))
            XCTAssertEqual(a2, CGFloat.pi / 2, accuracy: 0.01)
            XCTAssertEqual(hw2, 80, accuracy: 0.5)
            XCTAssertEqual(h2, 110, accuracy: 0.5)
        } else {
            XCTFail("Expected flipped downward parabola")
        }

        // 2. Downward-opening parabola (∩-shape).
        let downPts = (0...48).map { i -> CGPoint in
            let s = -1 + 2 * CGFloat(i) / 48
            return CGPoint(x: 150 + 70 * s, y: 80 + 110 * s * s)
        }
        guard case let .parabola(downV, downAxis, _, _) = ShapeRecognizer.recognize(downPts) else {
            return XCTFail("Expected downward parabola")
        }
        XCTAssertEqual(downV.x, 150, accuracy: 3)
        XCTAssertEqual(downV.y, 80, accuracy: 3)
        XCTAssertEqual(downAxis, CGFloat.pi / 2, accuracy: 0.05)

        // 3. Rightward-opening parabola (y² = 2px).
        let rightPts = (0...48).map { i -> CGPoint in
            let s = -1 + 2 * CGFloat(i) / 48
            return CGPoint(x: 100 + 120 * s * s, y: 140 + 80 * s)
        }
        guard case let .parabola(rV, rAxis, _, _) = ShapeRecognizer.recognize(rightPts) else {
            return XCTFail("Expected rightward parabola")
        }
        XCTAssertEqual(rV.x, 100, accuracy: 3)
        XCTAssertEqual(rV.y, 140, accuracy: 3)
        XCTAssertEqual(rAxis, 0, accuracy: 0.05)

        // 4. Tall narrow parabola must NOT be misclassified as a closed loop.
        let narrowPts = (0...48).map { i -> CGPoint in
            let s = -1 + 2 * CGFloat(i) / 48
            return CGPoint(x: 150 + 28 * s, y: 220 - 160 * s * s)
        }
        guard case .parabola = ShapeRecognizer.recognize(narrowPts) else {
            return XCTFail("Narrow tall parabola should remain a parabola, not a closed loop")
        }
    }

    func testDistinguishesRhombusParallelogramAndRectangle() {
        // 1. Upright diamond rhombus: exact 4 equal sides & perpendicular diagonals.
        let diamondPts = polylinePoints([
            CGPoint(x: 150, y: 40),
            CGPoint(x: 210, y: 120),
            CGPoint(x: 150, y: 200),
            CGPoint(x: 90, y: 120),
            CGPoint(x: 151, y: 42),
        ])
        guard case let .polygon(dVerts, _, _) = ShapeRecognizer.recognize(diamondPts) else {
            return XCTFail("Expected upright diamond rhombus")
        }
        XCTAssertEqual(dVerts.count, 4)
        let dSides = (0..<4).map { i -> CGFloat in
            let a = dVerts[i], b = dVerts[(i + 1) % 4]
            return hypot(b.x - a.x, b.y - a.y)
        }
        XCTAssertEqual(dSides[0], dSides[1], accuracy: 0.5)
        XCTAssertEqual(dSides[1], dSides[2], accuracy: 0.5)
        XCTAssertEqual(dSides[2], dSides[3], accuracy: 0.5)
        let dd1 = CGPoint(x: dVerts[2].x - dVerts[0].x, y: dVerts[2].y - dVerts[0].y)
        let dd2 = CGPoint(x: dVerts[3].x - dVerts[1].x, y: dVerts[3].y - dVerts[1].y)
        XCTAssertEqual(dd1.x * dd2.x + dd1.y * dd2.y, 0, accuracy: 1.0, "rhombus diagonals must be perpendicular")

        // 2. Slanted flat-base rhombus (60°/120°, all 4 sides = 100): exact equal sides & perpendicular diagonals.
        let slantedRhombusPts = polylinePoints([
            CGPoint(x: 120, y: 100),
            CGPoint(x: 220, y: 100),
            CGPoint(x: 170, y: 186.6),
            CGPoint(x: 70, y: 186.6),
            CGPoint(x: 121, y: 101),
        ])
        guard case let .polygon(srVerts, _, _) = ShapeRecognizer.recognize(slantedRhombusPts) else {
            return XCTFail("Expected slanted rhombus")
        }
        XCTAssertEqual(srVerts.count, 4)
        let srSides = (0..<4).map { i -> CGFloat in
            let a = srVerts[i], b = srVerts[(i + 1) % 4]
            return hypot(b.x - a.x, b.y - a.y)
        }
        XCTAssertEqual(srSides[0], srSides[1], accuracy: 0.5)
        XCTAssertEqual(srSides[1], srSides[2], accuracy: 0.5)
        XCTAssertEqual(srSides[2], srSides[3], accuracy: 0.5)
        let srd1 = CGPoint(x: srVerts[2].x - srVerts[0].x, y: srVerts[2].y - srVerts[0].y)
        let srd2 = CGPoint(x: srVerts[3].x - srVerts[1].x, y: srVerts[3].y - srVerts[1].y)
        XCTAssertEqual(srd1.x * srd2.x + srd1.y * srd2.y, 0, accuracy: 1.5, "slanted rhombus diagonals must be perpendicular")

        // 3. Ordinary parallelogram (160 x 87.3, slanted ~66°/114°): equal parallel opposite sides, unequal adjacent sides.
        let paraPts = polylinePoints([
            CGPoint(x: 100, y: 80),
            CGPoint(x: 260, y: 80),
            CGPoint(x: 225, y: 160),
            CGPoint(x: 65, y: 160),
            CGPoint(x: 101, y: 81),
        ])
        guard case let .polygon(pVerts, _, _) = ShapeRecognizer.recognize(paraPts) else {
            return XCTFail("Expected parallelogram polygon")
        }
        XCTAssertEqual(pVerts.count, 4)
        let topVec = CGPoint(x: pVerts[1].x - pVerts[0].x, y: pVerts[1].y - pVerts[0].y)
        let botVec = CGPoint(x: pVerts[2].x - pVerts[3].x, y: pVerts[2].y - pVerts[3].y)
        let rightVec = CGPoint(x: pVerts[2].x - pVerts[1].x, y: pVerts[2].y - pVerts[1].y)
        let leftVec = CGPoint(x: pVerts[3].x - pVerts[0].x, y: pVerts[3].y - pVerts[0].y)
        XCTAssertEqual(topVec.x, botVec.x, accuracy: 0.5)
        XCTAssertEqual(topVec.y, botVec.y, accuracy: 0.5)
        XCTAssertEqual(rightVec.x, leftVec.x, accuracy: 0.5)
        XCTAssertEqual(rightVec.y, leftVec.y, accuracy: 0.5)
        let pLong = max(hypot(topVec.x, topVec.y), hypot(rightVec.x, rightVec.y))
        let pShort = min(hypot(topVec.x, topVec.y), hypot(rightVec.x, rightVec.y))
        XCTAssertGreaterThan(pLong / pShort, 1.5, "parallelogram must preserve unequal side lengths")
        XCTAssertGreaterThan(abs(topVec.x * rightVec.x + topVec.y * rightVec.y), 1500,
                             "parallelogram must preserve slant rather than flattening to rectangle")

        // 4. Rectangle starting/ending at a corner -> Plan A corner drag stretches width & height independently.
        let cornerRectPts = polylinePoints([
            CGPoint(x: 50, y: 50),
            CGPoint(x: 250, y: 50),
            CGPoint(x: 250, y: 150),
            CGPoint(x: 50, y: 150),
            CGPoint(x: 51, y: 51),
        ])
        guard case let .rectangle(rc, rw, rh, _, _) = ShapeRecognizer.recognize(cornerRectPts),
              let rectShape = ShapeRecognizer.recognize(cornerRectPts) else {
            return XCTFail("Expected rectangle")
        }
        XCTAssertEqual(rc.x, 150, accuracy: 2)
        XCTAssertEqual(rc.y, 100, accuracy: 2)
        XCTAssertEqual(rw, 200, accuracy: 4)
        XCTAssertEqual(rh, 100, accuracy: 4)
        if case let .rectangle(_, adjW, adjH, _, _) = rectShape.adjusted(to: CGPoint(x: 310, y: 190),
                                                                         initialAnchor: CGPoint(x: 50, y: 50)) {
            XCTAssertEqual(adjW, 320, accuracy: 4)
            XCTAssertEqual(adjH, 180, accuracy: 4)
        } else {
            XCTFail("Expected stretched rectangle")
        }

        // 5. Rectangle starting at edge midpoint still recognizes cleanly as rectangle.
        let midRectPts = polylinePoints([
            CGPoint(x: 150, y: 50),
            CGPoint(x: 250, y: 50),
            CGPoint(x: 250, y: 150),
            CGPoint(x: 50, y: 150),
            CGPoint(x: 50, y: 50),
            CGPoint(x: 148, y: 51),
        ])
        guard case .rectangle = ShapeRecognizer.recognize(midRectPts) else {
            return XCTFail("Expected rectangle when starting at top midpoint")
        }
    }

    func testRecognizesRegularPentagonHexagonAndTrianglesWithoutBreakingCircles() {
        // 1. Equilateral triangle.
        let triPts = polylinePoints([
            CGPoint(x: 150, y: 40),
            CGPoint(x: 230, y: 180),
            CGPoint(x: 70, y: 180),
            CGPoint(x: 152, y: 43),
        ])
        guard case let .polygon(triVerts, _, _) = ShapeRecognizer.recognize(triPts) else {
            return XCTFail("Expected triangle polygon")
        }
        XCTAssertEqual(triVerts.count, 3)
        let ts0 = hypot(triVerts[1].x - triVerts[0].x, triVerts[1].y - triVerts[0].y)
        let ts1 = hypot(triVerts[2].x - triVerts[1].x, triVerts[2].y - triVerts[1].y)
        let ts2 = hypot(triVerts[0].x - triVerts[2].x, triVerts[0].y - triVerts[2].y)
        XCTAssertEqual(ts0, ts1, accuracy: 0.5)
        XCTAssertEqual(ts1, ts2, accuracy: 0.5)

        // 2. Regular Pentagon (slight hand jitter -> snapped to exact 5 equal sides).
        var pentCorners = (0..<5).map { i -> CGPoint in
            let a = -CGFloat.pi / 2 + 2 * CGFloat.pi * CGFloat(i) / 5
            let jitter: CGFloat = (i % 2 == 0) ? 1.5 : -1.5
            return CGPoint(x: 200 + (85 + jitter) * cos(a), y: 200 + (85 - jitter) * sin(a))
        }
        pentCorners.append(pentCorners[0])
        guard case let .polygon(pentVerts, _, _) = ShapeRecognizer.recognize(polylinePoints(pentCorners)) else {
            return XCTFail("Expected regular pentagon")
        }
        XCTAssertEqual(pentVerts.count, 5)
        let pentSides = (0..<5).map { i -> CGFloat in
            let a = pentVerts[i], b = pentVerts[(i + 1) % 5]
            return hypot(b.x - a.x, b.y - a.y)
        }
        for s in pentSides.dropFirst() {
            XCTAssertEqual(s, pentSides[0], accuracy: 0.5)
        }

        // 3. Regular Hexagon (slight hand jitter -> snapped to exact 6 equal sides).
        var hexCorners = (0..<6).map { i -> CGPoint in
            let a = 2 * CGFloat.pi * CGFloat(i) / 6
            let jitter: CGFloat = (i % 2 == 0) ? 1.0 : -1.0
            return CGPoint(x: 200 + (85 + jitter) * cos(a), y: 200 + (85 - jitter) * sin(a))
        }
        hexCorners.append(hexCorners[0])
        guard case let .polygon(hexVerts, _, _) = ShapeRecognizer.recognize(polylinePoints(hexCorners)) else {
            return XCTFail("Expected regular hexagon")
        }
        XCTAssertEqual(hexVerts.count, 6)
        let hexSides = (0..<6).map { i -> CGFloat in
            let a = hexVerts[i], b = hexVerts[(i + 1) % 6]
            return hypot(b.x - a.x, b.y - a.y)
        }
        for s in hexSides.dropFirst() {
            XCTAssertEqual(s, hexSides[0], accuracy: 0.5)
        }

        // 4. Slightly wobbly hand-drawn Circle must STILL recognize as Circle, NOT Hexagon.
        let wobblyCircle = (0...72).map { i -> CGPoint in
            let theta = 2 * CGFloat.pi * CGFloat(i) / 72
            let r = 80 + 2.5 * sin(3 * theta)
            return CGPoint(x: 200 + r * cos(theta), y: 200 + r * sin(theta))
        }
        guard case .circle = ShapeRecognizer.recognize(wobblyCircle) else {
            return XCTFail("Wobbly circle must remain a circle, not a hexagon")
        }
    }

    func testPlanAPolygonLiveScaleAndRotationWithLevelDetent() {
        let center = CGPoint(x: 100, y: 100)
        let baseVerts = [
            CGPoint(x: 100, y: 40),
            CGPoint(x: 152, y: 130),
            CGPoint(x: 48, y: 130),
        ]
        let anchor = CGPoint(x: 100, y: 40) // directly above center (distance 60)
        let poly = RecognizedShape.polygon(vertices: baseVerts, center: center, unitScalePoint: anchor)

        // 1. Drag straight outward to 2x distance with tiny 1° wobble -> exact 2x scale, 0° rotation drift.
        let slightWobble = CGPoint(x: 100 + 120 * sin(1.0 * CGFloat.pi / 180),
                                   y: 100 - 120 * cos(1.0 * CGFloat.pi / 180))
        guard case let .polygon(scaled, _, _) = poly.adjusted(to: slightWobble, initialAnchor: anchor) else {
            return XCTFail("Expected scaled polygon")
        }
        XCTAssertEqual(scaled[0].x, 100, accuracy: 0.01, "±2° detent must prevent unwanted rotation during scaling")
        XCTAssertEqual(scaled[0].y, -20, accuracy: 0.5)

        // 2. Drag 90° clockwise at 1.5x distance -> rotates exact 90° AND scales 1.5x simultaneously.
        let rot90Drag = CGPoint(x: 100 + 90, y: 100)
        guard case let .polygon(rotated, _, _) = poly.adjusted(to: rot90Drag, initialAnchor: anchor) else {
            return XCTFail("Expected rotated polygon")
        }
        XCTAssertEqual(rotated[0].x, 190, accuracy: 0.5)
        XCTAssertEqual(rotated[0].y, 100, accuracy: 0.5)
    }

    func testTooShortStrokeReturnsNil() {
        let tiny = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 1), CGPoint(x: 4, y: 2), CGPoint(x: 5, y: 2)]
        XCTAssertNil(ShapeRecognizer.recognize(tiny))
    }

    func testShapeAdjustmentAndSampleGeneration() {
        let shapes: [RecognizedShape] = [
            .line(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 10)),
            .arrow(start: CGPoint(x: 10, y: 10), end: CGPoint(x: 110, y: 10)),
            .circle(center: CGPoint(x: 100, y: 100), radius: 40),
            .parabola(vertex: CGPoint(x: 100, y: 160), axisAngle: -CGFloat.pi / 2, halfWidth: 50, height: 80),
            .rectangle(center: CGPoint(x: 100, y: 100), width: 80, height: 60, rotation: 0,
                       anchorLocal: CGPoint(x: 40, y: 30)),
            .polygon(vertices: [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0), CGPoint(x: 40, y: 60)],
                     center: CGPoint(x: 40, y: 20), unitScalePoint: CGPoint(x: 80, y: 0)),
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

        // Lifting the pen holds full brightness during `liftHoldDuration`, then fades over `liftFadeDuration`.
        engine.end(now: 15.2)
        let duringHold = engine.frame(at: 15.2 + LaserPointerEngine.liftHoldDuration * 0.5)
        XCTAssertTrue(duringHold.isActive)
        XCTAssertEqual(duringHold.opacity, 1.0, accuracy: 0.001)

        let midFade = engine.frame(at: 15.2 + LaserPointerEngine.liftHoldDuration + LaserPointerEngine.liftFadeDuration * 0.5)
        XCTAssertTrue(midFade.isActive)
        XCTAssertEqual(midFade.opacity, 0.5, accuracy: 0.05)

        let expired = engine.frame(at: 15.2 + LaserPointerEngine.totalLiftDuration + 0.05)
        XCTAssertFalse(expired.isActive)
        XCTAssertTrue(engine.samples.isEmpty)
    }

    func testLaserMultiStrokeChainingAndHoldToKeepAlive() {
        let engine = LaserPointerEngine()
        // Circle 1
        engine.begin(at: CGPoint(x: 20, y: 20), color: ToolSettings.laserPalette[0], now: 10.0)
        engine.move(to: CGPoint(x: 80, y: 20), now: 10.1)
        engine.end(now: 10.2)

        // Lift for 0.6s (within hold window), then circle 2 -> chains both disconnected strokes!
        engine.begin(at: CGPoint(x: 200, y: 120), color: ToolSettings.laserPalette[0], now: 10.8)
        engine.move(to: CGPoint(x: 260, y: 120), now: 10.9)
        engine.end(now: 11.0)
        XCTAssertEqual(engine.strokes.count, 2)

        // Wait into fade phase (0.9s hold + 0.3s fade = 1.2s after lift -> fading at ~50%).
        let fading = engine.frame(at: 11.0 + LaserPointerEngine.liftHoldDuration + LaserPointerEngine.liftFadeDuration * 0.5)
        XCTAssertTrue(fading.isActive)
        XCTAssertLessThan(fading.opacity, 0.7)

        // Press & hold pen tip on screen before expiry -> revives ALL strokes to 100% brightness indefinitely!
        engine.begin(at: CGPoint(x: 320, y: 200), color: ToolSettings.laserPalette[0],
                     now: 11.0 + LaserPointerEngine.liftHoldDuration + LaserPointerEngine.liftFadeDuration * 0.5)
        XCTAssertEqual(engine.strokes.count, 3)

        // Even 10 seconds later while still holding pen on screen, all marks stay at 100% brightness.
        let heldLong = engine.frame(at: 25.0)
        XCTAssertTrue(heldLong.isActive)
        XCTAssertEqual(heldLong.opacity, 1.0, accuracy: 0.001)

        // Once finally lifted and totalLiftDuration passes, clears cleanly and next stroke starts fresh.
        engine.end(now: 25.0)
        XCTAssertFalse(engine.frame(at: 25.0 + LaserPointerEngine.totalLiftDuration + 0.1).isActive)
        XCTAssertTrue(engine.strokes.isEmpty)

        engine.begin(at: CGPoint(x: 50, y: 50), color: ToolSettings.laserPalette[0], now: 30.0)
        XCTAssertEqual(engine.strokes.count, 1)
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
