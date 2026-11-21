import CoreGraphics
import Foundation

/// Geometric shapes produced by Draw-and-Hold ("画完按住成形").
///
/// Supports Plan A live reshaping while the pen stays down after snapping:
/// - `line` / `arrow`: anchor start, drag end with fine 0°/90° (±1.2°) angle snapping.
/// - `circle`: fixed center, live radius scaling (ellipses are intentionally never produced).
/// - `parabola`: fixed vertex, drag arm to widen/narrow/stretch or drag past vertex to flip opening.
/// - `rectangle`: stretch width & height independently from a corner (with soft square snap),
///   or rotate & resize from an edge midpoint.
/// - `polygon`: simultaneous scale + rotation around `center` via `unitScalePoint`
///   (with a gentle ±2° detent at 0°/90° so pure scaling stays level).
enum RecognizedShape: Equatable {
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint)
    case circle(center: CGPoint, radius: CGFloat)
    case parabola(vertex: CGPoint, axisAngle: CGFloat, halfWidth: CGFloat, height: CGFloat)
    case rectangle(center: CGPoint, width: CGFloat, height: CGFloat, rotation: CGFloat, anchorLocal: CGPoint)
    case polygon(vertices: [CGPoint], center: CGPoint, unitScalePoint: CGPoint)

    /// Live adjustment while the user keeps holding and drags after snapping.
    func adjusted(to dragPoint: CGPoint, initialAnchor: CGPoint) -> RecognizedShape {
        switch self {
        case let .line(start, _):
            return .line(start: start, end: ShapeRecognizer.snapAngle(from: start, to: dragPoint, stepDegrees: 90, toleranceDegrees: 1.2))

        case let .arrow(start, _):
            return .arrow(start: start, end: ShapeRecognizer.snapAngle(from: start, to: dragPoint, stepDegrees: 90, toleranceDegrees: 1.2))

        case let .circle(center, _):
            let newR = max(12, hypot(dragPoint.x - center.x, dragPoint.y - center.y))
            return .circle(center: center, radius: newR)

        case let .parabola(vertex, axisAngle, _, _):
            let dx = dragPoint.x - vertex.x
            let dy = dragPoint.y - vertex.y
            let ax = cos(axisAngle)
            let ay = sin(axisAngle)
            let px = -ay
            let py = ax
            let u = dx * px + dy * py
            let v = dx * ax + dy * ay
            let newHalfW = max(14, abs(u))
            if v < -14 {
                let flipped = atan2(-ay, -ax)
                return .parabola(vertex: vertex, axisAngle: flipped, halfWidth: newHalfW, height: max(14, -v))
            }
            return .parabola(vertex: vertex, axisAngle: axisAngle, halfWidth: newHalfW, height: max(14, v))

        case let .rectangle(center, width, height, rotation, anchorLocal):
            let dx = dragPoint.x - center.x
            let dy = dragPoint.y - center.y
            let cosR = cos(rotation)
            let sinR = sin(rotation)
            let lx = dx * cosR + dy * sinR
            let ly = -dx * sinR + dy * cosR

            let isCornerAnchor = abs(anchorLocal.x) >= width * 0.22 && abs(anchorLocal.y) >= height * 0.22
            if isCornerAnchor {
                var newW = max(20, 2 * abs(lx))
                var newH = max(20, 2 * abs(ly))
                // Soft square snap when aspect ratio comes within 5%.
                if max(newW, newH) > 24, abs(newW - newH) / max(newW, newH) <= 0.05 {
                    let side = (newW + newH) / 2
                    newW = side
                    newH = side
                }
                return .rectangle(center: center, width: newW, height: newH, rotation: rotation, anchorLocal: anchorLocal)
            } else {
                // Anchored near an edge midpoint: rotate smoothly around center while resizing that edge.
                let anchorAngle = atan2(anchorLocal.y, anchorLocal.x) + rotation
                let dragDist = hypot(dx, dy)
                var newRot = rotation
                if dragDist > 8 {
                    let dragAngle = atan2(dy, dx)
                    let rawDelta = atan2(sin(dragAngle - anchorAngle), cos(dragAngle - anchorAngle))
                    if abs(rawDelta) <= 2.0 * .pi / 180 {
                        newRot = rotation
                    } else {
                        var candidate = rotation + rawDelta
                        let step = CGFloat.pi / 2
                        let nearest = (candidate / step).rounded() * step
                        if abs(candidate - nearest) <= 2.0 * .pi / 180 {
                            candidate = nearest
                        }
                        newRot = candidate
                    }
                }
                let isTopBottomEdge = abs(anchorLocal.y) * max(1, width) >= abs(anchorLocal.x) * max(1, height)
                let newW = isTopBottomEdge ? width : max(20, 2 * dragDist)
                let newH = isTopBottomEdge ? max(20, 2 * dragDist) : height
                return .rectangle(center: center, width: newW, height: newH, rotation: newRot, anchorLocal: anchorLocal)
            }

        case let .polygon(vertices, center, unitScalePoint):
            guard !vertices.isEmpty else { return self }
            let anchor = hypot(unitScalePoint.x - center.x, unitScalePoint.y - center.y) > 4
                ? unitScalePoint
                : initialAnchor
            let v0x = anchor.x - center.x
            let v0y = anchor.y - center.y
            let r0 = hypot(v0x, v0y)
            let vx = dragPoint.x - center.x
            let vy = dragPoint.y - center.y
            let r = hypot(vx, vy)
            let baseDist = max(12, r0)
            let factor = max(0.25, min(4.0, max(8, r) / baseDist))

            var dTheta: CGFloat = 0
            if r0 > 6, r > 6 {
                let rawDelta = atan2(vy, vx) - atan2(v0y, v0x)
                dTheta = atan2(sin(rawDelta), cos(rawDelta))
                // Gentle ±2.0° detent at 0° / ±90° / 180° so pure scaling stays completely level.
                let step = CGFloat.pi / 2
                let nearest = (dTheta / step).rounded() * step
                if abs(dTheta - nearest) <= 2.0 * .pi / 180 {
                    dTheta = nearest
                }
            }
            let cosD = cos(dTheta)
            let sinD = sin(dTheta)
            let transformed = vertices.map { p -> CGPoint in
                let px = (p.x - center.x) * factor
                let py = (p.y - center.y) * factor
                return CGPoint(x: center.x + px * cosD - py * sinD,
                               y: center.y + px * sinD + py * cosD)
            }
            return .polygon(vertices: transformed, center: center, unitScalePoint: unitScalePoint)
        }
    }

    /// Converts this recognized shape into a first-class parametric `GeometricPrimitive` so its
    /// endpoints, vertices, centers, and intersections participate in compass/shape snapping and editing.
    var primitive: GeometricPrimitive {
        switch self {
        case let .line(start, end):
            return .segment(a: start, b: end)
        case let .arrow(start, end):
            return .segment(a: start, b: end, startArrow: .none, endArrow: .open)
        case let .circle(center, radius):
            return .circle(center: center, radius: radius, showCenterMark: false)
        case let .parabola(vertex, axisAngle, halfWidth, height):
            return .parabola(vertex: vertex, axisAngle: axisAngle, halfWidth: halfWidth, height: height)
        case let .rectangle(center, width, height, rotation, _):
            let hw = width / 2
            let hh = height / 2
            let cosR = cos(rotation)
            let sinR = sin(rotation)
            let local = [
                CGPoint(x: -hw, y: -hh),
                CGPoint(x: hw, y: -hh),
                CGPoint(x: hw, y: hh),
                CGPoint(x: -hw, y: hh),
            ]
            let world = local.map { p in
                CGPoint(x: center.x + p.x * cosR - p.y * sinR,
                        y: center.y + p.x * sinR + p.y * cosR)
            }
            return .polygon(vertices: world, closed: true)
        case let .polygon(vertices, _, _):
            return .polygon(vertices: vertices, closed: true)
        }
    }

    /// Generates clean `StrokeSample`s (with subpath breaks at sharp corners) for rendering & storage.
    func samples(radius: CGFloat) -> [StrokeSample] {
        primitive.samples(radius: radius)
    }
}

/// Recognizes single-stroke geometric shapes when the user pauses at the end of a stroke.
///
/// Supported shapes:
/// - Open: straight line, single-stroke arrow, parabola (vertical & horizontal).
/// - Closed: exact circle (never ellipse), triangle (auto-regularizing equilateral / right / isosceles),
///   rectangle / square, rhombus (distinct from parallelogram), parallelogram,
///   regular pentagon, regular hexagon.
enum ShapeRecognizer {
    static func recognize(_ rawPoints: [CGPoint]) -> RecognizedShape? {
        guard rawPoints.count >= 4 else { return nil }
        let points = deduplicated(rawPoints, minStep: 0.5)
        guard points.count >= 3 else { return nil }

        let length = pathLength(points)
        let box = boundingBox(points)
        let diag = hypot(box.width, box.height)
        guard length >= 20, diag >= 16 else { return nil }

        let first = points[0]
        let last = points[points.count - 1]
        let closure = hypot(last.x - first.x, last.y - first.y)
        let minDim = min(box.width, box.height)
        // Guard against narrow U-shaped parabolas whose arm tips happen to be < 0.32 * diag apart:
        // a genuine closed loop also closes within 65% of its narrower bounding dimension.
        let isClosed = closure <= max(28, diag * 0.32)
            && closure <= max(24, minDim * 0.65)
            && length >= max(56, closure * 2.8)

        if !isClosed {
            return recognizeOpen(points, length: length, box: box, diag: diag)
        }
        return recognizeClosed(points, diag: diag, anchorPoint: last)
    }

    static func snapAngle(from start: CGPoint, to end: CGPoint, stepDegrees: CGFloat, toleranceDegrees: CGFloat) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return end }
        let angle = atan2(dy, dx)
        let step = stepDegrees * .pi / 180
        let nearest = (angle / step).rounded() * step
        let tolerance = toleranceDegrees * .pi / 180
        guard abs(angle - nearest) <= tolerance else { return end }
        return CGPoint(x: start.x + cos(nearest) * length, y: start.y + sin(nearest) * length)
    }

    // MARK: Open shapes (arrow, line, parabola)

    private static func recognizeOpen(_ points: [CGPoint], length: CGFloat, box: CGRect, diag: CGFloat) -> RecognizedShape? {
        // 1. Check single-stroke arrow first so long arrows with modest barbs are not swallowed by line snap.
        if let arrow = recognizeArrow(points) {
            return arrow
        }

        let first = points[0]
        let last = points[points.count - 1]
        let direct = hypot(last.x - first.x, last.y - first.y)

        // 2. Crisp straight line snap (fine 0°/90° ±2.0° only).
        if direct >= 18 {
            let maxDev = maxDistanceToSegment(points, a: first, b: last)
            if maxDev <= max(6, length * 0.065), length <= direct * 1.18 {
                let snapped = snapAngle(from: first, to: last, stepDegrees: 90, toleranceDegrees: 2.0)
                return .line(start: first, end: snapped)
            }
        }

        // 3. Exact least-squares parabola (vertical y = ax²+bx+c or horizontal x = ay²+by+c).
        if let parabola = fitParabola(points, box: box, diag: diag) {
            return parabola
        }

        // 4. Generous straight-line fallback on deliberate draw-and-hold.
        if direct >= 22 {
            let maxDev = maxDistanceToSegment(points, a: first, b: last)
            if maxDev <= max(12, length * 0.13), length <= direct * 1.28 {
                let snapped = snapAngle(from: first, to: last, stepDegrees: 90, toleranceDegrees: 2.0)
                return .line(start: first, end: snapped)
            }
        }
        return nil
    }

    private static func recognizeArrow(_ points: [CGPoint]) -> RecognizedShape? {
        let first = points[0]
        var tipIndex = 0
        var maxDist: CGFloat = 0
        for (i, p) in points.enumerated() {
            let d = hypot(p.x - first.x, p.y - first.y)
            if d > maxDist {
                maxDist = d
                tipIndex = i
            }
        }
        guard maxDist >= 28, tipIndex >= 2, tipIndex < points.count - 2 else { return nil }
        let shaft = Array(points[0...tipIndex])
        let head = Array(points[tipIndex...])
        let shaftLen = pathLength(shaft)
        let headLen = pathLength(head)
        guard shaftLen <= maxDist * 1.18,
              headLen >= 9,
              headLen <= maxDist * 0.95 else { return nil }

        let tip = points[tipIndex]
        let shaftDev = maxDistanceToSegment(shaft, a: first, b: tip)
        guard shaftDev <= max(7, maxDist * 0.08) else { return nil }

        let maxFromTip = head.map { hypot($0.x - tip.x, $0.y - tip.y) }.max() ?? 0
        guard maxFromTip >= 9, maxFromTip <= max(32, maxDist * 0.45) else { return nil }

        let shaftDir = CGPoint(x: (tip.x - first.x) / maxDist, y: (tip.y - first.y) / maxDist)
        let barbEnd = head.max { hypot($0.x - tip.x, $0.y - tip.y) < hypot($1.x - tip.x, $1.y - tip.y) } ?? points.last!
        let bx = barbEnd.x - tip.x
        let by = barbEnd.y - tip.y
        let blen = hypot(bx, by)
        guard blen >= 9 else { return nil }
        let dot = (bx / blen) * shaftDir.x + (by / blen) * shaftDir.y
        let perp = abs(bx * (-shaftDir.y) + by * shaftDir.x)
        guard dot < -0.30, perp >= 4 else { return nil }

        let snapped = snapAngle(from: first, to: tip, stepDegrees: 90, toleranceDegrees: 2.0)
        return .arrow(start: first, end: snapped)
    }

    private struct ParabolaCandidate {
        var vertex: CGPoint
        var axisAngle: CGFloat
        var halfWidth: CGFloat
        var height: CGFloat
        var rmsd: CGFloat
    }

    private static func fitParabola(_ points: [CGPoint], box: CGRect, diag: CGFloat) -> RecognizedShape? {
        guard diag >= 36 else { return nil }
        let uniform = resampleUniform(points, count: 48)
        let vertical = fitParabolaAxis(uniform, vertical: true, diag: diag)
        let horizontal = fitParabolaAxis(uniform, vertical: false, diag: diag)

        let best: ParabolaCandidate?
        switch (vertical, horizontal) {
        case let (v?, h?): best = (v.rmsd <= h.rmsd) ? v : h
        case let (v?, nil): best = v
        case let (nil, h?): best = h
        case (nil, nil): best = nil
        }
        guard let best else { return nil }
        return .parabola(vertex: best.vertex, axisAngle: best.axisAngle,
                         halfWidth: best.halfWidth, height: best.height)
    }

    /// Fits `v = a*u^2 + b*u + c` where `(u, v) = (x, y)` for vertical parabolas and `(y, x)` for horizontal ones.
    private static func fitParabolaAxis(_ uniform: [CGPoint], vertical: Bool, diag: CGFloat) -> ParabolaCandidate? {
        let us = uniform.map { vertical ? $0.x : $0.y }
        let vs = uniform.map { vertical ? $0.y : $0.x }
        guard let uMin = us.min(), let uMax = us.max(),
              let vMin = vs.min(), let vMax = vs.max() else { return nil }
        let spanU = uMax - uMin
        let spanV = vMax - vMin
        guard spanU >= 24, spanV >= 18 else { return nil }

        // Require mostly monotonic travel along the transverse axis u (rejects hooks, loops & folded strokes).
        let uFirst = us.first!
        let uLast = us.last!
        guard abs(uLast - uFirst) >= spanU * 0.72 else { return nil }
        let dir: CGFloat = (uLast >= uFirst) ? 1 : -1
        var backSteps = 0
        var backTravel: CGFloat = 0
        let stepTol = max(3.0, spanU * 0.04)
        for i in 1..<us.count {
            let delta = (us[i] - us[i - 1]) * dir
            if delta < -stepTol {
                backSteps += 1
                backTravel += -delta
            }
        }
        guard backSteps <= 2, backTravel <= spanU * 0.12 else { return nil }

        // Center and normalize u ∈ [-1, 1] for well-conditioned 3x3 least squares.
        let uMid = (uMin + uMax) / 2
        let vMid = (vMin + vMax) / 2
        let scale = max(1, spanU / 2)

        var s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var t0 = 0.0, t1 = 0.0, t2 = 0.0
        let n = Double(uniform.count)
        for i in 0..<uniform.count {
            let un = Double((us[i] - uMid) / scale)
            let vn = Double((vs[i] - vMid) / scale)
            let u2 = un * un
            s1 += un
            s2 += u2
            s3 += u2 * un
            s4 += u2 * u2
            t0 += vn
            t1 += un * vn
            t2 += u2 * vn
        }

        let matrix = [
            [s4, s3, s2],
            [s3, s2, s1],
            [s2, s1, n],
        ]
        guard let coeffs = solve3x3(matrix, [t2, t1, t0]) else { return nil }
        let aNorm = CGFloat(coeffs[0])
        let bNorm = CGFloat(coeffs[1])
        let cNorm = CGFloat(coeffs[2])

        // Curvature gate: reject shallow curves that are merely slightly bowed straight lines.
        guard abs(aNorm) >= 0.24 else { return nil }

        let u0Norm = -bNorm / (2 * aNorm)
        let v0Norm = cNorm - (bNorm * bNorm) / (4 * aNorm)
        let u0 = uMid + scale * u0Norm
        let v0 = vMid + scale * v0Norm

        // Vertex must lie genuinely inside the drawn stroke (both arms present).
        let relVertex = (u0 - uMin) / spanU
        guard relVertex >= 0.15, relVertex <= 0.85 else { return nil }

        let dLeft = abs(uFirst - u0)
        let dRight = abs(uLast - u0)
        guard min(dLeft, dRight) >= max(12, max(dLeft, dRight) * 0.30) else { return nil }

        let halfWidth = max(14, (dLeft + dRight) / 2)
        let aWorld = aNorm / scale
        let height = abs(aWorld) * halfWidth * halfWidth
        guard height >= max(18, spanU * 0.22) else { return nil }

        let vertex = vertical ? CGPoint(x: u0, y: v0) : CGPoint(x: v0, y: u0)
        let axisAngle: CGFloat
        if vertical {
            // UIKit +Y down: a > 0 opens DOWN (+π/2), a < 0 opens UP (-π/2).
            axisAngle = (aNorm > 0) ? CGFloat.pi / 2 : -CGFloat.pi / 2
        } else {
            axisAngle = (aNorm > 0) ? 0 : CGFloat.pi
        }

        // Bidirectional Chamfer RMSD against the snapped symmetric parabola polyline.
        let sampleCount = 48
        let candidatePts = (0...sampleCount).map { i -> CGPoint in
            let s = -1 + 2 * CGFloat(i) / CGFloat(sampleCount)
            return GeometricPrimitive.parabolaPoint(vertex: vertex, axisAngle: axisAngle,
                                                    halfWidth: halfWidth, height: height, s: s)
        }
        let metrics = polylineChamfer(uniform, candidatePts, closedCandidate: false)
        guard metrics.rmsd <= diag * 0.068, metrics.maxForward <= diag * 0.14 else { return nil }

        return ParabolaCandidate(vertex: vertex, axisAngle: axisAngle,
                                 halfWidth: halfWidth, height: height, rmsd: metrics.rmsd)
    }

    // MARK: Closed shapes (circle, triangle, rectangle, rhombus, parallelogram, regular pentagon/hexagon)

    private static func recognizeClosed(_ points: [CGPoint], diag: CGFloat, anchorPoint: CGPoint) -> RecognizedShape? {
        let uniform = resampleUniform(points, count: 64)
        let circleFit = fitCircle(uniform)
        // Oval fit is used strictly as a smooth-curve vs sharp-polygon discriminator; ellipses are never emitted.
        let ovalFit = fitOvalMetric(uniform)
        let vertices = extractClosedVertices(points, diag: diag)

        // 1. Triangle (3 vertices): equilateral -> right -> isosceles -> general triangle.
        if vertices.count == 3 {
            let triVerts = regularizeTriangle(vertices, uniform: uniform, diag: diag)
            let triMetrics = polylineChamfer(uniform, triVerts, closedCandidate: true)
            if triMetrics.rmsd <= diag * 0.055,
               (ovalFit.residual > 0.07 || triMetrics.rmsd < circleFit.rmsd * 0.75) {
                return .polygon(vertices: triVerts, center: centroid(triVerts), unitScalePoint: anchorPoint)
            }
        }

        // 2. Quadrilateral (4 vertices): Rectangle/Square vs Rhombus vs Parallelogram vs General Quad.
        if vertices.count == 4 {
            if let quad = classifyQuadrilateral(vertices, uniform: uniform, diag: diag,
                                                ovalResidual: ovalFit.residual,
                                                circleRMSD: circleFit.rmsd,
                                                anchorPoint: anchorPoint) {
                return quad
            }
        }

        // 3. Regular Pentagon (5 vertices).
        if vertices.count == 5 {
            let pentFit = fitRegularPolygon(uniform, sides: 5)
            if pentFit.rmsd <= diag * 0.044, pentFit.rmsd < circleFit.rmsd * 0.82 {
                return .polygon(vertices: pentFit.vertices, center: pentFit.center, unitScalePoint: anchorPoint)
            }
            let rawMetrics = polylineChamfer(uniform, vertices, closedCandidate: true)
            if rawMetrics.rmsd <= diag * 0.042,
               rawMetrics.rmsd < circleFit.rmsd * 0.68,
               ovalFit.residual > 0.055 {
                return .polygon(vertices: vertices, center: centroid(vertices), unitScalePoint: anchorPoint)
            }
        }

        // 4. Regular Hexagon (6 vertices) — strict margin over Circle so wobbly circles never turn hexagonal.
        if vertices.count == 6 {
            let hexFit = fitRegularPolygon(uniform, sides: 6)
            if hexFit.rmsd <= diag * 0.036, hexFit.rmsd < circleFit.rmsd * 0.78 {
                return .polygon(vertices: hexFit.vertices, center: hexFit.center, unitScalePoint: anchorPoint)
            }
        }

        // 5. Circle fallback (NO ellipses: smooth rounded loops always snap to exact Circle).
        let ovalRatio = min(ovalFit.rx, ovalFit.ry) / max(1, max(ovalFit.rx, ovalFit.ry))
        if circleFit.radius >= 10,
           (circleFit.rmsd <= diag * 0.075 || (ovalFit.residual <= 0.16 && ovalRatio >= 0.35)) {
            return .circle(center: circleFit.center, radius: circleFit.radius)
        }

        return nil
    }

    // MARK: Triangle regularization

    private static func regularizeTriangle(_ raw: [CGPoint], uniform: [CGPoint], diag: CGFloat) -> [CGPoint] {
        guard raw.count == 3 else { return raw }
        let sides = (0..<3).map { i -> CGFloat in
            let a = raw[i], b = raw[(i + 1) % 3]
            return hypot(b.x - a.x, b.y - a.y)
        }
        guard let minS = sides.min(), let maxS = sides.max(), maxS > 1 else { return raw }

        // 1. Near-equilateral -> exact regular 3-gon.
        if minS / maxS >= 0.86 {
            let eq = fitRegularPolygon(uniform, sides: 3)
            if eq.rmsd <= diag * 0.055 {
                return eq.vertices
            }
        }

        // 2. Near-right angle -> exact 90° right triangle preserving leg lengths.
        let angles = interiorAngles(raw)
        if let rightIdx = angles.enumerated().min(by: { abs($0.element - .pi / 2) < abs($1.element - .pi / 2) }),
           abs(rightIdx.element - .pi / 2) <= 9 * .pi / 180 {
            let k = rightIdx.offset
            let pCorner = raw[k]
            let pPrev = raw[(k + 2) % 3]
            let pNext = raw[(k + 1) % 3]
            let v1 = CGPoint(x: pPrev.x - pCorner.x, y: pPrev.y - pCorner.y)
            let v2 = CGPoint(x: pNext.x - pCorner.x, y: pNext.y - pCorner.y)
            let l1 = hypot(v1.x, v1.y)
            let l2 = hypot(v2.x, v2.y)
            if l1 > 4, l2 > 4 {
                var a1 = atan2(v1.y, v1.x)
                let snapStep = CGFloat.pi / 2
                let near1 = (a1 / snapStep).rounded() * snapStep
                let a2Raw = atan2(v2.y, v2.x)
                let near2 = (a2Raw / snapStep).rounded() * snapStep
                if abs(a1 - near1) <= 8 * .pi / 180 {
                    a1 = near1
                } else if abs(a2Raw - near2) <= 8 * .pi / 180 {
                    let sign: CGFloat = (v1.x * v2.y - v1.y * v2.x >= 0) ? -1 : 1
                    a1 = near2 + sign * CGFloat.pi / 2
                }
                let u1 = CGPoint(x: cos(a1), y: sin(a1))
                let cross = v1.x * v2.y - v1.y * v2.x
                let u2 = cross >= 0 ? CGPoint(x: -u1.y, y: u1.x) : CGPoint(x: u1.y, y: -u1.x)
                var out = raw
                out[(k + 2) % 3] = CGPoint(x: pCorner.x + l1 * u1.x, y: pCorner.y + l1 * u1.y)
                out[(k + 1) % 3] = CGPoint(x: pCorner.x + l2 * u2.x, y: pCorner.y + l2 * u2.y)
                if polylineChamfer(uniform, out, closedCandidate: true).rmsd <= diag * 0.055 {
                    return out
                }
            }
        }

        // 3. Near-isosceles -> exact equal legs symmetric over base perpendicular bisector.
        let pairs = [(0, 1, 2), (1, 2, 0), (2, 0, 1)] // (apex, baseA, baseB)
        for (apexIdx, b1Idx, b2Idx) in pairs {
            let apex = raw[apexIdx], b1 = raw[b1Idx], b2 = raw[b2Idx]
            let leg1 = hypot(apex.x - b1.x, apex.y - b1.y)
            let leg2 = hypot(apex.x - b2.x, apex.y - b2.y)
            if max(leg1, leg2) > 4, min(leg1, leg2) / max(leg1, leg2) >= 0.90 {
                let baseVec = CGPoint(x: b2.x - b1.x, y: b2.y - b1.y)
                let baseLen = hypot(baseVec.x, baseVec.y)
                if baseLen > 4 {
                    let baseMid = CGPoint(x: (b1.x + b2.x) / 2, y: (b1.y + b2.y) / 2)
                    let baseAngle = snappedAxisAngle(atan2(baseVec.y, baseVec.x), toleranceDegrees: 7)
                    let ux = cos(baseAngle), uy = sin(baseAngle)
                    let nx = -uy, ny = ux
                    let alt = (apex.x - baseMid.x) * nx + (apex.y - baseMid.y) * ny
                    var out = raw
                    out[b1Idx] = CGPoint(x: baseMid.x - 0.5 * baseLen * ux, y: baseMid.y - 0.5 * baseLen * uy)
                    out[b2Idx] = CGPoint(x: baseMid.x + 0.5 * baseLen * ux, y: baseMid.y + 0.5 * baseLen * uy)
                    out[apexIdx] = CGPoint(x: baseMid.x + alt * nx, y: baseMid.y + alt * ny)
                    if polylineChamfer(uniform, out, closedCandidate: true).rmsd <= diag * 0.055 {
                        return out
                    }
                }
            }
        }

        return raw
    }

    // MARK: Quadrilateral classification (Rectangle vs Rhombus vs Parallelogram)

    private static func classifyQuadrilateral(_ v: [CGPoint],
                                              uniform: [CGPoint],
                                              diag: CGFloat,
                                              ovalResidual: CGFloat,
                                              circleRMSD: CGFloat,
                                              anchorPoint: CGPoint) -> RecognizedShape? {
        guard v.count == 4 else { return nil }
        let rawMetrics = polylineChamfer(uniform, v, closedCandidate: true)
        guard rawMetrics.rmsd <= diag * 0.052 else { return nil }
        // Guard against elongated smooth ovals masquerading as an inscribed diamond/quad.
        guard ovalResidual > 0.055 || rawMetrics.rmsd < ovalResidual * diag * 0.45 else { return nil }

        let e = (0..<4).map { i -> CGPoint in
            let a = v[i], b = v[(i + 1) % 4]
            return CGPoint(x: b.x - a.x, y: b.y - a.y)
        }
        let len = e.map { hypot($0.x, $0.y) }
        guard len.allSatisfy({ $0 > 4 }) else { return nil }

        let angles = interiorAngles(v)
        let angleDevsFrom90 = angles.map { abs($0 - .pi / 2) }
        let maxDev90 = angleDevsFrom90.max() ?? .pi
        let meanDev90 = angleDevsFrom90.reduce(0, +) / 4

        let cos02 = -(e[0].x * e[2].x + e[0].y * e[2].y) / (len[0] * len[2])
        let cos13 = -(e[1].x * e[3].x + e[1].y * e[3].y) / (len[1] * len[3])
        let oppositeParallel = cos02 >= 0.85 && cos13 >= 0.85

        let avgA = (len[0] + len[2]) / 2
        let avgB = (len[1] + len[3]) / 2
        let adjRatio = min(avgA, avgB) / max(1, max(avgA, avgB))

        let d02 = CGPoint(x: v[2].x - v[0].x, y: v[2].y - v[0].y)
        let d13 = CGPoint(x: v[3].x - v[1].x, y: v[3].y - v[1].y)
        let d02Len = hypot(d02.x, d02.y)
        let d13Len = hypot(d13.x, d13.y)
        guard d02Len > 4, d13Len > 4 else { return nil }
        let diagCos = abs(d02.x * d13.x + d02.y * d13.y) / (d02Len * d13Len)
        let diagAngle = acos(min(1, diagCos))
        let diagDevFrom90 = abs(diagAngle - .pi / 2)

        // Check upright diamond first (axis-aligned perpendicular diagonals + equal sides).
        let d02AxisDev = axisDeviation(atan2(d02.y, d02.x))
        let d13AxisDev = axisDeviation(atan2(d13.y, d13.x))
        let isUprightDiamond = d02AxisDev <= 11 * .pi / 180
            && d13AxisDev <= 11 * .pi / 180
            && diagDevFrom90 <= 14 * .pi / 180
            && adjRatio >= 0.85

        if isUprightDiamond {
            let rhombus = makeRhombusFromDiagonals(v)
            let rmsd = polylineChamfer(uniform, rhombus, closedCandidate: true).rmsd
            if rmsd <= diag * 0.048, rmsd < circleRMSD * 0.90 {
                return .polygon(vertices: rhombus, center: centroid(rhombus), unitScalePoint: anchorPoint)
            }
        }

        // 1. Rectangle / Square (tight 90° gate so 70°-75° parallelograms are never crushed into rectangles).
        if maxDev90 <= 13 * .pi / 180, meanDev90 <= 9 * .pi / 180 {
            let rect = makeRectangleShape(from: v, anchorPoint: anchorPoint)
            if case let .polygon(rectVerts, _) = rect.primitive {
                let rmsd = polylineChamfer(uniform, rectVerts, closedCandidate: true).rmsd
                if rmsd <= diag * 0.048 {
                    return rect
                }
            }
        }

        // 2. Rhombus vs Parallelogram when opposite edges are parallel.
        if oppositeParallel {
            // Rhombus: all 4 sides nearly equal AND diagonals nearly perpendicular.
            if adjRatio >= 0.85, diagDevFrom90 <= 14 * .pi / 180 {
                let e0AxisDev = axisDeviation(atan2(e[0].y, e[0].x))
                let e1AxisDev = axisDeviation(atan2(e[1].y, e[1].x))
                let rhombus = (min(e0AxisDev, e1AxisDev) <= 9 * .pi / 180)
                    ? makeRhombusFromEdges(v)
                    : makeRhombusFromDiagonals(v)
                let rmsd = polylineChamfer(uniform, rhombus, closedCandidate: true).rmsd
                if rmsd <= diag * 0.050 {
                    return .polygon(vertices: rhombus, center: centroid(rhombus), unitScalePoint: anchorPoint)
                }
            }

            // General Parallelogram: exact equal & parallel opposite edges preserving drawn slant & unequal sides.
            let para = makeParallelogram(from: v)
            let rmsd = polylineChamfer(uniform, para, closedCandidate: true).rmsd
            if rmsd <= diag * 0.050 {
                return .polygon(vertices: para, center: centroid(para), unitScalePoint: anchorPoint)
            }
        }

        // 3. Clean convex quad (e.g. trapezoid).
        if rawMetrics.rmsd <= diag * 0.044, rawMetrics.rmsd < circleRMSD * 0.78 {
            return .polygon(vertices: v, center: centroid(v), unitScalePoint: anchorPoint)
        }
        return nil
    }

    private static func makeRectangleShape(from vertices: [CGPoint], anchorPoint: CGPoint) -> RecognizedShape {
        let e0 = CGPoint(x: vertices[1].x - vertices[0].x, y: vertices[1].y - vertices[0].y)
        let e2 = CGPoint(x: vertices[2].x - vertices[3].x, y: vertices[2].y - vertices[3].y)
        let avgE = CGPoint(x: (e0.x + e2.x) / 2, y: (e0.y + e2.y) / 2)
        let rawAngle = atan2(avgE.y, avgE.x)
        let angle = snappedAxisAngle(rawAngle, toleranceDegrees: 8)

        let cosA = cos(-angle)
        let sinA = sin(-angle)
        let rotated = vertices.map { p in
            CGPoint(x: p.x * cosA - p.y * sinA, y: p.x * sinA + p.y * cosA)
        }
        let minX = rotated.map(\.x).min() ?? 0
        let maxX = rotated.map(\.x).max() ?? 0
        let minY = rotated.map(\.y).min() ?? 0
        let maxY = rotated.map(\.y).max() ?? 0
        var width = max(16, maxX - minX)
        var height = max(16, maxY - minY)
        if max(width, height) > 20, abs(width - height) / max(width, height) <= 0.08 {
            let side = (width + height) / 2
            width = side
            height = side
        }

        let midRot = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let cosB = cos(angle)
        let sinB = sin(angle)
        let center = CGPoint(x: midRot.x * cosB - midRot.y * sinB,
                             y: midRot.x * sinB + midRot.y * cosB)

        // Transform the pen's hold point into rectangle local coordinates for Plan A corner vs edge resizing.
        let adx = anchorPoint.x - center.x
        let ady = anchorPoint.y - center.y
        let anchorLocal = CGPoint(x: adx * cosB + ady * sinB,
                                  y: -adx * sinB + ady * cosB)
        return .rectangle(center: center, width: width, height: height, rotation: angle, anchorLocal: anchorLocal)
    }

    /// Builds an exact rhombus with orthogonal bisecting diagonals (all 4 sides identically equal).
    private static func makeRhombusFromDiagonals(_ v: [CGPoint]) -> [CGPoint] {
        let c = centroid(v)
        let d02 = CGPoint(x: v[2].x - v[0].x, y: v[2].y - v[0].y)
        let d13 = CGPoint(x: v[3].x - v[1].x, y: v[3].y - v[1].y)
        let h1 = max(8, hypot(d02.x, d02.y) / 2)
        let h2 = max(8, hypot(d13.x, d13.y) / 2)
        let angle = snappedAxisAngle(atan2(d02.y, d02.x), toleranceDegrees: 9)
        let ux = cos(angle), uy = sin(angle)
        let px = -uy, py = ux
        let sign: CGFloat = (d13.x * px + d13.y * py >= 0) ? 1 : -1
        let wx = px * sign, wy = py * sign
        return [
            CGPoint(x: c.x - h1 * ux, y: c.y - h1 * uy),
            CGPoint(x: c.x - h2 * wx, y: c.y - h2 * wy),
            CGPoint(x: c.x + h1 * ux, y: c.y + h1 * uy),
            CGPoint(x: c.x + h2 * wx, y: c.y + h2 * wy),
        ]
    }

    /// Builds an exact flat-base slanted rhombus (horizontal/vertical base edge, all 4 sides equal,
    /// diagonals automatically perpendicular because |u| == |w|).
    private static func makeRhombusFromEdges(_ v: [CGPoint]) -> [CGPoint] {
        let c = centroid(v)
        let aRaw = CGPoint(x: ((v[1].x - v[0].x) + (v[2].x - v[3].x)) / 2,
                           y: ((v[1].y - v[0].y) + (v[2].y - v[3].y)) / 2)
        let bRaw = CGPoint(x: ((v[2].x - v[1].x) + (v[3].x - v[0].x)) / 2,
                           y: ((v[2].y - v[1].y) + (v[3].y - v[0].y)) / 2)
        let la = max(8, hypot(aRaw.x, aRaw.y))
        let lb = max(8, hypot(bRaw.x, bRaw.y))
        let side = (la + lb) / 2

        var angleA = atan2(aRaw.y, aRaw.x)
        var angleB = atan2(bRaw.y, bRaw.x)
        if axisDeviation(angleA) <= axisDeviation(angleB) {
            angleA = snappedAxisAngle(angleA, toleranceDegrees: 9)
        } else {
            angleB = snappedAxisAngle(angleB, toleranceDegrees: 9)
        }
        let a = CGPoint(x: side * cos(angleA), y: side * sin(angleA))
        let b = CGPoint(x: side * cos(angleB), y: side * sin(angleB))
        return [
            CGPoint(x: c.x - 0.5 * a.x - 0.5 * b.x, y: c.y - 0.5 * a.y - 0.5 * b.y),
            CGPoint(x: c.x + 0.5 * a.x - 0.5 * b.x, y: c.y + 0.5 * a.y - 0.5 * b.y),
            CGPoint(x: c.x + 0.5 * a.x + 0.5 * b.x, y: c.y + 0.5 * a.y + 0.5 * b.y),
            CGPoint(x: c.x - 0.5 * a.x + 0.5 * b.x, y: c.y - 0.5 * a.y + 0.5 * b.y),
        ]
    }

    /// Builds an exact parallelogram with equal parallel opposite sides while preserving slant & side ratio.
    private static func makeParallelogram(from v: [CGPoint]) -> [CGPoint] {
        let c = centroid(v)
        let aRaw = CGPoint(x: ((v[1].x - v[0].x) + (v[2].x - v[3].x)) / 2,
                           y: ((v[1].y - v[0].y) + (v[2].y - v[3].y)) / 2)
        let bRaw = CGPoint(x: ((v[2].x - v[1].x) + (v[3].x - v[0].x)) / 2,
                           y: ((v[2].y - v[1].y) + (v[3].y - v[0].y)) / 2)
        let la = max(8, hypot(aRaw.x, aRaw.y))
        let lb = max(8, hypot(bRaw.x, bRaw.y))
        var angleA = atan2(aRaw.y, aRaw.x)
        var angleB = atan2(bRaw.y, bRaw.x)
        if axisDeviation(angleA) <= axisDeviation(angleB) {
            angleA = snappedAxisAngle(angleA, toleranceDegrees: 8)
        } else {
            angleB = snappedAxisAngle(angleB, toleranceDegrees: 8)
        }
        let a = CGPoint(x: la * cos(angleA), y: la * sin(angleA))
        let b = CGPoint(x: lb * cos(angleB), y: lb * sin(angleB))
        return [
            CGPoint(x: c.x - 0.5 * a.x - 0.5 * b.x, y: c.y - 0.5 * a.y - 0.5 * b.y),
            CGPoint(x: c.x + 0.5 * a.x - 0.5 * b.x, y: c.y + 0.5 * a.y - 0.5 * b.y),
            CGPoint(x: c.x + 0.5 * a.x + 0.5 * b.x, y: c.y + 0.5 * a.y + 0.5 * b.y),
            CGPoint(x: c.x - 0.5 * a.x + 0.5 * b.x, y: c.y - 0.5 * a.y + 0.5 * b.y),
        ]
    }

    // MARK: Regular N-gon fitting (Equilateral triangle, Regular Pentagon, Regular Hexagon)

    private struct RegularPolygonFit {
        var vertices: [CGPoint]
        var center: CGPoint
        var radius: CGFloat
        var rmsd: CGFloat
    }

    private static func fitRegularPolygon(_ uniform: [CGPoint], sides n: Int) -> RegularPolygonFit {
        let c = centroid(uniform)
        let strokeMeanDist = uniform.map { hypot($0.x - c.x, $0.y - c.y) }.reduce(0, +) / CGFloat(max(1, uniform.count))

        // Exact mean radius of a unit regular N-gon perimeter (by sampling 48 points around it).
        let unitVerts = regularPolygonVertices(center: .zero, radius: 1, sides: n, phase: 0)
        let unitPoly = sampleClosedPolygon(unitVerts, totalPoints: 48)
        let unitMeanDist = unitPoly.map { hypot($0.x, $0.y) }.reduce(0, +) / CGFloat(max(1, unitPoly.count))
        let rEst = max(8, strokeMeanDist / max(0.2, unitMeanDist))

        let period = 2 * CGFloat.pi / CGFloat(n)
        var bestPhase: CGFloat = 0
        var bestR = rEst
        var bestRMSD = CGFloat.infinity

        // Coarse angular phase sweep (2° increments over one symmetry period).
        let coarseStep = 2 * CGFloat.pi / 180
        var phi: CGFloat = 0
        while phi < period {
            let verts = regularPolygonVertices(center: c, radius: rEst, sides: n, phase: phi)
            let rmsd = polylineChamfer(uniform, verts, closedCandidate: true).rmsd
            if rmsd < bestRMSD {
                bestRMSD = rmsd
                bestPhase = phi
            }
            phi += coarseStep
        }

        // Fine refinement over phase (±2.5° in 0.5° steps) and circumradius (±4%).
        let coarsePhase = bestPhase
        let fineStep = 0.5 * CGFloat.pi / 180
        let scales: [CGFloat] = [0.96, 1.00, 1.04]
        for s in scales {
            let rTry = max(8, rEst * s)
            var d = -2.5 * CGFloat.pi / 180
            while d <= 2.5 * CGFloat.pi / 180 + 1e-4 {
                let pTry = coarsePhase + d
                let verts = regularPolygonVertices(center: c, radius: rTry, sides: n, phase: pTry)
                let rmsd = polylineChamfer(uniform, verts, closedCandidate: true).rmsd
                if rmsd < bestRMSD {
                    bestRMSD = rmsd
                    bestPhase = pTry
                    bestR = rTry
                }
                d += fineStep
            }
        }

        // Canonical orientation snap (e.g. apex straight UP for triangle/pentagon, flat top/bottom for hexagon).
        let snappedPhase = snapRegularPhase(bestPhase, sides: n, toleranceDegrees: 8)
        let finalVerts = regularPolygonVertices(center: c, radius: bestR, sides: n, phase: snappedPhase)
        let finalRMSD = polylineChamfer(uniform, finalVerts, closedCandidate: true).rmsd
        return RegularPolygonFit(vertices: finalVerts, center: c, radius: bestR, rmsd: finalRMSD)
    }

    private static func regularPolygonVertices(center: CGPoint, radius: CGFloat, sides n: Int, phase: CGFloat) -> [CGPoint] {
        (0..<n).map { i in
            let theta = phase + 2 * CGFloat.pi * CGFloat(i) / CGFloat(n)
            return CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
        }
    }

    private static func snapRegularPhase(_ phase: CGFloat, sides n: Int, toleranceDegrees: CGFloat) -> CGFloat {
        let period = 2 * CGFloat.pi / CGFloat(n)
        let tol = toleranceDegrees * .pi / 180
        let canonicalTargets: [CGFloat] = [-CGFloat.pi / 2, CGFloat.pi / 2, 0]
        for target in canonicalTargets {
            // Distance modulo symmetry period.
            let diff = (phase - target).truncatingRemainder(dividingBy: period)
            let wrapped = atan2(sin(diff * CGFloat(n)), cos(diff * CGFloat(n))) / CGFloat(n)
            if abs(wrapped) <= tol {
                return target
            }
        }
        return phase
    }

    // MARK: Circle & Oval smooth-curve fitting

    private struct CircleFit {
        var center: CGPoint
        var radius: CGFloat
        var rmsd: CGFloat
    }

    /// Algebraic Kåsa least-squares circle fit with bidirectional Chamfer RMSD.
    private static func fitCircle(_ uniform: [CGPoint]) -> CircleFit {
        let n = Double(max(1, uniform.count))
        let meanX = uniform.map { Double($0.x) }.reduce(0, +) / n
        let meanY = uniform.map { Double($0.y) }.reduce(0, +) / n

        var suu = 0.0, suv = 0.0, svv = 0.0
        var su = 0.0, sv = 0.0
        var sur2 = 0.0, svr2 = 0.0, sr2 = 0.0
        for p in uniform {
            let u = Double(p.x) - meanX
            let v = Double(p.y) - meanY
            let r2 = u * u + v * v
            suu += u * u
            suv += u * v
            svv += v * v
            su += u
            sv += v
            sur2 += u * r2
            svr2 += v * r2
            sr2 += r2
        }

        let center: CGPoint
        if let sol = solve3x3([[suu, suv, su], [suv, svv, sv], [su, sv, n]], [-sur2, -svr2, -sr2]) {
            let cx = CGFloat(meanX - sol[0] / 2)
            let cy = CGFloat(meanY - sol[1] / 2)
            // Sanity guard against wild center drift on near-collinear inputs.
            let drift = hypot(cx - CGFloat(meanX), cy - CGFloat(meanY))
            let box = boundingBox(uniform)
            if drift <= max(box.width, box.height) * 0.75 {
                center = CGPoint(x: cx, y: cy)
            } else {
                center = CGPoint(x: CGFloat(meanX), y: CGFloat(meanY))
            }
        } else {
            center = CGPoint(x: CGFloat(meanX), y: CGFloat(meanY))
        }

        let radius = max(1, uniform.map { hypot($0.x - center.x, $0.y - center.y) }.reduce(0, +) / CGFloat(max(1, uniform.count)))
        let circlePts = (0..<64).map { i -> CGPoint in
            let theta = 2 * CGFloat.pi * CGFloat(i) / 64
            return CGPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
        }
        let rmsd = polylineChamfer(uniform, circlePts, closedCandidate: true).rmsd
        return CircleFit(center: center, radius: radius, rmsd: rmsd)
    }

    private struct OvalMetric {
        var rx: CGFloat
        var ry: CGFloat
        var residual: CGFloat
    }

    /// Second-moment oval residual used only to distinguish smooth closed curves from sharp polygons.
    private static func fitOvalMetric(_ uniform: [CGPoint]) -> OvalMetric {
        let n = CGFloat(max(1, uniform.count))
        let cx = uniform.map(\.x).reduce(0, +) / n
        let cy = uniform.map(\.y).reduce(0, +) / n

        var sxx: CGFloat = 0, syy: CGFloat = 0, sxy: CGFloat = 0
        for p in uniform {
            let dx = p.x - cx, dy = p.y - cy
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        sxx /= n; syy /= n; sxy /= n
        let rotation = 0.5 * atan2(2 * sxy, sxx - syy)
        let cosR = cos(rotation), sinR = sin(rotation)

        var u2: CGFloat = 0, v2: CGFloat = 0
        for p in uniform {
            let dx = p.x - cx, dy = p.y - cy
            let u = dx * cosR + dy * sinR
            let v = -dx * sinR + dy * cosR
            u2 += u * u; v2 += v * v
        }
        let rx = max(1, sqrt(2 * u2 / n))
        let ry = max(1, sqrt(2 * v2 / n))

        var errSum: CGFloat = 0
        for p in uniform {
            let dx = p.x - cx, dy = p.y - cy
            let u = (dx * cosR + dy * sinR) / rx
            let v = (-dx * sinR + dy * cosR) / ry
            errSum += abs(hypot(u, v) - 1)
        }
        return OvalMetric(rx: rx, ry: ry, residual: errSum / n)
    }

    // MARK: Corner extraction & Chamfer RMSD

    private static func extractClosedVertices(_ points: [CGPoint], diag: CGFloat) -> [CGPoint] {
        var closed = points
        closed.append(points[0])
        // Epsilon = 0.040 * diag cleanly extracts 3..6 polygon corners while splitting circles into 8 vertices.
        var simplified = rdp(closed, epsilon: max(5, diag * 0.040))
        if simplified.count > 1,
           hypot(simplified.last!.x - simplified.first!.x, simplified.last!.y - simplified.first!.y) < 1 {
            simplified.removeLast()
        }
        // Merge vertices that are too close together (e.g. slight overshoot at stroke closure).
        let minEdge = max(10, diag * 0.12)
        var changed = true
        while changed, simplified.count > 3 {
            changed = false
            for i in 0..<simplified.count {
                let j = (i + 1) % simplified.count
                if hypot(simplified[j].x - simplified[i].x, simplified[j].y - simplified[i].y) < minEdge {
                    let mid = CGPoint(x: (simplified[i].x + simplified[j].x) / 2,
                                      y: (simplified[i].y + simplified[j].y) / 2)
                    simplified[i] = mid
                    simplified.remove(at: j)
                    changed = true
                    break
                }
            }
        }
        // Drop nearly-collinear vertices along an edge (e.g. mid-edge stroke start/end).
        changed = true
        while changed, simplified.count > 3 {
            changed = false
            let angles = interiorAngles(simplified)
            if let flatIndex = angles.firstIndex(where: { $0 > 152 * .pi / 180 }) {
                simplified.remove(at: flatIndex)
                changed = true
            }
        }
        return simplified
    }

    private struct ChamferMetrics {
        var rmsd: CGFloat
        var maxForward: CGFloat
    }

    /// Bidirectional Chamfer RMSD between a uniform stroke polyline and a candidate polyline/polygon.
    private static func polylineChamfer(_ strokePts: [CGPoint],
                                        _ candidateVerts: [CGPoint],
                                        closedCandidate: Bool) -> ChamferMetrics {
        guard !strokePts.isEmpty, candidateVerts.count >= 2 else {
            return ChamferMetrics(rmsd: .infinity, maxForward: .infinity)
        }
        let edgeCount = closedCandidate ? candidateVerts.count : candidateVerts.count - 1

        // Forward: stroke -> candidate segments
        var fwdSqSum: CGFloat = 0
        var maxFwd: CGFloat = 0
        for p in strokePts {
            var best = CGFloat.infinity
            for i in 0..<edgeCount {
                let a = candidateVerts[i]
                let b = candidateVerts[(i + 1) % candidateVerts.count]
                let d = EraserEngine.distance(from: p, toSegment: a, b)
                if d < best { best = d }
            }
            fwdSqSum += best * best
            if best > maxFwd { maxFwd = best }
        }
        let fwdMeanSq = fwdSqSum / CGFloat(strokePts.count)

        // Backward: dense uniform samples of candidate -> stroke segments
        let candSamples = closedCandidate
            ? sampleClosedPolygon(candidateVerts, totalPoints: 48)
            : candidateVerts
        var bwdSqSum: CGFloat = 0
        for q in candSamples {
            var best = CGFloat.infinity
            for i in 0..<(strokePts.count - 1) {
                let d = EraserEngine.distance(from: q, toSegment: strokePts[i], strokePts[i + 1])
                if d < best { best = d }
            }
            bwdSqSum += best * best
        }
        let bwdMeanSq = bwdSqSum / CGFloat(max(1, candSamples.count))
        return ChamferMetrics(rmsd: sqrt(0.5 * (fwdMeanSq + bwdMeanSq)), maxForward: maxFwd)
    }

    private static func sampleClosedPolygon(_ vertices: [CGPoint], totalPoints: Int) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        var closed = vertices
        closed.append(vertices[0])
        return resampleUniform(closed, count: max(vertices.count + 1, totalPoints))
    }

    // MARK: Linear algebra & geometry helpers

    /// Solves a 3×3 linear system `A x = b` via Gaussian elimination with partial pivoting.
    private static func solve3x3(_ aIn: [[Double]], _ bIn: [Double]) -> [Double]? {
        var a = aIn
        var b = bIn
        for col in 0..<3 {
            var pivotRow = col
            var pivotVal = abs(a[col][col])
            for row in (col + 1)..<3 {
                if abs(a[row][col]) > pivotVal {
                    pivotVal = abs(a[row][col])
                    pivotRow = row
                }
            }
            guard pivotVal > 1e-10 else { return nil }
            if pivotRow != col {
                a.swapAt(col, pivotRow)
                b.swapAt(col, pivotRow)
            }
            let piv = a[col][col]
            for row in (col + 1)..<3 {
                let factor = a[row][col] / piv
                for k in col..<3 {
                    a[row][k] -= factor * a[col][k]
                }
                b[row] -= factor * b[col]
            }
        }
        var x = [0.0, 0.0, 0.0]
        for row in stride(from: 2, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<3 {
                sum -= a[row][k] * x[k]
            }
            guard abs(a[row][row]) > 1e-10 else { return nil }
            x[row] = sum / a[row][row]
        }
        return x
    }

    private static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / n,
                       y: pts.map(\.y).reduce(0, +) / n)
    }

    private static func axisDeviation(_ angle: CGFloat) -> CGFloat {
        let step = CGFloat.pi / 2
        let nearest = (angle / step).rounded() * step
        return abs(angle - nearest)
    }

    private static func snappedAxisAngle(_ angle: CGFloat, toleranceDegrees: CGFloat) -> CGFloat {
        let step = CGFloat.pi / 2
        let nearest = (angle / step).rounded() * step
        return abs(angle - nearest) <= toleranceDegrees * .pi / 180 ? nearest : angle
    }

    private static func deduplicated(_ points: [CGPoint], minStep: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var out = [first]
        for p in points.dropFirst() {
            if hypot(p.x - out.last!.x, p.y - out.last!.y) >= minStep {
                out.append(p)
            }
        }
        if let last = points.last, hypot(last.x - out.last!.x, last.y - out.last!.y) > 0.01 {
            out.append(last)
        }
        return out
    }

    private static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        return total
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func maxDistanceToSegment(_ points: [CGPoint], a: CGPoint, b: CGPoint) -> CGFloat {
        points.map { EraserEngine.distance(from: $0, toSegment: a, b) }.max() ?? 0
    }

    private static func interiorAngles(_ vertices: [CGPoint]) -> [CGFloat] {
        let n = vertices.count
        guard n >= 3 else { return [] }
        return (0..<n).map { i in
            let prev = vertices[(i - 1 + n) % n]
            let curr = vertices[i]
            let next = vertices[(i + 1) % n]
            let v1 = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
            let v2 = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
            let l1 = hypot(v1.x, v1.y)
            let l2 = hypot(v2.x, v2.y)
            guard l1 > 1e-5, l2 > 1e-5 else { return 0 }
            let cosA = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (l1 * l2)))
            return acos(cosA)
        }
    }

    private static func resampleUniform(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count > 1, count > 1 else { return points }
        let total = pathLength(points)
        guard total > 1e-4 else { return points }
        let step = total / CGFloat(count - 1)
        var out: [CGPoint] = [points[0]]
        var accumulated: CGFloat = 0
        var target = step
        var i = 1
        while i < points.count, out.count < count {
            let a = points[i - 1]
            let b = points[i]
            let seg = hypot(b.x - a.x, b.y - a.y)
            if accumulated + seg >= target, seg > 1e-6 {
                let t = (target - accumulated) / seg
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                target += step
            } else {
                accumulated += seg
                i += 1
            }
        }
        while out.count < count { out.append(points.last!) }
        return out
    }

    private static func rdp(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points[0]
        let last = points[points.count - 1]
        var maxDist: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = EraserEngine.distance(from: points[i], toSegment: first, last)
            if d > maxDist {
                maxDist = d
                index = i
            }
        }
        if maxDist > epsilon {
            let left = rdp(Array(points[0...index]), epsilon: epsilon)
            let right = rdp(Array(points[index...]), epsilon: epsilon)
            return Array(left.dropLast()) + right
        }
        return [first, last]
    }
}
