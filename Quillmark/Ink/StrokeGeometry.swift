import CoreGraphics
import Foundation

/// A processed point on the stroke centerline with its half-width.
struct StrokeSample: Codable, Equatable {
    var point: CGPoint
    var radius: CGFloat
}

/// Width response of each pen to pressure and speed.
enum PenModel {
    /// Maps Apple Pencil force to 0...1. Normal handwriting lands around 0.4–0.7.
    static func normalizedForce(raw: CGFloat, maximum: CGFloat, isStylus: Bool) -> Float {
        guard isStylus, maximum > 0 else { return 0.5 }
        let r = Float(max(0, min(1, raw / maximum)))
        return min(1, powf(min(1, r * 2), 0.8))
    }

    /// Multiplier applied to the nominal width. `speed` is in page points per second.
    static func widthFactor(pen: PenKind, force: Float, speed: Float) -> Float {
        let f = max(0, min(1, force))
        let v = max(0, min(1, speed / 1500))
        switch pen {
        case .ballpoint:
            return 0.85 + 0.3 * f
        case .fountain:
            return (0.35 + 1.15 * powf(f, 0.9)) * (1 - 0.3 * v)
        case .brush:
            return (0.12 + 2.1 * powf(f, 1.4)) * (1 - 0.45 * v)
        }
    }
}

/// Turns raw input points into a stabilized, variable-width centerline.
enum StrokeProcessor {
    static let minimumSpacing: CGFloat = 0.25
    static let minimumRadius: CGFloat = 0.12

    static func samples(for points: [InkPoint], pen: PenKind, width: Float, smoothing: Float, finished: Bool,
                        highlighter: Bool = false) -> [StrokeSample] {
        guard let first = points.first else { return [] }
        let follow = CGFloat(1 - max(0, min(0.95, smoothing)) * 0.85)
        let base = CGFloat(width) / 2

        func targetRadius(_ p: InkPoint, speed: Float) -> CGFloat {
            // A highlighter has a felt chisel: constant width, no pressure or speed response.
            if highlighter { return max(minimumRadius, base) }
            return max(minimumRadius, base * CGFloat(PenModel.widthFactor(pen: pen, force: p.force, speed: speed)))
        }

        var result = [StrokeSample(point: first.location, radius: targetRadius(first, speed: 0))]
        result.reserveCapacity(points.count + 1)
        var smoothed = first.location
        var radius = result[0].radius
        var previousRaw = first
        var speed: Float = 0

        for raw in points.dropFirst() {
            let dt = max(0.001, raw.t - previousRaw.t)
            let distance = Float(hypot(CGFloat(raw.x - previousRaw.x), CGFloat(raw.y - previousRaw.y)))
            speed = speed * 0.6 + (distance / dt) * 0.4
            previousRaw = raw

            let target = raw.location
            let next = CGPoint(x: smoothed.x + (target.x - smoothed.x) * follow,
                               y: smoothed.y + (target.y - smoothed.y) * follow)
            radius += (targetRadius(raw, speed: speed) - radius) * 0.35
            guard hypot(next.x - smoothed.x, next.y - smoothed.y) >= minimumSpacing else { continue }
            smoothed = next
            result.append(StrokeSample(point: smoothed, radius: radius))
        }

        // Pull the tail to the real pen position so the stroke never lags behind the nib.
        if points.count > 1, let last = points.last {
            let end = last.location
            if hypot(end.x - smoothed.x, end.y - smoothed.y) >= minimumSpacing {
                result.append(StrokeSample(point: end, radius: radius))
            } else if result.count > 1 {
                result[result.count - 1].point = end
            }
        }

        if !highlighter {
            applyTaper(&result, pen: pen, finished: finished)
        }
        return result
    }

    /// Replaces a freehand stroke by a straight segment from its first to its last point
    /// (highlighter / tape straight-line mode). Optionally snaps near-horizontal/vertical lines.
    static func straightened(_ points: [InkPoint], spacing: Float = 2, snapAngleDegrees: Float = 0) -> [InkPoint] {
        guard let first = points.first, var last = points.last, points.count > 1 else { return points }
        if snapAngleDegrees > 0 {
            let dx = last.x - first.x
            let dy = last.y - first.y
            let length = hypotf(dx, dy)
            if length > 1 {
                let angle = atan2f(dy, dx)
                let snapStep = Float.pi / 2 // 0°, 90°, 180°, -90°
                let nearest = (angle / snapStep).rounded() * snapStep
                let threshold = snapAngleDegrees * Float.pi / 180
                if abs(angle - nearest) <= threshold {
                    last.x = first.x + cosf(nearest) * length
                    last.y = first.y + sinf(nearest) * length
                }
            }
        }
        let length = hypotf(last.x - first.x, last.y - first.y)
        let steps = max(1, Int(length / spacing))
        return (0...steps).map { i in
            let f = Float(i) / Float(steps)
            return InkPoint(x: first.x + (last.x - first.x) * f,
                            y: first.y + (last.y - first.y) * f,
                            force: first.force + (last.force - first.force) * f,
                            azimuth: first.azimuth, altitude: first.altitude,
                            t: first.t + (last.t - first.t) * f)
        }
    }

    /// Inserts interpolated samples so neighbours are at most `maxSpacing` apart.
    /// Preserves subpath breaks (`radius <= 0`).
    static func densified(_ samples: [StrokeSample], maxSpacing: CGFloat) -> [StrokeSample] {
        guard samples.count > 1, maxSpacing > 0 else { return samples }
        var result: [StrokeSample] = [samples[0]]
        result.reserveCapacity(samples.count * 2)
        for i in 1..<samples.count {
            let a = samples[i - 1]
            let b = samples[i]
            if a.radius <= 0 || b.radius <= 0 {
                result.append(b)
                continue
            }
            let distance = hypot(b.point.x - a.point.x, b.point.y - a.point.y)
            let extra = Int(distance / maxSpacing)
            if extra > 0 {
                for k in 1...extra {
                    let f = CGFloat(k) / CGFloat(extra + 1)
                    result.append(StrokeSample(point: CGPoint(x: a.point.x + (b.point.x - a.point.x) * f,
                                                              y: a.point.y + (b.point.y - a.point.y) * f),
                                               radius: a.radius + (b.radius - a.radius) * f))
                }
            }
            result.append(b)
        }
        return result
    }

    private static func applyTaper(_ samples: inout [StrokeSample], pen: PenKind, finished: Bool) {
        guard pen != .ballpoint, samples.count >= 4 else { return }
        let start: [CGFloat] = [0.45, 0.7, 0.88]
        for (i, f) in start.enumerated() where i < samples.count {
            samples[i].radius = max(minimumRadius, samples[i].radius * f)
        }
        guard finished, pen == .brush else { return }
        let end: [CGFloat] = [0.35, 0.6, 0.85]
        for (i, f) in end.enumerated() {
            let j = samples.count - 1 - i
            if j >= start.count {
                samples[j].radius = max(minimumRadius, samples[j].radius * f)
            }
        }
    }
}

/// Builds a filled outline (two offset curves joined by round caps) from stroke samples.
/// Supports solid, dashed, and dotted styles as pure filled paths so they render identically
/// in CoreGraphics, SVG, and external display overlays.
enum StrokeOutline {
    static let capSegments = 8
    /// Sentinel sample inserted between disconnected parts of a composite shape (e.g. an arrow shaft and head).
    static let breakSample = StrokeSample(point: .zero, radius: 0)

    static func path(for samples: [StrokeSample],
                     lineStyle: StrokeLineStyle = .solid,
                     transform: CGAffineTransform = .identity) -> CGPath {
        let result = CGMutablePath()
        let runs = splitSubpaths(samples)
        for run in runs {
            switch lineStyle {
            case .solid:
                appendSolid(run, to: result, transform: transform)
            case .dashed:
                appendDashed(run, to: result, transform: transform)
            case .dotted:
                appendDotted(run, to: result, transform: transform)
            }
        }
        return result
    }

    private static func splitSubpaths(_ samples: [StrokeSample]) -> [[StrokeSample]] {
        var runs: [[StrokeSample]] = []
        var current: [StrokeSample] = []
        for s in samples {
            if s.radius <= 0 {
                if !current.isEmpty {
                    runs.append(current)
                    current = []
                }
            } else {
                current.append(s)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func appendDashed(_ samples: [StrokeSample], to path: CGMutablePath, transform: CGAffineTransform) {
        guard let first = samples.first else { return }
        if samples.count == 1 {
            appendSolid(samples, to: path, transform: transform)
            return
        }
        let avgDiameter = max(1.2, (samples.map(\.radius).reduce(0, +) / CGFloat(samples.count)) * 2)
        let dashLength = max(7.0, avgDiameter * 3.2)
        let gapLength = max(5.0, avgDiameter * 2.4)
        let period = dashLength + gapLength

        let dense = StrokeProcessor.densified(samples, maxSpacing: 1.0)
        var distance: CGFloat = 0
        var segment: [StrokeSample] = [first]
        var drawing = true

        for i in 1..<dense.count {
            let prev = dense[i - 1]
            let curr = dense[i]
            distance += hypot(curr.point.x - prev.point.x, curr.point.y - prev.point.y)
            let phase = distance.truncatingRemainder(dividingBy: period)
            let shouldDraw = phase <= dashLength
            if shouldDraw {
                if !drawing {
                    segment = [curr]
                    drawing = true
                } else {
                    segment.append(curr)
                }
            } else if drawing {
                if !segment.isEmpty {
                    appendSolid(segment, to: path, transform: transform)
                    segment.removeAll(keepingCapacity: true)
                }
                drawing = false
            }
        }
        if drawing, !segment.isEmpty {
            appendSolid(segment, to: path, transform: transform)
        }
    }

    private static func appendDotted(_ samples: [StrokeSample], to path: CGMutablePath, transform: CGAffineTransform) {
        guard let first = samples.first else { return }
        let avgDiameter = max(1.2, (samples.map(\.radius).reduce(0, +) / CGFloat(samples.count)) * 2)
        let spacing = max(4.5, avgDiameter * 2.3)

        func addDot(_ sample: StrokeSample) {
            let r = max(sample.radius, 0.85)
            path.addEllipse(in: CGRect(x: sample.point.x - r, y: sample.point.y - r, width: 2 * r, height: 2 * r),
                            transform: transform)
        }

        addDot(first)
        guard samples.count > 1 else { return }
        let dense = StrokeProcessor.densified(samples, maxSpacing: 1.0)
        var sinceLastDot: CGFloat = 0
        for i in 1..<dense.count {
            let prev = dense[i - 1]
            let curr = dense[i]
            sinceLastDot += hypot(curr.point.x - prev.point.x, curr.point.y - prev.point.y)
            if sinceLastDot >= spacing {
                addDot(curr)
                sinceLastDot = 0
            }
        }
    }

    private static func appendSolid(_ samples: [StrokeSample], to path: CGMutablePath, transform: CGAffineTransform) {
        guard let first = samples.first else { return }
        if samples.count == 1 {
            let r = first.radius
            path.addEllipse(in: CGRect(x: first.point.x - r, y: first.point.y - r, width: 2 * r, height: 2 * r),
                            transform: transform)
            return
        }

        let n = samples.count
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        var tangents: [CGVector] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        tangents.reserveCapacity(n)

        for i in 0..<n {
            let a = samples[max(0, i - 1)].point
            let b = samples[min(n - 1, i + 1)].point
            var dx = b.x - a.x
            var dy = b.y - a.y
            let length = hypot(dx, dy)
            if length < 1e-6 {
                dx = 1
                dy = 0
            } else {
                dx /= length
                dy /= length
            }
            tangents.append(CGVector(dx: dx, dy: dy))
            let s = samples[i]
            left.append(CGPoint(x: s.point.x - dy * s.radius, y: s.point.y + dx * s.radius))
            right.append(CGPoint(x: s.point.x + dy * s.radius, y: s.point.y - dx * s.radius))
        }

        let endTangent = tangents[n - 1]
        let startTangent = tangents[0]

        path.move(to: left[0], transform: transform)
        addSmoothCurve(path, through: left, transform: transform)
        addCap(path, center: samples[n - 1].point, radius: samples[n - 1].radius,
               normal: CGVector(dx: -endTangent.dy, dy: endTangent.dx),
               direction: endTangent, transform: transform)
        addSmoothCurve(path, through: Array(right.reversed()), transform: transform)
        addCap(path, center: samples[0].point, radius: samples[0].radius,
               normal: CGVector(dx: startTangent.dy, dy: -startTangent.dx),
               direction: CGVector(dx: -startTangent.dx, dy: -startTangent.dy), transform: transform)
        path.closeSubpath()
    }

    private static func addSmoothCurve(_ path: CGMutablePath, through points: [CGPoint], transform: CGAffineTransform) {
        guard points.count > 1 else { return }
        path.addLine(to: points[0], transform: transform)
        if points.count == 2 {
            path.addLine(to: points[1], transform: transform)
            return
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i], transform: transform)
        }
        path.addLine(to: points[points.count - 1], transform: transform)
    }

    /// Half circle from `center + normal*r` around `direction` to `center - normal*r`.
    private static func addCap(_ path: CGMutablePath, center: CGPoint, radius: CGFloat,
                               normal: CGVector, direction: CGVector, transform: CGAffineTransform) {
        for k in 1...capSegments {
            let theta = CGFloat.pi * CGFloat(k) / CGFloat(capSegments)
            let c = cos(theta)
            let s = sin(theta)
            let p = CGPoint(x: center.x + (normal.dx * c + direction.dx * s) * radius,
                            y: center.y + (normal.dy * c + direction.dy * s) * radius)
            path.addLine(to: p, transform: transform)
        }
    }
}

extension InkStroke {
    /// Centerline used for rendering and hit testing.
    func renderSamples(finished: Bool = true) -> [StrokeSample] {
        if let baked { return baked }
        if let geometry { return geometry.samples(radius: CGFloat(width) / 2) }
        return StrokeProcessor.samples(for: points, pen: pen, width: width, smoothing: smoothing,
                                       finished: finished, highlighter: isHighlighter || isTape)
    }

    func outlinePath(transform: CGAffineTransform = .identity, finished: Bool = true) -> CGPath {
        StrokeOutline.path(for: renderSamples(finished: finished),
                           lineStyle: resolvedLineStyle,
                           transform: transform)
    }
}
