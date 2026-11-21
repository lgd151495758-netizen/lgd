import CoreGraphics
import Foundation

// MARK: - Parametric Geometric Primitives

enum ArrowHeadStyle: String, Codable, Equatable {
    case none
    case open
}

/// Parametric geometric shape stored alongside an `InkStroke` so lines, circles, arcs and
/// polygons retain exact mathematical semantics (for snapping, intersections, and crisp rendering).
enum GeometricPrimitive: Codable, Equatable {
    case segment(a: CGPoint, b: CGPoint, startArrow: ArrowHeadStyle = .none, endArrow: ArrowHeadStyle = .none)
    case circle(center: CGPoint, radius: CGFloat, showCenterMark: Bool = true)
    case arc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat,
             clockwise: Bool, showCenterMark: Bool = true)
    case ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, rotation: CGFloat)
    case polygon(vertices: [CGPoint], closed: Bool = true)

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
        }
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

    /// Collects snap points in document CSS coordinates from all visible geometric strokes.
    static func snapPoints(from strokes: [InkStroke], origins: [UUID: CGPoint]) -> [SnapPoint] {
        var primitives: [GeometricPrimitive] = []
        for stroke in strokes {
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
