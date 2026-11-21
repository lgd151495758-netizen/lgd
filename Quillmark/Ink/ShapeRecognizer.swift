import CoreGraphics
import Foundation

/// Geometric shapes produced by Draw-and-Hold ("画完按住成形").
enum RecognizedShape: Equatable {
    case line(start: CGPoint, end: CGPoint)
    case arrow(start: CGPoint, end: CGPoint)
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat)
    case polygon(vertices: [CGPoint])

    /// Live adjustment while the user keeps holding and drags after snapping.
    func adjusted(to dragPoint: CGPoint, initialAnchor: CGPoint) -> RecognizedShape {
        switch self {
        case let .line(start, _):
            return .line(start: start, end: ShapeRecognizer.snapAngle(from: start, to: dragPoint, stepDegrees: 90, toleranceDegrees: 1.2))
        case let .arrow(start, _):
            return .arrow(start: start, end: ShapeRecognizer.snapAngle(from: start, to: dragPoint, stepDegrees: 90, toleranceDegrees: 1.2))
        case let .ellipse(center, rx, ry, rotation):
            let base = max(12, hypot(initialAnchor.x - center.x, initialAnchor.y - center.y))
            let current = max(8, hypot(dragPoint.x - center.x, dragPoint.y - center.y))
            let factor = max(0.25, min(4.0, current / base))
            return .ellipse(center: center, rx: rx * factor, ry: ry * factor, rotation: rotation)
        case let .polygon(vertices):
            guard !vertices.isEmpty else { return self }
            let cx = vertices.map(\.x).reduce(0, +) / CGFloat(vertices.count)
            let cy = vertices.map(\.y).reduce(0, +) / CGFloat(vertices.count)
            let center = CGPoint(x: cx, y: cy)
            let base = max(12, hypot(initialAnchor.x - cx, initialAnchor.y - cy))
            let current = max(8, hypot(dragPoint.x - cx, dragPoint.y - cy))
            let factor = max(0.25, min(4.0, current / base))
            let scaled = vertices.map { v in
                CGPoint(x: center.x + (v.x - center.x) * factor,
                        y: center.y + (v.y - center.y) * factor)
            }
            return .polygon(vertices: scaled)
        }
    }

    /// Converts this recognized shape into a first-class parametric `GeometricPrimitive` so its
    /// endpoints, vertices, centers, and intersections participate in ruler/compass snapping.
    var primitive: GeometricPrimitive {
        switch self {
        case let .line(start, end):
            return .segment(a: start, b: end)
        case let .arrow(start, end):
            return .segment(a: start, b: end, startArrow: .none, endArrow: .open)
        case let .ellipse(center, rx, ry, rotation):
            if abs(rx - ry) < 0.5 {
                return .circle(center: center, radius: (rx + ry) / 2, showCenterMark: false)
            }
            return .ellipse(center: center, rx: rx, ry: ry, rotation: rotation)
        case let .polygon(vertices):
            return .polygon(vertices: vertices, closed: true)
        }
    }

    /// Generates clean `StrokeSample`s (with subpath breaks at sharp corners) for rendering & storage.
    func samples(radius: CGFloat) -> [StrokeSample] {
        primitive.samples(radius: radius)
    }
}

/// Recognizes single-stroke geometric shapes when the user pauses at the end of a stroke.
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
        let isClosed = closure <= max(28, diag * 0.32) && length >= max(56, closure * 2.8)

        if !isClosed {
            return recognizeOpen(points, length: length)
        }
        return recognizeClosed(points, diag: diag)
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

    // MARK: Open shapes (line & arrow)

    private static func recognizeOpen(_ points: [CGPoint], length: CGFloat) -> RecognizedShape? {
        // Check single-stroke arrow first so long arrows with modest barbs are not swallowed by line snap.
        if let arrow = recognizeArrow(points) {
            return arrow
        }

        let first = points[0]
        let last = points[points.count - 1]
        let direct = hypot(last.x - first.x, last.y - first.y)

        if direct >= 18 {
            let maxDev = maxDistanceToSegment(points, a: first, b: last)
            if maxDev <= max(6, length * 0.065), length <= direct * 1.18 {
                let snapped = snapAngle(from: first, to: last, stepDegrees: 90, toleranceDegrees: 2.0)
                return .line(start: first, end: snapped)
            }
        }

        // Generous straight-line snap on deliberate draw-and-hold.
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

        // Head must stay near the tip, kick away from the shaft line, and turn back.
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

    // MARK: Closed shapes (circle, ellipse, triangle, rectangle)

    private static func recognizeClosed(_ points: [CGPoint], diag: CGFloat) -> RecognizedShape? {
        let uniform = resampleUniform(points, count: 64)
        let ellipseFit = fitEllipse(uniform)
        let vertices = extractClosedVertices(points, diag: diag)

        if vertices.count == 3 {
            let polyErr = meanDistanceToPolygon(uniform, vertices: vertices) / diag
            if polyErr <= 0.06, (ellipseFit.residual > 0.12 || polyErr * 1.8 < ellipseFit.residual) {
                return .polygon(vertices: vertices)
            }
        }

        if vertices.count == 4 {
            let polyErr = meanDistanceToPolygon(uniform, vertices: vertices) / diag
            let angles = interiorAngles(vertices)
            let isRectangular = angles.allSatisfy { abs($0 - .pi / 2) <= 28 * .pi / 180 }
            if isRectangular, polyErr <= 0.055, (ellipseFit.residual > 0.10 || polyErr * 1.6 < ellipseFit.residual) {
                return .polygon(vertices: makeRectangle(from: vertices))
            }
        }

        if ellipseFit.residual <= 0.18, ellipseFit.rx >= 8, ellipseFit.ry >= 8 {
            let ratio = min(ellipseFit.rx, ellipseFit.ry) / max(ellipseFit.rx, ellipseFit.ry)
            if ratio >= 0.78 {
                let r = (ellipseFit.rx + ellipseFit.ry) / 2
                return .ellipse(center: ellipseFit.center, rx: r, ry: r, rotation: 0)
            }
            var rotation = ellipseFit.rotation
            let snapStep = CGFloat.pi / 2
            let nearest = (rotation / snapStep).rounded() * snapStep
            if abs(rotation - nearest) <= 8 * .pi / 180 {
                rotation = nearest
            }
            return .ellipse(center: ellipseFit.center, rx: ellipseFit.rx, ry: ellipseFit.ry, rotation: rotation)
        }

        if (3...5).contains(vertices.count) {
            let polyErr = meanDistanceToPolygon(uniform, vertices: vertices) / diag
            if polyErr <= 0.065 {
                if vertices.count == 4, interiorAngles(vertices).allSatisfy({ abs($0 - .pi / 2) <= 32 * .pi / 180 }) {
                    return .polygon(vertices: makeRectangle(from: vertices))
                }
                return .polygon(vertices: vertices)
            }
        }
        return nil
    }

    private struct EllipseFit {
        var center: CGPoint
        var rx: CGFloat
        var ry: CGFloat
        var rotation: CGFloat
        var residual: CGFloat
    }

    private static func fitEllipse(_ uniform: [CGPoint]) -> EllipseFit {
        let n = CGFloat(uniform.count)
        let cx = uniform.map(\.x).reduce(0, +) / n
        let cy = uniform.map(\.y).reduce(0, +) / n

        var sxx: CGFloat = 0
        var syy: CGFloat = 0
        var sxy: CGFloat = 0
        for p in uniform {
            let dx = p.x - cx
            let dy = p.y - cy
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        sxx /= n
        syy /= n
        sxy /= n

        let rotation = 0.5 * atan2(2 * sxy, sxx - syy)
        let cosR = cos(rotation)
        let sinR = sin(rotation)

        var u2: CGFloat = 0
        var v2: CGFloat = 0
        for p in uniform {
            let dx = p.x - cx
            let dy = p.y - cy
            let u = dx * cosR + dy * sinR
            let v = -dx * sinR + dy * cosR
            u2 += u * u
            v2 += v * v
        }
        // For a uniform ellipse, E[u^2] = rx^2 / 2 and E[v^2] = ry^2 / 2.
        let rx = max(1, sqrt(2 * u2 / n))
        let ry = max(1, sqrt(2 * v2 / n))

        var errSum: CGFloat = 0
        for p in uniform {
            let dx = p.x - cx
            let dy = p.y - cy
            let u = (dx * cosR + dy * sinR) / rx
            let v = (-dx * sinR + dy * cosR) / ry
            errSum += abs(hypot(u, v) - 1)
        }
        return EllipseFit(center: CGPoint(x: cx, y: cy), rx: rx, ry: ry, rotation: rotation, residual: errSum / n)
    }

    private static func extractClosedVertices(_ points: [CGPoint], diag: CGFloat) -> [CGPoint] {
        var closed = points
        closed.append(points[0])
        var simplified = rdp(closed, epsilon: max(6, diag * 0.055))
        if simplified.count > 1, hypot(simplified.last!.x - simplified.first!.x, simplified.last!.y - simplified.first!.y) < 1 {
            simplified.removeLast()
        }
        // Merge vertices that are too close together (e.g. slight overshoot at stroke closure).
        let minEdge = max(10, diag * 0.14)
        var changed = true
        while changed, simplified.count > 3 {
            changed = false
            for i in 0..<simplified.count {
                let j = (i + 1) % simplified.count
                if hypot(simplified[j].x - simplified[i].x, simplified[j].y - simplified[i].y) < minEdge {
                    let mid = CGPoint(x: (simplified[i].x + simplified[j].x) / 2, y: (simplified[i].y + simplified[j].y) / 2)
                    simplified[i] = mid
                    simplified.remove(at: j)
                    changed = true
                    break
                }
            }
        }
        // Drop nearly-collinear vertices along an edge.
        changed = true
        while changed, simplified.count > 3 {
            changed = false
            let angles = interiorAngles(simplified)
            if let flatIndex = angles.firstIndex(where: { $0 > 154 * .pi / 180 }) {
                simplified.remove(at: flatIndex)
                changed = true
            }
        }
        return simplified
    }

    /// Snaps a 4-vertex quad into a clean rectangle (axis-aligned if within ±8°).
    private static func makeRectangle(from vertices: [CGPoint]) -> [CGPoint] {
        guard vertices.count == 4 else { return vertices }
        let e0 = CGPoint(x: vertices[1].x - vertices[0].x, y: vertices[1].y - vertices[0].y)
        var angle = atan2(e0.y, e0.x)
        let snapStep = CGFloat.pi / 2
        let nearest = (angle / snapStep).rounded() * snapStep
        if abs(angle - nearest) <= 8 * .pi / 180 {
            angle = nearest
        }
        let cosA = cos(-angle)
        let sinA = sin(-angle)
        let rotated = vertices.map { p in
            CGPoint(x: p.x * cosA - p.y * sinA, y: p.x * sinA + p.y * cosA)
        }
        let minX = rotated.map(\.x).min() ?? 0
        let maxX = rotated.map(\.x).max() ?? 0
        let minY = rotated.map(\.y).min() ?? 0
        let maxY = rotated.map(\.y).max() ?? 0
        let corners = [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: maxY),
        ]
        let cosB = cos(angle)
        let sinB = sin(angle)
        return corners.map { p in
            CGPoint(x: p.x * cosB - p.y * sinB, y: p.x * sinB + p.y * cosB)
        }
    }

    // MARK: Geometry helpers

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

    private static func meanDistanceToPolygon(_ points: [CGPoint], vertices: [CGPoint]) -> CGFloat {
        guard vertices.count >= 3, !points.isEmpty else { return .infinity }
        var sum: CGFloat = 0
        for p in points {
            var best = CGFloat.infinity
            for i in 0..<vertices.count {
                let d = EraserEngine.distance(from: p, toSegment: vertices[i], vertices[(i + 1) % vertices.count])
                if d < best { best = d }
            }
            sum += best
        }
        return sum / CGFloat(points.count)
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
