import CoreGraphics
import Foundation

// MARK: - Parametric Geometric Primitives

enum ArrowHeadStyle: String, Codable, Equatable {
    case none
    case open
}

/// Parametric geometric shape stored alongside an `InkStroke` so lines, circles, arcs, polygons
/// and coordinate axes retain exact mathematical semantics (for snapping, intersections, shading,
/// and post-creation vertex editing).
enum GeometricPrimitive: Codable, Equatable {
    case segment(a: CGPoint, b: CGPoint, startArrow: ArrowHeadStyle = .none, endArrow: ArrowHeadStyle = .none)
    case circle(center: CGPoint, radius: CGFloat, showCenterMark: Bool = true)
    case arc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat,
             clockwise: Bool, showCenterMark: Bool = true)
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat)
    case polygon(vertices: [CGPoint], closed: Bool = true)
    /// Exact mathematical parabola:
    /// `P(s) = vertex + (s * halfWidth) * perp + (s^2 * height) * axis` for `s ∈ [-1, 1]`,
    /// where `axis = (cos(axisAngle), sin(axisAngle))` points toward the opening
    /// (`-π/2` opens UP in UIKit +Y down, `+π/2` opens DOWN, `0` opens RIGHT, `π` opens LEFT).
    case parabola(vertex: CGPoint, axisAngle: CGFloat, halfWidth: CGFloat, height: CGFloat)
    /// 2D Cartesian coordinate system (`xMin < 0 < xMax`, `yMin < 0 < yMax` in UIKit +Y down).
    case axes(origin: CGPoint, xMin: CGFloat, xMax: CGFloat, yMin: CGFloat, yMax: CGFloat, tickSpacing: CGFloat = 28)

    var supportsFill: Bool {
        switch self {
        case .circle, .ellipse: return true
        case let .polygon(_, closed): return closed
        case .segment, .arc, .parabola, .axes: return false
        }
    }

    var isCircularWithCenterMark: Bool {
        switch self {
        case .circle, .arc: return true
        default: return false
        }
    }

    var showsCenterMark: Bool {
        switch self {
        case let .circle(_, _, mark), let .arc(_, _, _, _, _, mark): return mark
        default: return false
        }
    }

    func togglingCenterMark() -> GeometricPrimitive {
        switch self {
        case let .circle(c, r, mark):
            return .circle(center: c, radius: r, showCenterMark: !mark)
        case let .arc(c, r, s, e, cw, mark):
            return .arc(center: c, radius: r, startAngle: s, endAngle: e, clockwise: cw, showCenterMark: !mark)
        default:
            return self
        }
    }

    func translated(by offset: CGPoint) -> GeometricPrimitive {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x + offset.x, y: p.y + offset.y)
        }
        switch self {
        case let .segment(a, b, sArrow, eArrow):
            return .segment(a: shift(a), b: shift(b), startArrow: sArrow, endArrow: eArrow)
        case let .circle(center, radius, mark):
            return .circle(center: shift(center), radius: radius, showCenterMark: mark)
        case let .arc(center, radius, start, end, cw, mark):
            return .arc(center: shift(center), radius: radius, startAngle: start, endAngle: end,
                        clockwise: cw, showCenterMark: mark)
        case let .ellipse(center, rx, ry, rotation):
            return .ellipse(center: shift(center), rx: rx, ry: ry, rotation: rotation)
        case let .polygon(vertices, closed):
            return .polygon(vertices: vertices.map(shift), closed: closed)
        case let .parabola(vertex, axisAngle, halfWidth, height):
            return .parabola(vertex: shift(vertex), axisAngle: axisAngle, halfWidth: halfWidth, height: height)
        case let .axes(origin, xMin, xMax, yMin, yMax, tick):
            return .axes(origin: shift(origin), xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax, tickSpacing: tick)
        }
    }

    /// Closed interior path for optional semi-transparent shading (returns `nil` for open shapes).
    func fillPath(transform: CGAffineTransform = .identity) -> CGPath? {
        switch self {
        case let .circle(center, radius, _):
            let r = max(1, radius)
            let p = CGMutablePath()
            p.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r), transform: transform)
            return p

        case let .ellipse(center, rx, ry, rotation):
            let steps = 72
            let cosR = cos(rotation)
            let sinR = sin(rotation)
            let p = CGMutablePath()
            for i in 0..<steps {
                let theta = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
                let lx = rx * cos(theta)
                let ly = ry * sin(theta)
                let pt = CGPoint(x: center.x + lx * cosR - ly * sinR, y: center.y + lx * sinR + ly * cosR)
                if i == 0 { p.move(to: pt, transform: transform) }
                else { p.addLine(to: pt, transform: transform) }
            }
            p.closeSubpath()
            return p

        case let .polygon(vertices, closed):
            guard closed, vertices.count >= 3 else { return nil }
            let p = CGMutablePath()
            p.move(to: vertices[0], transform: transform)
            for v in vertices.dropFirst() {
                p.addLine(to: v, transform: transform)
            }
            p.closeSubpath()
            return p

        case .segment, .arc, .parabola, .axes:
            return nil
        }
    }

    func boundingBox() -> CGRect {
        switch self {
        case let .segment(a, b, _, _):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        case let .circle(c, r, _):
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case let .arc(c, r, s, e, cw, _):
            let pts = samples(radius: 1).filter { $0.radius > 0 }.map(\.point)
            guard let first = pts.first else {
                let p = CGPoint(x: c.x + r * cos(s), y: c.y + r * sin(s))
                let q = CGPoint(x: c.x + r * cos(e), y: c.y + r * sin(e))
                _ = cw
                return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
            }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case let .ellipse(c, rx, ry, rot):
            let ux = rx * cos(rot), uy = rx * sin(rot)
            let vx = -ry * sin(rot), vy = ry * cos(rot)
            let halfW = hypot(ux, vx)
            let halfH = hypot(uy, vy)
            return CGRect(x: c.x - halfW, y: c.y - halfH, width: 2 * halfW, height: 2 * halfH)
        case let .polygon(vertices, _):
            guard let first = vertices.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for v in vertices {
                minX = min(minX, v.x); maxX = max(maxX, v.x)
                minY = min(minY, v.y); maxY = max(maxY, v.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .parabola:
            let pts = samples(radius: 1).map(\.point)
            guard let first = pts.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in pts {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case let .axes(o, xMin, xMax, yMin, yMax, _):
            return CGRect(x: o.x + xMin, y: o.y + yMin, width: xMax - xMin, height: yMax - yMin)
        }
    }

    /// Interactive vertex / control handles for post-creation fine-tuning.
    func controlHandles() -> [CGPoint] {
        switch self {
        case let .segment(a, b, _, _):
            return [a, b]
        case let .circle(c, r, _):
            return [c, CGPoint(x: c.x + r, y: c.y)]
        case let .arc(c, r, s, e, _, _):
            return [
                c,
                CGPoint(x: c.x + r * cos(s), y: c.y + r * sin(s)),
                CGPoint(x: c.x + r * cos(e), y: c.y + r * sin(e)),
            ]
        case let .ellipse(c, rx, ry, rot):
            return [
                c,
                CGPoint(x: c.x + rx * cos(rot), y: c.y + rx * sin(rot)),
                CGPoint(x: c.x - ry * sin(rot), y: c.y + ry * cos(rot)),
            ]
        case let .polygon(vertices, _):
            return vertices
        case let .parabola(vertex, axisAngle, halfWidth, height):
            return [
                vertex,
                Self.parabolaPoint(vertex: vertex, axisAngle: axisAngle, halfWidth: halfWidth, height: height, s: 1),
                Self.parabolaPoint(vertex: vertex, axisAngle: axisAngle, halfWidth: halfWidth, height: height, s: -1),
            ]
        case let .axes(o, xMin, xMax, yMin, yMax, _):
            return [
                o,
                CGPoint(x: o.x + xMin, y: o.y),
                CGPoint(x: o.x + xMax, y: o.y),
                CGPoint(x: o.x, y: o.y + yMin),
                CGPoint(x: o.x, y: o.y + yMax),
            ]
        }
    }

    /// Moves a single control handle to `target` with magnetic snapping to `snapPoints`.
    func movingHandle(at index: Int,
                      to target: CGPoint,
                      snapPoints: [SnapPoint],
                      snapThreshold: CGFloat = 10) -> (primitive: GeometricPrimitive, snapped: SnapPoint?) {
        switch self {
        case let .segment(a, b, sArrow, eArrow):
            guard index == 0 || index == 1 else { return (self, nil) }
            let anchor = (index == 0) ? b : a
            if let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints,
                                                          threshold: snapThreshold, excluding: anchor, excludeRadius: 6) {
                let p = snap.point
                return (index == 0
                        ? .segment(a: p, b: b, startArrow: sArrow, endArrow: eArrow)
                        : .segment(a: a, b: p, startArrow: sArrow, endArrow: eArrow), snap)
            }
            let fine = ShapeRecognizer.snapAngle(from: anchor, to: target, stepDegrees: 90, toleranceDegrees: 1.2)
            return (index == 0
                    ? .segment(a: fine, b: b, startArrow: sArrow, endArrow: eArrow)
                    : .segment(a: a, b: fine, startArrow: sArrow, endArrow: eArrow), nil)

        case let .circle(c, r, mark):
            if index == 0 {
                if let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints, threshold: snapThreshold) {
                    return (.circle(center: snap.point, radius: r, showCenterMark: mark), snap)
                }
                return (.circle(center: target, radius: r, showCenterMark: mark), nil)
            } else if index == 1 {
                let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints,
                                                           threshold: snapThreshold, excluding: c, excludeRadius: 10)
                let p = snap?.point ?? target
                let newR = max(10, hypot(p.x - c.x, p.y - c.y))
                return (.circle(center: c, radius: newR, showCenterMark: mark), snap)
            }
            return (self, nil)

        case let .arc(c, r, s, e, cw, mark):
            if index == 0 {
                if let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints, threshold: snapThreshold) {
                    return (.arc(center: snap.point, radius: r, startAngle: s, endAngle: e, clockwise: cw, showCenterMark: mark), snap)
                }
                return (.arc(center: target, radius: r, startAngle: s, endAngle: e, clockwise: cw, showCenterMark: mark), nil)
            } else if index == 1 || index == 2 {
                let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints,
                                                           threshold: snapThreshold, excluding: c, excludeRadius: 10)
                let p = snap?.point ?? target
                let newR = max(10, hypot(p.x - c.x, p.y - c.y))
                let theta = atan2(p.y - c.y, p.x - c.x)
                return (index == 1
                        ? .arc(center: c, radius: newR, startAngle: theta, endAngle: e, clockwise: cw, showCenterMark: mark)
                        : .arc(center: c, radius: newR, startAngle: s, endAngle: theta, clockwise: cw, showCenterMark: mark), snap)
            }
            return (self, nil)

        case let .ellipse(c, rx, ry, rot):
            if index == 0 {
                let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints, threshold: snapThreshold)
                return (.ellipse(center: snap?.point ?? target, rx: rx, ry: ry, rotation: rot), snap)
            } else if index == 1 {
                let newRx = max(10, hypot(target.x - c.x, target.y - c.y))
                return (.ellipse(center: c, rx: newRx, ry: ry, rotation: rot), nil)
            } else if index == 2 {
                let newRy = max(10, hypot(target.x - c.x, target.y - c.y))
                return (.ellipse(center: c, rx: rx, ry: newRy, rotation: rot), nil)
            }
            return (self, nil)

        case var .polygon(vertices, closed):
            guard index >= 0, index < vertices.count else { return (self, nil) }
            if let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints, threshold: snapThreshold) {
                vertices[index] = snap.point
                return (.polygon(vertices: vertices, closed: closed), snap)
            }
            // Gently snap to horizontal/vertical alignment with adjacent vertices for crisp geometry.
            var adjusted = target
            let prev = vertices[(index - 1 + vertices.count) % vertices.count]
            let next = vertices[(index + 1) % vertices.count]
            if abs(adjusted.x - prev.x) <= 3 { adjusted.x = prev.x }
            else if abs(adjusted.x - next.x) <= 3 { adjusted.x = next.x }
            if abs(adjusted.y - prev.y) <= 3 { adjusted.y = prev.y }
            else if abs(adjusted.y - next.y) <= 3 { adjusted.y = next.y }
            vertices[index] = adjusted
            return (.polygon(vertices: vertices, closed: closed), nil)

        case let .parabola(vertex, axisAngle, halfWidth, height):
            if index == 0 {
                let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints, threshold: snapThreshold)
                return (.parabola(vertex: snap?.point ?? target, axisAngle: axisAngle,
                                  halfWidth: halfWidth, height: height), snap)
            } else if index == 1 || index == 2 {
                let snap = GeometrySnapEngine.nearestPoint(to: target, in: snapPoints,
                                                           threshold: snapThreshold, excluding: vertex, excludeRadius: 12)
                let p = snap?.point ?? target
                let dx = p.x - vertex.x
                let dy = p.y - vertex.y
                let ax = cos(axisAngle), ay = sin(axisAngle)
                let px = -ay, py = ax
                let u = dx * px + dy * py
                let v = dx * ax + dy * ay
                let newHalfW = max(12, abs(u))
                if v < -14 {
                    let flipped = atan2(-ay, -ax)
                    return (.parabola(vertex: vertex, axisAngle: flipped, halfWidth: newHalfW, height: max(12, -v)), snap)
                }
                return (.parabola(vertex: vertex, axisAngle: axisAngle, halfWidth: newHalfW, height: max(12, v)), snap)
            }
            return (self, nil)

        case let .axes(o, xMin, xMax, yMin, yMax, tick):
            switch index {
            case 0:
                // Slide origin O inside the existing outer bounding frame.
                let minX = o.x + xMin + 24
                let maxX = o.x + xMax - 24
                let minY = o.y + yMin + 24
                let maxY = o.y + yMax - 24
                let nx = min(max(minX, target.x), max(minX, maxX))
                let ny = min(max(minY, target.y), max(minY, maxY))
                let newOrigin = CGPoint(x: nx, y: ny)
                return (.axes(origin: newOrigin,
                              xMin: (o.x + xMin) - nx, xMax: (o.x + xMax) - nx,
                              yMin: (o.y + yMin) - ny, yMax: (o.y + yMax) - ny,
                              tickSpacing: tick), nil)
            case 1:
                return (.axes(origin: o, xMin: min(-24, target.x - o.x), xMax: xMax, yMin: yMin, yMax: yMax, tickSpacing: tick), nil)
            case 2:
                return (.axes(origin: o, xMin: xMin, xMax: max(24, target.x - o.x), yMin: yMin, yMax: yMax, tickSpacing: tick), nil)
            case 3:
                return (.axes(origin: o, xMin: xMin, xMax: xMax, yMin: min(-24, target.y - o.y), yMax: yMax, tickSpacing: tick), nil)
            case 4:
                return (.axes(origin: o, xMin: xMin, xMax: xMax, yMin: yMin, yMax: max(24, target.y - o.y), tickSpacing: tick), nil)
            default:
                return (self, nil)
            }
        }
    }

    /// Hit-tests whether `point` lies on the stroke outline or inside a closed shape's body.
    func hitTestBody(_ point: CGPoint, tolerance: CGFloat = 14) -> Bool {
        switch self {
        case let .segment(a, b, _, _):
            return EraserEngine.distance(from: point, toSegment: a, b) <= tolerance
        case let .circle(c, r, _):
            let d = hypot(point.x - c.x, point.y - c.y)
            return d <= r + tolerance
        case let .arc(c, r, s, e, cw, _):
            let d = hypot(point.x - c.x, point.y - c.y)
            guard abs(d - r) <= tolerance else { return false }
            let curve = GeometrySnapEngine.CircularCurve(center: c, radius: r, startAngle: s, endAngle: e, clockwise: cw)
            return curve.containsAngle(atan2(point.y - c.y, point.x - c.x))
        case let .ellipse(c, rx, ry, rot):
            let dx = point.x - c.x, dy = point.y - c.y
            let u = dx * cos(rot) + dy * sin(rot)
            let v = -dx * sin(rot) + dy * cos(rot)
            return hypot(u / max(1, rx + tolerance), v / max(1, ry + tolerance)) <= 1
        case let .polygon(vertices, closed):
            guard vertices.count >= 2 else { return false }
            let edgeCount = closed ? vertices.count : vertices.count - 1
            for i in 0..<edgeCount {
                if EraserEngine.distance(from: point, toSegment: vertices[i], vertices[(i + 1) % vertices.count]) <= tolerance {
                    return true
                }
            }
            if closed, let path = fillPath() {
                return path.contains(point)
            }
            return false
        case let .parabola(vertex, axisAngle, halfWidth, height):
            let steps = 36
            var prev = Self.parabolaPoint(vertex: vertex, axisAngle: axisAngle, halfWidth: halfWidth, height: height, s: -1)
            for i in 1...steps {
                let s = -1 + 2 * CGFloat(i) / CGFloat(steps)
                let curr = Self.parabolaPoint(vertex: vertex, axisAngle: axisAngle, halfWidth: halfWidth, height: height, s: s)
                if EraserEngine.distance(from: point, toSegment: prev, curr) <= tolerance {
                    return true
                }
                prev = curr
            }
            return false
        case let .axes(o, xMin, xMax, yMin, yMax, _):
            let hitX = EraserEngine.distance(from: point,
                                             toSegment: CGPoint(x: o.x + xMin, y: o.y),
                                             CGPoint(x: o.x + xMax, y: o.y)) <= tolerance
            let hitY = EraserEngine.distance(from: point,
                                             toSegment: CGPoint(x: o.x, y: o.y + yMin),
                                             CGPoint(x: o.x, y: o.y + yMax)) <= tolerance
            return hitX || hitY
        }
    }

    /// Generates dense centerline samples (using `StrokeOutline.breakSample` between disconnected
    /// parts such as arrow wings, polygon edges, or circle center marks).
    func samples(radius: CGFloat) -> [StrokeSample] {
        let r = max(StrokeProcessor.minimumRadius, radius)
        switch self {
        case let .segment(a, b, startArrow, endArrow):
            var result = Self.segmentSamples(from: a, to: b, radius: r)
            if endArrow == .open {
                result.append(contentsOf: Self.arrowWings(from: a, to: b, radius: r))
            }
            if startArrow == .open {
                result.append(contentsOf: Self.arrowWings(from: b, to: a, radius: r))
            }
            return result

        case let .circle(center, circleRadius, showCenterMark):
            let cr = max(1, circleRadius)
            let circumference = 2 * CGFloat.pi * cr
            let steps = max(48, min(220, Int(ceil(circumference / 2.5))))
            var result = (0...steps).map { i -> StrokeSample in
                let theta = 2 * CGFloat.pi * CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: center.x + cr * cos(theta), y: center.y + cr * sin(theta))
                return StrokeSample(point: p, radius: r)
            }
            if showCenterMark {
                result.append(StrokeOutline.breakSample)
                result.append(StrokeSample(point: center, radius: max(2.0, r * 1.45)))
            }
            return result

        case let .arc(center, arcRadius, startAngle, endAngle, clockwise, showCenterMark):
            let ar = max(1, arcRadius)
            let sweep = Self.signedSweep(start: startAngle, end: endAngle, clockwise: clockwise)
            let arcLen = abs(sweep) * ar
            let steps = max(8, min(220, Int(ceil(arcLen / 2.2))))
            var result = (0...steps).map { i -> StrokeSample in
                let t = CGFloat(i) / CGFloat(steps)
                let theta = startAngle + sweep * t
                let p = CGPoint(x: center.x + ar * cos(theta), y: center.y + ar * sin(theta))
                return StrokeSample(point: p, radius: r)
            }
            if showCenterMark {
                result.append(StrokeOutline.breakSample)
                result.append(StrokeSample(point: center, radius: max(2.0, r * 1.45)))
            }
            return result

        case let .ellipse(center, rx, ry, rotation):
            let perimeter = CGFloat.pi * (3 * (rx + ry) - sqrt((3 * rx + ry) * (rx + 3 * ry)))
            let steps = max(48, min(180, Int(perimeter / 2.5)))
            let cosR = cos(rotation)
            let sinR = sin(rotation)
            return (0...steps).map { i in
                let theta = (2 * CGFloat.pi * CGFloat(i)) / CGFloat(steps)
                let lx = rx * cos(theta)
                let ly = ry * sin(theta)
                let p = CGPoint(x: center.x + lx * cosR - ly * sinR,
                                y: center.y + lx * sinR + ly * cosR)
                return StrokeSample(point: p, radius: r)
            }

        case let .polygon(vertices, closed):
            guard vertices.count >= 2 else { return [] }
            var result: [StrokeSample] = []
            let edgeCount = closed ? vertices.count : vertices.count - 1
            for i in 0..<edgeCount {
                if i > 0 { result.append(StrokeOutline.breakSample) }
                let a = vertices[i]
                let b = vertices[(i + 1) % vertices.count]
                result.append(contentsOf: Self.segmentSamples(from: a, to: b, radius: r))
            }
            return result

        case let .parabola(vertex, axisAngle, halfWidth, height):
            let hw = max(4, halfWidth)
            let h = max(4, height)
            let approxLen = 2 * hypot(hw, h)
            let rawSteps = max(36, min(140, Int(ceil(approxLen / 2.2))))
            // Ensure an even step count so s = 0 (the exact vertex) is always sampled cleanly.
            let steps = rawSteps + (rawSteps % 2)
            return (0...steps).map { i in
                let s = -1 + 2 * CGFloat(i) / CGFloat(steps)
                let p = Self.parabolaPoint(vertex: vertex, axisAngle: axisAngle, halfWidth: hw, height: h, s: s)
                return StrokeSample(point: p, radius: r)
            }

        case let .axes(origin, xMin, xMax, yMin, yMax, tickSpacing):
            var result: [StrokeSample] = []
            let xStart = CGPoint(x: origin.x + xMin, y: origin.y)
            let xEnd = CGPoint(x: origin.x + xMax, y: origin.y)
            result.append(contentsOf: Self.segmentSamples(from: xStart, to: xEnd, radius: r))
            result.append(contentsOf: Self.arrowWings(from: xStart, to: xEnd, radius: r))

            // Vertical y-axis points UP in mathematical coordinates (from yMax down to yMin in UIKit +Y down).
            let yBottom = CGPoint(x: origin.x, y: origin.y + yMax)
            let yTop = CGPoint(x: origin.x, y: origin.y + yMin)
            result.append(StrokeOutline.breakSample)
            result.append(contentsOf: Self.segmentSamples(from: yBottom, to: yTop, radius: r))
            result.append(contentsOf: Self.arrowWings(from: yBottom, to: yTop, radius: r))

            // Crisp tick marks along both axes (skipping origin and arrowhead margin).
            let step = max(12, tickSpacing)
            let tickHalf = max(3.5, r * 2.6)
            let tickR = max(StrokeProcessor.minimumRadius, r * 0.78)
            var tx = step
            while tx <= xMax - 14 {
                result.append(StrokeOutline.breakSample)
                result.append(contentsOf: Self.segmentSamples(
                    from: CGPoint(x: origin.x + tx, y: origin.y - tickHalf),
                    to: CGPoint(x: origin.x + tx, y: origin.y + tickHalf), radius: tickR))
                tx += step
            }
            tx = -step
            while tx >= xMin + 6 {
                result.append(StrokeOutline.breakSample)
                result.append(contentsOf: Self.segmentSamples(
                    from: CGPoint(x: origin.x + tx, y: origin.y - tickHalf),
                    to: CGPoint(x: origin.x + tx, y: origin.y + tickHalf), radius: tickR))
                tx -= step
            }
            var ty = step
            while ty <= yMax - 6 {
                result.append(StrokeOutline.breakSample)
                result.append(contentsOf: Self.segmentSamples(
                    from: CGPoint(x: origin.x - tickHalf, y: origin.y + ty),
                    to: CGPoint(x: origin.x + tickHalf, y: origin.y + ty), radius: tickR))
                ty += step
            }
            ty = -step
            while ty >= yMin + 14 {
                result.append(StrokeOutline.breakSample)
                result.append(contentsOf: Self.segmentSamples(
                    from: CGPoint(x: origin.x - tickHalf, y: origin.y + ty),
                    to: CGPoint(x: origin.x + tickHalf, y: origin.y + ty), radius: tickR))
                ty -= step
            }
            return result
        }
    }

    /// Evaluates a point along a parametric parabola for `s ∈ [-1, 1]` (`s = 0` is the exact vertex).
    static func parabolaPoint(vertex: CGPoint,
                              axisAngle: CGFloat,
                              halfWidth: CGFloat,
                              height: CGFloat,
                              s: CGFloat) -> CGPoint {
        let ax = cos(axisAngle)
        let ay = sin(axisAngle)
        let px = -ay
        let py = ax
        let u = s * halfWidth
        let v = s * s * height
        return CGPoint(x: vertex.x + u * px + v * ax,
                       y: vertex.y + u * py + v * ay)
    }

    /// Computes signed angular sweep in UIKit coordinates (+Y down: clockwise means increasing angle).
    static func signedSweep(start: CGPoint, end: CGPoint) -> CGFloat {
        atan2(end.y - start.y, end.x - start.x)
    }

    static func signedSweep(start: CGFloat, end: CGFloat, clockwise: Bool) -> CGFloat {
        var delta = end - start
        if abs(delta) >= 2 * .pi - 1e-4 {
            return clockwise ? 2 * .pi : -2 * .pi
        }
        if clockwise {
            while delta < 0 { delta += 2 * .pi }
            while delta > 2 * .pi { delta -= 2 * .pi }
        } else {
            while delta > 0 { delta -= 2 * .pi }
            while delta < -2 * .pi { delta += 2 * .pi }
        }
        return delta
    }

    private static func segmentSamples(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> [StrokeSample] {
        let len = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(ceil(len / 2.0)))
        return (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return StrokeSample(point: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), radius: radius)
        }
    }

    private static func arrowWings(from start: CGPoint, to end: CGPoint, radius: CGFloat) -> [StrokeSample] {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 4 else { return [] }
        let ux = dx / length
        let uy = dy / length
        let headLen = min(max(12, radius * 9), length * 0.34)
        let angle: CGFloat = 28 * .pi / 180
        let cosA = cos(angle)
        let sinA = sin(angle)
        let leftWing = CGPoint(x: end.x - headLen * (ux * cosA - uy * sinA),
                               y: end.y - headLen * (uy * cosA + ux * sinA))
        let rightWing = CGPoint(x: end.x - headLen * (ux * cosA + uy * sinA),
                                y: end.y - headLen * (uy * cosA - ux * sinA))
        var out: [StrokeSample] = []
        out.append(StrokeOutline.breakSample)
        out.append(contentsOf: segmentSamples(from: leftWing, to: end, radius: radius))
        out.append(StrokeOutline.breakSample)
        out.append(contentsOf: segmentSamples(from: rightWing, to: end, radius: radius))
        return out
    }
}

// MARK: - Geometric Snap & Analytic Intersection Engine

enum SnapKind: Equatable {
    case intersection
    case endpoint
    case center
    case midpoint
}

struct SnapPoint: Equatable {
    var point: CGPoint
    var kind: SnapKind
}

/// Computes magnetic snap candidates (endpoints, centers, midpoints, and exact analytic
/// line-line / line-circle / circle-circle intersections) across visible geometric strokes.
enum GeometrySnapEngine {
    struct Segment {
        var a: CGPoint
        var b: CGPoint
    }

    struct CircularCurve {
        var center: CGPoint
        var radius: CGFloat
        var startAngle: CGFloat?
        var endAngle: CGFloat?
        var clockwise: Bool

        func containsAngle(_ theta: CGFloat) -> Bool {
            guard let start = startAngle, let end = endAngle else { return true }
            let total = GeometricPrimitive.signedSweep(start: start, end: end, clockwise: clockwise)
            let tol: CGFloat = 0.03
            if abs(total) >= 2 * .pi - tol { return true }
            let rel = GeometricPrimitive.signedSweep(start: start, end: theta, clockwise: clockwise)
            if clockwise {
                return (rel >= -tol && rel <= total + tol) || rel >= 2 * .pi - tol
            } else {
                return (rel <= tol && rel >= total - tol) || rel <= -2 * .pi + tol
            }
        }
    }

    /// Collects snap points in document CSS coordinates from all visible geometric strokes,
    /// optionally excluding `excludingStrokeID` (used while editing that stroke's own vertices).
    static func snapPoints(from strokes: [InkStroke],
                           origins: [UUID: CGPoint],
                           excludingStrokeID: UUID? = nil) -> [SnapPoint] {
        var primitives: [GeometricPrimitive] = []
        for stroke in strokes {
            if let excludingStrokeID, stroke.id == excludingStrokeID { continue }
            guard let geom = stroke.geometry else { continue }
            if let origin = origins[stroke.id] {
                primitives.append(geom.translated(by: origin))
            } else if stroke.anchor == nil {
                primitives.append(geom)
            }
        }
        return snapPoints(from: primitives)
    }

    static func snapPoints(from primitives: [GeometricPrimitive]) -> [SnapPoint] {
        var points: [SnapPoint] = []
        var segments: [Segment] = []
        var curves: [CircularCurve] = []

        for primitive in primitives {
            switch primitive {
            case let .segment(a, b, _, _):
                points.append(SnapPoint(point: a, kind: .endpoint))
                points.append(SnapPoint(point: b, kind: .endpoint))
                points.append(SnapPoint(point: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), kind: .midpoint))
                segments.append(Segment(a: a, b: b))

            case let .circle(center, radius, _):
                points.append(SnapPoint(point: center, kind: .center))
                curves.append(CircularCurve(center: center, radius: radius, startAngle: nil, endAngle: nil, clockwise: true))

            case let .arc(center, radius, start, end, clockwise, _):
                points.append(SnapPoint(point: center, kind: .center))
                let pStart = CGPoint(x: center.x + radius * cos(start), y: center.y + radius * sin(start))
                let pEnd = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
                points.append(SnapPoint(point: pStart, kind: .endpoint))
                points.append(SnapPoint(point: pEnd, kind: .endpoint))
                curves.append(CircularCurve(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: clockwise))

            case let .ellipse(center, _, _, _):
                points.append(SnapPoint(point: center, kind: .center))

            case let .polygon(vertices, closed):
                guard vertices.count >= 2 else { continue }
                for v in vertices {
                    points.append(SnapPoint(point: v, kind: .endpoint))
                }
                let edgeCount = closed ? vertices.count : vertices.count - 1
                for i in 0..<edgeCount {
                    let a = vertices[i]
                    let b = vertices[(i + 1) % vertices.count]
                    points.append(SnapPoint(point: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), kind: .midpoint))
                    segments.append(Segment(a: a, b: b))
                }

            case let .parabola(vertex, axisAngle, halfWidth, height):
                points.append(SnapPoint(point: vertex, kind: .center))
                points.append(SnapPoint(point: GeometricPrimitive.parabolaPoint(vertex: vertex, axisAngle: axisAngle,
                                                                                halfWidth: halfWidth, height: height, s: -1),
                                        kind: .endpoint))
                points.append(SnapPoint(point: GeometricPrimitive.parabolaPoint(vertex: vertex, axisAngle: axisAngle,
                                                                                halfWidth: halfWidth, height: height, s: 1),
                                        kind: .endpoint))

            case let .axes(origin, xMin, xMax, yMin, yMax, _):
                points.append(SnapPoint(point: origin, kind: .center))
                segments.append(Segment(a: CGPoint(x: origin.x + xMin, y: origin.y),
                                        b: CGPoint(x: origin.x + xMax, y: origin.y)))
                segments.append(Segment(a: CGPoint(x: origin.x, y: origin.y + yMin),
                                        b: CGPoint(x: origin.x, y: origin.y + yMax)))
            }
        }

        // Segment x Segment intersections
        if segments.count >= 2 {
            for i in 0..<(segments.count - 1) {
                for j in (i + 1)..<segments.count {
                    if let hit = intersect(segments[i], segments[j]) {
                        points.append(SnapPoint(point: hit, kind: .intersection))
                    }
                }
            }
        }

        // Segment x Circle/Arc intersections
        for seg in segments {
            for curve in curves {
                for hit in intersect(seg, curve) {
                    points.append(SnapPoint(point: hit, kind: .intersection))
                }
            }
        }

        // Circle/Arc x Circle/Arc intersections (compass-and-straightedge core!)
        if curves.count >= 2 {
            for i in 0..<(curves.count - 1) {
                for j in (i + 1)..<curves.count {
                    for hit in intersect(curves[i], curves[j]) {
                        points.append(SnapPoint(point: hit, kind: .intersection))
                    }
                }
            }
        }

        return points
    }

    /// Finds the best snap point within `threshold`, prioritizing intersections & endpoints over midpoints.
    static func nearestPoint(to target: CGPoint,
                             in candidates: [SnapPoint],
                             threshold: CGFloat = 12,
                             excluding: CGPoint? = nil,
                             excludeRadius: CGFloat = 0) -> SnapPoint? {
        var best: SnapPoint?
        var bestScore = CGFloat.infinity
        for c in candidates {
            if let excluding, hypot(c.point.x - excluding.x, c.point.y - excluding.y) < excludeRadius {
                continue
            }
            let d = hypot(c.point.x - target.x, c.point.y - target.y)
            guard d <= threshold else { continue }
            let bias: CGFloat
            switch c.kind {
            case .intersection: bias = 0
            case .endpoint, .center: bias = 1.5
            case .midpoint: bias = 4.0
            }
            let score = d + bias
            if score < bestScore {
                bestScore = score
                best = c
            }
        }
        return best
    }

    static func intersect(_ s1: Segment, _ s2: Segment) -> CGPoint? {
        let r = CGPoint(x: s1.b.x - s1.a.x, y: s1.b.y - s1.a.y)
        let s = CGPoint(x: s2.b.x - s2.a.x, y: s2.b.y - s2.a.y)
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > 1e-6 else { return nil }
        let qp = CGPoint(x: s2.a.x - s1.a.x, y: s2.a.y - s1.a.y)
        let t = (qp.x * s.y - qp.y * s.x) / denom
        let u = (qp.x * r.y - qp.y * r.x) / denom
        guard t >= -1e-4, t <= 1 + 1e-4, u >= -1e-4, u <= 1 + 1e-4 else { return nil }
        return CGPoint(x: s1.a.x + t * r.x, y: s1.a.y + t * r.y)
    }

    static func intersect(_ seg: Segment, _ curve: CircularCurve) -> [CGPoint] {
        let dx = seg.b.x - seg.a.x
        let dy = seg.b.y - seg.a.y
        let fx = seg.a.x - curve.center.x
        let fy = seg.a.y - curve.center.y
        let a = dx * dx + dy * dy
        guard a > 1e-6 else { return [] }
        let b = 2 * (fx * dx + fy * dy)
        let c = fx * fx + fy * fy - curve.radius * curve.radius
        let disc = b * b - 4 * a * c
        guard disc >= -1e-4 else { return [] }
        let sqrtDisc = sqrt(max(0, disc))
        let roots = sqrtDisc < 1e-5 ? [-b / (2 * a)] : [(-b - sqrtDisc) / (2 * a), (-b + sqrtDisc) / (2 * a)]
        var hits: [CGPoint] = []
        for t in roots where t >= -1e-4 && t <= 1 + 1e-4 {
            let p = CGPoint(x: seg.a.x + t * dx, y: seg.a.y + t * dy)
            let theta = atan2(p.y - curve.center.y, p.x - curve.center.x)
            if curve.containsAngle(theta) {
                hits.append(p)
            }
        }
        return hits
    }

    static func intersect(_ c1: CircularCurve, _ c2: CircularCurve) -> [CGPoint] {
        let dx = c2.center.x - c1.center.x
        let dy = c2.center.y - c1.center.y
        let d = hypot(dx, dy)
        guard d > 1e-5 else { return [] }
        if d > c1.radius + c2.radius + 1e-4 { return [] }
        if d < abs(c1.radius - c2.radius) - 1e-4 { return [] }

        let a = (c1.radius * c1.radius - c2.radius * c2.radius + d * d) / (2 * d)
        let hSq = c1.radius * c1.radius - a * a
        guard hSq >= -1e-4 else { return [] }
        let h = sqrt(max(0, hSq))
        let xm = c1.center.x + a * dx / d
        let ym = c1.center.y + a * dy / d
        let rx = -dy * (h / d)
        let ry = dx * (h / d)

        let raw: [CGPoint] = h < 1e-4
            ? [CGPoint(x: xm, y: ym)]
            : [CGPoint(x: xm + rx, y: ym + ry), CGPoint(x: xm - rx, y: ym - ry)]

        return raw.filter { p in
            let t1 = atan2(p.y - c1.center.y, p.x - c1.center.x)
            let t2 = atan2(p.y - c2.center.y, p.x - c2.center.x)
            return c1.containsAngle(t1) && c2.containsAngle(t2)
        }
    }
}

// MARK: - Virtual Compass (One-Handed Apple Pencil Operable)

enum GeometryAid: String, Equatable {
    case none
    case compass
}

struct CompassState: Equatable {
    enum HitZone: Equatable {
        case none
        case needle
        case resizeHandle
        case drawCircle
        case lockButton
        case centerMarkButton
        case fullCircleButton
    }

    static let minRadius: CGFloat = 20
    static let maxRadius: CGFloat = 420
    static let barSize = CGSize(width: 214, height: 34)

    var center: CGPoint = .zero
    var radius: CGFloat = 95
    var armAngle: CGFloat = -.pi / 4
    var isRadiusLocked: Bool = false
    var showCenterMark: Bool = true

    var penFoot: CGPoint {
        CGPoint(x: center.x + radius * cos(armAngle), y: center.y + radius * sin(armAngle))
    }

    /// Resize handle sits on the exact opposite point of the dashed circle (`distance == radius`)
    /// so pulling it onto a target point B measures |OB| to the exact pixel.
    var resizeHandleCenter: CGPoint {
        CGPoint(x: center.x - radius * cos(armAngle), y: center.y - radius * sin(armAngle))
    }

    /// Position of the compact action bar (clamped inside `bounds`, never overlapping the needle).
    func actionBarFrame(in bounds: CGRect) -> CGRect {
        let w = Self.barSize.width
        let h = Self.barSize.height
        let x = min(max(12, center.x - w / 2), max(12, bounds.width - w - 12))
        let preferredTop = center.y - max(radius, 56) - h - 18
        let y: CGFloat
        if preferredTop >= 10 {
            y = preferredTop
        } else {
            let below = center.y + max(radius, 56) + 18
            if below + h <= bounds.height - 12 {
                y = below
            } else {
                y = min(max(10, center.y - h - 42), max(10, bounds.height - h - 12))
            }
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func buttonFrames(in bounds: CGRect) -> (lock: CGRect, centerMark: CGRect, fullCircle: CGRect) {
        let bar = actionBarFrame(in: bounds)
        let segW = bar.width / 3
        return (
            lock: CGRect(x: bar.minX, y: bar.minY, width: segW, height: bar.height),
            centerMark: CGRect(x: bar.minX + segW, y: bar.minY, width: segW, height: bar.height),
            fullCircle: CGRect(x: bar.minX + 2 * segW, y: bar.minY, width: segW, height: bar.height)
        )
    }

    func hitTest(_ point: CGPoint, in bounds: CGRect) -> HitZone {
        let buttons = buttonFrames(in: bounds)
        if buttons.lock.insetBy(dx: -2, dy: -4).contains(point) { return .lockButton }
        if buttons.centerMark.insetBy(dx: -2, dy: -4).contains(point) { return .centerMarkButton }
        if buttons.fullCircle.insetBy(dx: -2, dy: -4).contains(point) { return .fullCircleButton }

        let needleHitRadius = min(24, max(12, radius * 0.45))
        if hypot(point.x - center.x, point.y - center.y) <= needleHitRadius {
            return .needle
        }

        if !isRadiusLocked {
            let resizeHitRadius = min(22, max(12, radius * 0.45))
            let handle = resizeHandleCenter
            if hypot(point.x - handle.x, point.y - handle.y) <= resizeHitRadius {
                return .resizeHandle
            }
        }

        let distFromCenter = hypot(point.x - center.x, point.y - center.y)
        if abs(distFromCenter - radius) <= 24 {
            return .drawCircle
        }
        return .none
    }

    @discardableResult
    mutating func moveCenter(to rawCenter: CGPoint, snapPoints: [SnapPoint], threshold: CGFloat = 12) -> SnapPoint? {
        if let snap = GeometrySnapEngine.nearestPoint(to: rawCenter, in: snapPoints, threshold: threshold) {
            center = snap.point
            return snap
        }
        center = rawCenter
        return nil
    }

    @discardableResult
    mutating func resize(withHandleAt rawPoint: CGPoint, snapPoints: [SnapPoint], threshold: CGFloat = 12) -> SnapPoint? {
        guard !isRadiusLocked else { return nil }
        let target: CGPoint
        let snapped: SnapPoint?
        if let snap = GeometrySnapEngine.nearestPoint(to: rawPoint, in: snapPoints, threshold: threshold,
                                                      excluding: center, excludeRadius: Self.minRadius) {
            target = snap.point
            snapped = snap
        } else {
            target = rawPoint
            snapped = nil
        }
        let d = hypot(target.x - center.x, target.y - center.y)
        radius = min(Self.maxRadius, max(Self.minRadius, d))
        if d > 4 {
            // Keep pen foot directly opposite the dragged resize handle.
            armAngle = atan2(center.y - target.y, center.x - target.x)
        }
        return snapped
    }
}

/// Tracks continuous unwrapped angular sweep while Apple Pencil draws an arc/circle with the compass.
struct CompassSweep: Equatable {
    static let autoCloseThresholdDegrees: CGFloat = 345

    var startAngle: CGFloat
    var lastAngle: CGFloat
    var totalSweep: CGFloat = 0

    init(startAngle: CGFloat) {
        self.startAngle = startAngle
        self.lastAngle = startAngle
    }

    var currentAngle: CGFloat { startAngle + totalSweep }
    var isClockwise: Bool { totalSweep >= 0 }
    var isFullCircle: Bool { abs(totalSweep) >= Self.autoCloseThresholdDegrees * .pi / 180 }
    var sweepDegrees: Int { Int((abs(totalSweep) * 180 / .pi).rounded()) }

    mutating func advance(to point: CGPoint, center: CGPoint) {
        guard hypot(point.x - center.x, point.y - center.y) > 4 else { return }
        let angle = atan2(point.y - center.y, point.x - center.x)
        let delta = atan2(sin(angle - lastAngle), cos(angle - lastAngle))
        lastAngle = angle
        let limit = 2 * CGFloat.pi
        totalSweep = min(limit, max(-limit, totalSweep + delta))
    }

    func primitive(center: CGPoint, radius: CGFloat, showCenterMark: Bool) -> GeometricPrimitive? {
        guard abs(totalSweep) >= 2 * .pi / 180 else { return nil }
        if isFullCircle {
            return .circle(center: center, radius: radius, showCenterMark: showCenterMark)
        }
        return .arc(center: center, radius: radius,
                    startAngle: startAngle, endAngle: startAngle + totalSweep,
                    clockwise: isClockwise, showCenterMark: showCenterMark)
    }
}

// MARK: - Standard Math Shape Builder

/// Builds crisp standard geometric primitives from a single drag gesture `(start -> end)`,
/// supporting magnetic snapping to existing endpoints, intersections, and centers.
enum ShapeBuilder {
    static func build(preset: ShapePreset,
                      from start: CGPoint,
                      to end: CGPoint,
                      snapPoints: [SnapPoint] = [],
                      snapThreshold: CGFloat = 10) -> (primitive: GeometricPrimitive, snapped: SnapPoint?) {
        let endSnap = GeometrySnapEngine.nearestPoint(to: end, in: snapPoints,
                                                      threshold: snapThreshold, excluding: start, excludeRadius: 8)
        let resolvedEnd = endSnap?.point ?? end

        switch preset {
        case .segment:
            let finalEnd = endSnap?.point
                ?? ShapeRecognizer.snapAngle(from: start, to: end, stepDegrees: 90, toleranceDegrees: 1.2)
            return (.segment(a: start, b: finalEnd), endSnap)

        case .arrow:
            let finalEnd = endSnap?.point
                ?? ShapeRecognizer.snapAngle(from: start, to: end, stepDegrees: 90, toleranceDegrees: 1.2)
            return (.segment(a: start, b: finalEnd, startArrow: .none, endArrow: .open), endSnap)

        case .circle:
            let r = max(8, hypot(resolvedEnd.x - start.x, resolvedEnd.y - start.y))
            return (.circle(center: start, radius: r, showCenterMark: true), endSnap)

        case .rightTriangle:
            // Right angle sits at (start.x, end.y), so drag direction naturally chooses corner orientation!
            let a = start
            let b = CGPoint(x: start.x, y: resolvedEnd.y)
            let c = resolvedEnd
            return (.polygon(vertices: [a, b, c], closed: true), endSnap)

        case .isoscelesTriangle:
            let minX = min(start.x, resolvedEnd.x)
            let maxX = max(start.x, resolvedEnd.x)
            let minY = min(start.y, resolvedEnd.y)
            let maxY = max(start.y, resolvedEnd.y)
            let midX = (minX + maxX) / 2
            let vertices: [CGPoint] = resolvedEnd.y >= start.y
                ? [CGPoint(x: midX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
                : [CGPoint(x: midX, y: maxY), CGPoint(x: maxX, y: minY), CGPoint(x: minX, y: minY)]
            return (.polygon(vertices: vertices, closed: true), endSnap)

        case .equilateralTriangle:
            let dx = resolvedEnd.x - start.x
            let dy = resolvedEnd.y - start.y
            let root3 = CGFloat(3).squareRoot()
            let side = max(12, max(abs(dx), abs(dy) * 2 / root3))
            let height = side * root3 / 2
            let midX = start.x + (dx >= 0 ? side / 2 : -side / 2)
            let leftX = midX - side / 2
            let rightX = midX + side / 2
            let vertices: [CGPoint]
            if dy >= 0 {
                let topY = start.y
                let baseY = start.y + height
                vertices = [CGPoint(x: midX, y: topY), CGPoint(x: rightX, y: baseY), CGPoint(x: leftX, y: baseY)]
            } else {
                let apexY = start.y - height
                let baseY = start.y
                vertices = [CGPoint(x: midX, y: apexY), CGPoint(x: rightX, y: baseY), CGPoint(x: leftX, y: baseY)]
            }
            return (.polygon(vertices: vertices, closed: true), endSnap)

        case .rectangle:
            var w = abs(resolvedEnd.x - start.x)
            var h = abs(resolvedEnd.y - start.y)
            // Softly snap near-squares (within 6%) to exact squares when not snapping to a target point.
            if endSnap == nil, max(w, h) > 20, abs(w - h) / max(w, h) <= 0.06 {
                let side = (w + h) / 2
                w = side
                h = side
            }
            let x2 = start.x + (resolvedEnd.x >= start.x ? w : -w)
            let y2 = start.y + (resolvedEnd.y >= start.y ? h : -h)
            let minX = min(start.x, x2), maxX = max(start.x, x2)
            let minY = min(start.y, y2), maxY = max(start.y, y2)
            return (.polygon(vertices: [
                CGPoint(x: minX, y: minY),
                CGPoint(x: maxX, y: minY),
                CGPoint(x: maxX, y: maxY),
                CGPoint(x: minX, y: maxY),
            ], closed: true), endSnap)

        case .parallelogram:
            let minX = min(start.x, resolvedEnd.x), maxX = max(start.x, resolvedEnd.x)
            let minY = min(start.y, resolvedEnd.y), maxY = max(start.y, resolvedEnd.y)
            let skew = (maxX - minX) * 0.22
            return (.polygon(vertices: [
                CGPoint(x: minX + skew, y: minY),
                CGPoint(x: maxX, y: minY),
                CGPoint(x: maxX - skew, y: maxY),
                CGPoint(x: minX, y: maxY),
            ], closed: true), endSnap)

        case .rhombus:
            let minX = min(start.x, resolvedEnd.x), maxX = max(start.x, resolvedEnd.x)
            let minY = min(start.y, resolvedEnd.y), maxY = max(start.y, resolvedEnd.y)
            let midX = (minX + maxX) / 2
            let midY = (minY + maxY) / 2
            return (.polygon(vertices: [
                CGPoint(x: midX, y: minY),
                CGPoint(x: maxX, y: midY),
                CGPoint(x: midX, y: maxY),
                CGPoint(x: minX, y: midY),
            ], closed: true), endSnap)

        case .trapezoid:
            let minX = min(start.x, resolvedEnd.x), maxX = max(start.x, resolvedEnd.x)
            let minY = min(start.y, resolvedEnd.y), maxY = max(start.y, resolvedEnd.y)
            let inset = (maxX - minX) * 0.20
            return (.polygon(vertices: [
                CGPoint(x: minX + inset, y: minY),
                CGPoint(x: maxX - inset, y: minY),
                CGPoint(x: maxX, y: maxY),
                CGPoint(x: minX, y: maxY),
            ], closed: true), endSnap)

        case .pentagon:
            let minX = min(start.x, resolvedEnd.x), maxX = max(start.x, resolvedEnd.x)
            let minY = min(start.y, resolvedEnd.y), maxY = max(start.y, resolvedEnd.y)
            let cx = (minX + maxX) / 2
            let cy = (minY + maxY) / 2
            let r = max(14, max(maxX - minX, maxY - minY) / 2)
            let startAngle: CGFloat = (resolvedEnd.y >= start.y) ? -CGFloat.pi / 2 : CGFloat.pi / 2
            let verts = (0..<5).map { i -> CGPoint in
                let a = startAngle + 2 * CGFloat.pi * CGFloat(i) / 5
                return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            }
            return (.polygon(vertices: verts, closed: true), endSnap)

        case .hexagon:
            let minX = min(start.x, resolvedEnd.x), maxX = max(start.x, resolvedEnd.x)
            let minY = min(start.y, resolvedEnd.y), maxY = max(start.y, resolvedEnd.y)
            let cx = (minX + maxX) / 2
            let cy = (minY + maxY) / 2
            let r = max(14, max(maxX - minX, maxY - minY) / 2)
            let verts = (0..<6).map { i -> CGPoint in
                let a = 2 * CGFloat.pi * CGFloat(i) / 6
                return CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
            }
            return (.polygon(vertices: verts, closed: true), endSnap)

        case .parabola:
            let halfW = max(16, abs(resolvedEnd.x - start.x))
            let height = max(16, abs(resolvedEnd.y - start.y))
            let axisAngle: CGFloat = (resolvedEnd.y >= start.y) ? CGFloat.pi / 2 : -CGFloat.pi / 2
            return (.parabola(vertex: start, axisAngle: axisAngle, halfWidth: halfW, height: height), endSnap)

        case .axes:
            let minX = min(start.x, resolvedEnd.x), maxX = max(start.x, resolvedEnd.x)
            let minY = min(start.y, resolvedEnd.y), maxY = max(start.y, resolvedEnd.y)
            let halfW = max(44, (maxX - minX) / 2)
            let halfH = max(44, (maxY - minY) / 2)
            let origin = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            return (.axes(origin: origin, xMin: -halfW, xMax: halfW, yMin: -halfH, yMax: halfH, tickSpacing: 28), endSnap)
        }
    }
}

// MARK: - Selected Shape Edit Overlay Model (iPad-Only)

struct SelectedShapeOverlay: Equatable {
    enum ActionButton: Equatable {
        case cycleLineStyle
        case toggleFillOrCenter
        case duplicate
        case delete
    }

    enum HitZone: Equatable {
        case none
        case handle(Int)
        case action(ActionButton)
        case body
    }

    var strokeID: UUID
    /// Control handle coordinates in view space.
    var handles: [CGPoint]
    /// Bounding box of the selected shape in view space.
    var boundingBox: CGRect
    var lineStyle: StrokeLineStyle
    var supportsFill: Bool
    var isFilled: Bool
    var isCircularWithCenterMark: Bool
    var showsCenterMark: Bool

    var hasSecondToggle: Bool { supportsFill || isCircularWithCenterMark }

    func actionBarFrame(in bounds: CGRect) -> CGRect {
        let count: CGFloat = hasSecondToggle ? 4 : 3
        let w = count * 56
        let h: CGFloat = 34
        let x = min(max(12, boundingBox.midX - w / 2), max(12, bounds.width - w - 12))
        let aboveY = boundingBox.minY - h - 18
        let belowY = boundingBox.maxY + 18
        let y: CGFloat
        if aboveY >= 10 {
            y = aboveY
        } else if belowY + h <= bounds.height - 12 {
            y = belowY
        } else {
            y = 12
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func actionButtons(in bounds: CGRect) -> [(ActionButton, CGRect)] {
        let bar = actionBarFrame(in: bounds)
        let actions: [ActionButton] = hasSecondToggle
            ? [.cycleLineStyle, .toggleFillOrCenter, .duplicate, .delete]
            : [.cycleLineStyle, .duplicate, .delete]
        let segW = bar.width / CGFloat(actions.count)
        return actions.enumerated().map { idx, action in
            (action, CGRect(x: bar.minX + CGFloat(idx) * segW, y: bar.minY, width: segW, height: bar.height))
        }
    }

    func hitTest(_ point: CGPoint, in bounds: CGRect, bodyHit: Bool) -> HitZone {
        for (action, rect) in actionButtons(in: bounds) {
            if rect.insetBy(dx: -2, dy: -4).contains(point) {
                return .action(action)
            }
        }
        var bestIndex: Int?
        var bestDist: CGFloat = 22
        for (i, h) in handles.enumerated() {
            let d = hypot(point.x - h.x, point.y - h.y)
            if d < bestDist {
                bestDist = d
                bestIndex = i
            }
        }
        if let bestIndex {
            return .handle(bestIndex)
        }
        if bodyHit {
            return .body
        }
        return .none
    }
}
