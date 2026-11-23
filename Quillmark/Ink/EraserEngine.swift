import CoreGraphics
import Foundation

/// Caches stroke centerlines, bounds, and max radius for O(1) hit-testing during erasing and lasso.
final class StrokeGeometryCache {
    private struct Entry {
        let pointCount: Int
        let bakedCount: Int
        let width: Float
        let firstPoint: CGPoint?
        let lastPoint: CGPoint?
        let geometry: GeometricPrimitive?
        let samples: [StrokeSample]
        let bounds: CGRect
        let maxRadius: CGFloat
    }

    private var entries: [UUID: Entry] = [:]

    private func entry(for stroke: InkStroke) -> Entry {
        let firstPt = stroke.baked?.first?.point ?? stroke.points.first?.location
        let lastPt = stroke.baked?.last?.point ?? stroke.points.last?.location
        if let cached = entries[stroke.id],
           cached.pointCount == stroke.points.count,
           cached.bakedCount == (stroke.baked?.count ?? -1),
           cached.width == stroke.width,
           cached.firstPoint == firstPt,
           cached.lastPoint == lastPt,
           cached.geometry == stroke.geometry {
            return cached
        }
        let samples = stroke.renderSamples()
        let (bounds, maxRadius) = Self.computeBounds(for: samples)
        let created = Entry(pointCount: stroke.points.count, bakedCount: stroke.baked?.count ?? -1,
                            width: stroke.width, firstPoint: firstPt, lastPoint: lastPt,
                            geometry: stroke.geometry, samples: samples, bounds: bounds, maxRadius: maxRadius)
        entries[stroke.id] = created
        return created
    }

    /// Pre-populates the cache for a freshly split pixel-eraser fragment so subsequent 240Hz samples
    /// hit the cache immediately without scanning `samples` again.
    func store(_ stroke: InkStroke, samples: [StrokeSample]) {
        let (bounds, maxRadius) = Self.computeBounds(for: samples)
        let firstPt = stroke.baked?.first?.point ?? stroke.points.first?.location
        let lastPt = stroke.baked?.last?.point ?? stroke.points.last?.location
        entries[stroke.id] = Entry(
            pointCount: stroke.points.count,
            bakedCount: stroke.baked?.count ?? -1,
            width: stroke.width,
            firstPoint: firstPt,
            lastPoint: lastPt,
            geometry: stroke.geometry,
            samples: samples,
            bounds: bounds,
            maxRadius: maxRadius
        )
    }

    func evict(id: UUID) {
        entries.removeValue(forKey: id)
    }

    /// Prunes stale entries when cache grows large across long erasing sessions.
    func prune(keeping activeIDs: Set<UUID>) {
        guard entries.count > activeIDs.count + 64 else { return }
        entries = entries.filter { activeIDs.contains($0.key) }
    }

    func samples(for stroke: InkStroke) -> [StrokeSample] { entry(for: stroke).samples }
    func bounds(for stroke: InkStroke) -> CGRect { entry(for: stroke).bounds }
    func maxRadius(for stroke: InkStroke) -> CGFloat { entry(for: stroke).maxRadius }

    func removeAll() { entries.removeAll() }

    private static func computeBounds(for samples: [StrokeSample]) -> (CGRect, CGFloat) {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var maxR: CGFloat = 0
        var hasValid = false
        for s in samples where s.radius > 0 {
            hasValid = true
            let r = s.radius
            if r > maxR { maxR = r }
            if s.point.x - r < minX { minX = s.point.x - r }
            if s.point.y - r < minY { minY = s.point.y - r }
            if s.point.x + r > maxX { maxX = s.point.x + r }
            if s.point.y + r > maxY { maxY = s.point.y + r }
        }
        guard hasValid else { return (.null, 0) }
        return (CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), maxR)
    }
}

/// Pure erase operations on a page's strokes. The eraser is a disc swept from `a` to `b`.
enum EraserEngine {
    struct Result {
        var strokes: [InkStroke]
        var changed: Bool
    }

    /// Local subdivision spacing strictly along segments intersecting the eraser sweep.
    static let fragmentSpacing: CGFloat = 1.0

    static func erase(_ strokes: [InkStroke], from a: CGPoint, to b: CGPoint, radius: CGFloat,
                      mode: EraserMode, highlighterOnly: Bool, cache: StrokeGeometryCache) -> Result {
        let sweep = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -radius, dy: -radius)
        var output: [InkStroke] = []
        output.reserveCapacity(strokes.count)
        var changed = false

        for stroke in strokes {
            guard !highlighterOnly || stroke.isHighlighter,
                  cache.bounds(for: stroke).intersects(sweep) else {
                output.append(stroke)
                continue
            }
            let samples = cache.samples(for: stroke)
            let maxStrokeR = cache.maxRadius(for: stroke)
            switch mode {
            case .stroke:
                if hitsStroke(samples: samples, maxStrokeRadius: maxStrokeR, a: a, b: b, radius: radius) {
                    changed = true
                    cache.evict(id: stroke.id)
                } else {
                    output.append(stroke)
                }
            case .pixel:
                if let pieces = split(stroke, samples: samples, maxStrokeRadius: maxStrokeR,
                                      a: a, b: b, radius: radius, cache: cache) {
                    changed = true
                    cache.evict(id: stroke.id)
                    output.append(contentsOf: pieces)
                } else {
                    output.append(stroke)
                }
            }
        }
        return Result(strokes: output, changed: changed)
    }

    /// Zero-allocation hit test using segment-to-segment squared distance + local AABB rejection.
    private static func hitsStroke(samples: [StrokeSample],
                                   maxStrokeRadius: CGFloat,
                                   a: CGPoint,
                                   b: CGPoint,
                                   radius: CGFloat) -> Bool {
        let pad = radius + maxStrokeRadius
        let minX = min(a.x, b.x) - pad
        let maxX = max(a.x, b.x) + pad
        let minY = min(a.y, b.y) - pad
        let maxY = max(a.y, b.y) + pad

        var prev: StrokeSample?
        for s in samples {
            if s.radius <= 0 {
                prev = nil
                continue
            }
            if let p = prev {
                if !(max(p.point.x, s.point.x) < minX || min(p.point.x, s.point.x) > maxX ||
                     max(p.point.y, s.point.y) < minY || min(p.point.y, s.point.y) > maxY) {
                    let cut = radius + max(p.radius, s.radius)
                    if segmentToSegmentDistanceSquared(p.point, s.point, a, b) <= cut * cut {
                        return true
                    }
                }
            } else {
                if s.point.x >= minX && s.point.x <= maxX && s.point.y >= minY && s.point.y <= maxY {
                    let cut = radius + s.radius
                    if distanceSquared(from: s.point, toSegment: a, b) <= cut * cut {
                        return true
                    }
                }
            }
            prev = s
        }
        return false
    }

    /// Locally clips `stroke` against the swept eraser disc without globally densifying untouched
    /// sections, keeping surviving fragments compact and 120fps-friendly. Returns `nil` on miss.
    private static func split(_ stroke: InkStroke,
                              samples: [StrokeSample],
                              maxStrokeRadius: CGFloat,
                              a: CGPoint,
                              b: CGPoint,
                              radius: CGFloat,
                              cache: StrokeGeometryCache) -> [InkStroke]? {
        guard !samples.isEmpty else { return nil }

        let pad = radius + maxStrokeRadius * 0.6 + fragmentSpacing
        let minX = min(a.x, b.x) - pad
        let maxX = max(a.x, b.x) + pad
        let minY = min(a.y, b.y) - pad
        let maxY = max(a.y, b.y) + pad

        // 1. Fast zero-allocation pre-check: bail immediately if no segment is within erase distance.
        var candidateHit = false
        var prevCheck: StrokeSample?
        for s in samples {
            if s.radius <= 0 {
                prevCheck = nil
                continue
            }
            if let p = prevCheck {
                if !(max(p.point.x, s.point.x) < minX || min(p.point.x, s.point.x) > maxX ||
                     max(p.point.y, s.point.y) < minY || min(p.point.y, s.point.y) > maxY) {
                    let cut = radius + max(p.radius, s.radius) * 0.6
                    if segmentToSegmentDistanceSquared(p.point, s.point, a, b) <= cut * cut {
                        candidateHit = true
                        break
                    }
                }
            } else if s.point.x >= minX && s.point.x <= maxX && s.point.y >= minY && s.point.y <= maxY {
                let cut = radius + s.radius * 0.6
                if distanceSquared(from: s.point, toSegment: a, b) <= cut * cut {
                    candidateHit = true
                    break
                }
            }
            prevCheck = s
        }
        guard candidateHit else { return nil }

        // 2. Local-only subdivision: untouched segments keep their original compact vertices;
        //    only segments intersecting the eraser sweep are stepped at `fragmentSpacing` and
        //    collinear surviving spans are collapsed to their exact entry/exit points.
        @inline(__always)
        func isErased(_ sample: StrokeSample) -> Bool {
            let cut = radius + sample.radius * 0.6
            return distanceSquared(from: sample.point, toSegment: a, b) <= cut * cut
        }

        @inline(__always)
        func appendUnique(_ sample: StrokeSample, to run: inout [StrokeSample]) {
            if let last = run.last {
                let dx = sample.point.x - last.point.x
                let dy = sample.point.y - last.point.y
                if dx * dx + dy * dy <= 1e-4 && abs(sample.radius - last.radius) <= 1e-3 {
                    return
                }
            }
            run.append(sample)
        }

        var runs: [[StrokeSample]] = []
        var current: [StrokeSample] = []
        var hit = false
        var prev: StrokeSample?

        for s in samples {
            if s.radius <= 0 {
                if !current.isEmpty {
                    runs.append(current)
                    current = []
                }
                prev = nil
                continue
            }

            guard let p0 = prev else {
                // Start of a subpath.
                if isErased(s) {
                    hit = true
                } else {
                    current.append(s)
                }
                prev = s
                continue
            }

            // Fast path: entire segment lies strictly outside the expanded eraser sweep AABB.
            if max(p0.point.x, s.point.x) < minX || min(p0.point.x, s.point.x) > maxX ||
               max(p0.point.y, s.point.y) < minY || min(p0.point.y, s.point.y) > maxY {
                appendUnique(s, to: &current)
                prev = s
                continue
            }

            // Local path: subdivide this intersecting segment at `fragmentSpacing`.
            let dx = s.point.x - p0.point.x
            let dy = s.point.y - p0.point.y
            let segLen = hypot(dx, dy)
            let steps = max(1, Int(ceil(segLen / fragmentSpacing)))
            let invSteps = 1.0 / CGFloat(steps)
            let dr = s.radius - p0.radius

            var pendingEnd: StrokeSample?
            for k in 1...steps {
                let f = CGFloat(k) * invSteps
                let sample = StrokeSample(
                    point: CGPoint(x: p0.point.x + dx * f, y: p0.point.y + dy * f),
                    radius: p0.radius + dr * f
                )
                if isErased(sample) {
                    hit = true
                    if let end = pendingEnd {
                        appendUnique(end, to: &current)
                        pendingEnd = nil
                    }
                    if !current.isEmpty {
                        runs.append(current)
                        current = []
                    }
                } else {
                    if current.isEmpty {
                        appendUnique(sample, to: &current)
                    }
                    pendingEnd = sample
                }
            }
            if let end = pendingEnd {
                appendUnique(end, to: &current)
            }
            prev = s
        }

        guard hit else { return nil }
        if !current.isEmpty { runs.append(current) }

        return runs
            .filter { $0.count >= 2 || ($0.first?.radius ?? 0) > 0.6 }
            .map { run in
                var piece = stroke
                piece.id = UUID()
                piece.points = []
                piece.baked = run
                piece.geometry = nil
                piece.fillColor = nil
                cache.store(piece, samples: run)
                return piece
            }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        sqrt(distanceSquared(from: p, toSegment: a, b))
    }

    @inline(__always)
    static func distanceSquared(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else {
            let ex = p.x - a.x
            let ey = p.y - a.y
            return ex * ex + ey * ey
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        let cx = p.x - (a.x + t * dx)
        let cy = p.y - (a.y + t * dy)
        return cx * cx + cy * cy
    }

    /// Exact squared distance between two 2D line segments `p0-p1` and `a-b` (zero `sqrt`).
    static func segmentToSegmentDistanceSquared(_ p0: CGPoint, _ p1: CGPoint,
                                                _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        if segmentsIntersect(p0, p1, a, b) {
            return 0
        }
        let d1 = distanceSquared(from: p0, toSegment: a, b)
        let d2 = distanceSquared(from: p1, toSegment: a, b)
        let d3 = distanceSquared(from: a, toSegment: p0, p1)
        let d4 = distanceSquared(from: b, toSegment: p0, p1)
        return min(min(d1, d2), min(d3, d4))
    }

    private static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint,
                                          _ q1: CGPoint, _ q2: CGPoint) -> Bool {
        @inline(__always)
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        let d1 = cross(q1, q2, p1)
        let d2 = cross(q1, q2, p2)
        let d3 = cross(p1, p2, q1)
        let d4 = cross(p1, p2, q2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
           ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) {
            return true
        }
        return false
    }
}
