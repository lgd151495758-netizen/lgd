import CoreGraphics
import Foundation

/// Caches stroke centerlines and bounds for hit testing (keyed by stroke identity and geometry signature).
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
        var bounds = CGRect.null
        for s in samples where s.radius > 0 {
            bounds = bounds.union(CGRect(x: s.point.x - s.radius, y: s.point.y - s.radius,
                                         width: 2 * s.radius, height: 2 * s.radius))
        }
        let created = Entry(pointCount: stroke.points.count, bakedCount: stroke.baked?.count ?? -1,
                            width: stroke.width, firstPoint: firstPt, lastPoint: lastPt,
                            geometry: stroke.geometry, samples: samples, bounds: bounds)
        entries[stroke.id] = created
        return created
    }

    func samples(for stroke: InkStroke) -> [StrokeSample] { entry(for: stroke).samples }
    func bounds(for stroke: InkStroke) -> CGRect { entry(for: stroke).bounds }

    func removeAll() { entries.removeAll() }
}

/// Pure erase operations on a page's strokes. The eraser is a disc swept from `a` to `b`.
enum EraserEngine {
    struct Result {
        var strokes: [InkStroke]
        var changed: Bool
    }

    /// Precise-eraser pieces are resampled to this spacing so a gap is never wider than the eraser.
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
            switch mode {
            case .stroke:
                let hit = cache.samples(for: stroke).contains { sample in
                    sample.radius > 0 && distance(from: sample.point, toSegment: a, b) <= radius + sample.radius
                }
                if hit {
                    changed = true
                } else {
                    output.append(stroke)
                }
            case .pixel:
                if let pieces = split(stroke, samples: cache.samples(for: stroke), a: a, b: b, radius: radius) {
                    changed = true
                    output.append(contentsOf: pieces)
                } else {
                    output.append(stroke)
                }
            }
        }
        return Result(strokes: output, changed: changed)
    }

    /// Returns the parts of `stroke` outside the eraser, or `nil` when the eraser misses it.
    private static func split(_ stroke: InkStroke, samples: [StrokeSample], a: CGPoint, b: CGPoint,
                              radius: CGFloat) -> [InkStroke]? {
        let dense = StrokeProcessor.densified(samples, maxSpacing: fragmentSpacing)
        var runs: [[StrokeSample]] = []
        var current: [StrokeSample] = []
        var hit = false
        for sample in dense {
            if sample.radius <= 0 {
                if !current.isEmpty {
                    runs.append(current)
                    current = []
                }
                continue
            }
            if distance(from: sample.point, toSegment: a, b) <= radius + sample.radius * 0.6 {
                hit = true
                if !current.isEmpty {
                    runs.append(current)
                    current = []
                }
            } else {
                current.append(sample)
            }
        }
        guard hit else { return nil }
        if !current.isEmpty { runs.append(current) }

        return runs
            .filter { $0.count >= 2 || ($0.first?.radius ?? 0) > 0.6 }
            .map { run in
                // Keep every attribute (colour, tool, web anchor…) of the original stroke.
                var piece = stroke
                piece.id = UUID()
                piece.points = []
                piece.baked = run
                piece.geometry = nil
                piece.fillColor = nil
                return piece
            }
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
