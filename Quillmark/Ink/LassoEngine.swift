import CoreGraphics
import Foundation

/// Pure geometry engine for the one-handed Lasso tool (`套索`):
/// freeform loop enclosure selection, single-stroke tap hit-testing, bounding-box aggregation,
/// and uniform scale/translation across handwritten, eraser-baked, and parametric geometric strokes.
enum LassoEngine {
    /// Standard even-odd ray-casting test for whether `point` lies inside a closed polygon.
    static func pointInPolygon(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        let count = polygon.count
        guard count >= 3 else { return false }
        var inside = false
        var j = count - 1
        for i in 0..<count {
            let a = polygon[i]
            let b = polygon[j]
            let crossesY = (a.y > point.y) != (b.y > point.y)
            if crossesY {
                let intersectX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < intersectX {
                    inside.toggle()
                }
            }
            j = i
        }
        return inside
    }

    /// Returns the IDs of all visible strokes enclosed (at least 35% of centerline samples inside)
    /// by the closed freeform lasso `polygon` in document coordinates.
    static func selectStrokeIDs(from strokes: [InkStroke],
                                origins: [UUID: CGPoint],
                                polygon: [CGPoint],
                                cache: StrokeGeometryCache) -> [UUID] {
        guard polygon.count >= 3 else { return [] }
        let polyBox = boundingBox(of: polygon)
        guard !polyBox.isNull, polyBox.width >= 4 || polyBox.height >= 4 else { return [] }

        var selected: [UUID] = []
        for stroke in strokes {
            guard let origin = visibleOrigin(for: stroke, in: origins) else { continue }
            let docBounds = cache.bounds(for: stroke).offsetBy(dx: origin.x, dy: origin.y)
            guard !docBounds.isNull, docBounds.intersects(polyBox) else { continue }

            let samples = cache.samples(for: stroke).filter { $0.radius > 0 }
            guard !samples.isEmpty else { continue }
            var insideCount = 0
            for s in samples {
                let pt = CGPoint(x: s.point.x + origin.x, y: s.point.y + origin.y)
                if pointInPolygon(pt, polygon: polygon) {
                    insideCount += 1
                }
            }
            let needed = max(1, Int(ceil(Double(samples.count) * 0.35)))
            if insideCount >= needed {
                selected.append(stroke.id)
            }
        }
        return selected
    }

    /// Hit-tests the topmost visible stroke under a single tap in document coordinates.
    static func hitTestSingleStroke(from strokes: [InkStroke],
                                    origins: [UUID: CGPoint],
                                    at docPoint: CGPoint,
                                    tolerance: CGFloat = 14,
                                    cache: StrokeGeometryCache) -> UUID? {
        for stroke in strokes.reversed() {
            guard let origin = visibleOrigin(for: stroke, in: origins) else { continue }
            if let geom = stroke.geometry {
                if geom.translated(by: origin).hitTestBody(docPoint, tolerance: tolerance) {
                    return stroke.id
                }
                continue
            }
            let docBounds = cache.bounds(for: stroke).offsetBy(dx: origin.x, dy: origin.y)
            guard !docBounds.isNull, docBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(docPoint) else {
                continue
            }
            let localPt = CGPoint(x: docPoint.x - origin.x, y: docPoint.y - origin.y)
            let samples = cache.samples(for: stroke)
            var prev: StrokeSample?
            for s in samples {
                if s.radius <= 0 {
                    prev = nil
                    continue
                }
                if let p = prev {
                    if EraserEngine.distance(from: localPt, toSegment: p.point, s.point) <= tolerance + max(p.radius, s.radius) {
                        return stroke.id
                    }
                } else if hypot(localPt.x - s.point.x, localPt.y - s.point.y) <= tolerance + s.radius {
                    return stroke.id
                }
                prev = s
            }
        }
        return nil
    }

    /// Union bounding box in document coordinates for a set of visible strokes.
    static func documentBounds(of strokes: [InkStroke],
                               origins: [UUID: CGPoint],
                               cache: StrokeGeometryCache) -> CGRect {
        var box = CGRect.null
        for stroke in strokes {
            guard let origin = visibleOrigin(for: stroke, in: origins) else { continue }
            let sb = cache.bounds(for: stroke)
            if !sb.isNull {
                box = box.union(sb.offsetBy(dx: origin.x, dy: origin.y))
            }
            if let geom = stroke.geometry {
                let gb = geom.translated(by: origin).boundingBox()
                if !gb.isNull {
                    box = box.union(gb)
                }
            }
        }
        return box
    }

    /// Transforms a document-space stroke by uniform `scale` around `pivot`, then `translation`.
    static func transformStroke(_ stroke: InkStroke,
                                scale: CGFloat,
                                around pivot: CGPoint,
                                translation: CGPoint) -> InkStroke {
        let s = max(0.1, scale)
        let isPureTranslate = abs(s - 1) < 1e-4
        if isPureTranslate {
            return stroke.translated(by: translation)
        }

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: pivot.x + (p.x - pivot.x) * s + translation.x,
                    y: pivot.y + (p.y - pivot.y) * s + translation.y)
        }

        var copy = stroke
        copy.width = max(0.6, min(60, stroke.width * Float(s)))
        if !stroke.points.isEmpty {
            copy.points = stroke.points.map { p in
                var q = p
                let mapped = map(p.location)
                q.x = Float(mapped.x)
                q.y = Float(mapped.y)
                return q
            }
        }
        if let baked = stroke.baked {
            copy.baked = baked.map { sample in
                guard sample.radius > 0 else { return sample }
                return StrokeSample(point: map(sample.point),
                                    radius: max(StrokeProcessor.minimumRadius, sample.radius * s))
            }
        }
        if let geom = stroke.geometry {
            copy.geometry = geom.scaled(by: s, around: pivot).translated(by: translation)
        }
        return copy
    }

    private static func visibleOrigin(for stroke: InkStroke, in origins: [UUID: CGPoint]) -> CGPoint? {
        if let origin = origins[stroke.id] { return origin }
        return stroke.anchor == nil ? .zero : nil
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - iPad-Only Lasso Selection Overlay Model

/// View-space geometry and hit-testing for the active Lasso selection box, 4 corner scale handles,
/// and floating quick-action bar (6 ink colors + Duplicate + Delete). Never projected to students.
struct LassoSelectionOverlay: Equatable {
    enum ScaleCorner: Int, CaseIterable, Equatable {
        case topLeft = 0
        case topRight = 1
        case bottomRight = 2
        case bottomLeft = 3
    }

    enum ActionButton: Equatable {
        case color(Int)
        case duplicate
        case delete
    }

    enum HitZone: Equatable {
        case none
        case handle(ScaleCorner)
        case action(ActionButton)
        case body
    }

    static let barWidth: CGFloat = 294
    static let barHeight: CGFloat = 38
    static let boxPadding: CGFloat = 8

    var strokeIDs: [UUID]
    /// Selection bounding box in view coordinates (tight around strokes; visual frame adds `boxPadding`).
    var boundingBox: CGRect
    /// Shared color of the selection if every selected stroke has the same color, else `nil`.
    var activeColor: RGBAColor?

    var paddedBox: CGRect {
        boundingBox.insetBy(dx: -Self.boxPadding, dy: -Self.boxPadding)
    }

    func handlePositions() -> [(ScaleCorner, CGPoint)] {
        let r = paddedBox
        return [
            (.topLeft, CGPoint(x: r.minX, y: r.minY)),
            (.topRight, CGPoint(x: r.maxX, y: r.minY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
        ]
    }

    func oppositeCorner(of corner: ScaleCorner, in box: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: box.maxX, y: box.maxY)
        case .topRight: return CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight: return CGPoint(x: box.minX, y: box.minY)
        case .bottomLeft: return CGPoint(x: box.maxX, y: box.minY)
        }
    }

    func cornerPoint(of corner: ScaleCorner, in box: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: return CGPoint(x: box.minX, y: box.minY)
        case .topRight: return CGPoint(x: box.maxX, y: box.minY)
        case .bottomRight: return CGPoint(x: box.maxX, y: box.maxY)
        case .bottomLeft: return CGPoint(x: box.minX, y: box.maxY)
        }
    }

    func actionBarFrame(in bounds: CGRect) -> CGRect {
        let w = min(Self.barWidth, max(180, bounds.width - 24))
        let h = Self.barHeight
        let r = paddedBox
        let x = min(max(12, r.midX - w / 2), max(12, bounds.width - w - 12))
        let aboveY = r.minY - h - 18
        let belowY = r.maxY + 18
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
        let colorCount = ToolSettings.palette.count
        let textAreaW: CGFloat = 104 // 52pt 复制 + 52pt 删除
        let colorStartX = bar.minX + 8
        let colorAreaW = max(60, bar.width - textAreaW - 14)
        let swatchW = colorAreaW / CGFloat(max(1, colorCount))

        var out: [(ActionButton, CGRect)] = []
        for i in 0..<colorCount {
            let rect = CGRect(x: colorStartX + CGFloat(i) * swatchW, y: bar.minY, width: swatchW, height: bar.height)
            out.append((.color(i), rect))
        }
        let dupX = bar.maxX - textAreaW
        out.append((.duplicate, CGRect(x: dupX, y: bar.minY, width: 52, height: bar.height)))
        out.append((.delete, CGRect(x: dupX + 52, y: bar.minY, width: 52, height: bar.height)))
        return out
    }

    func hitTest(_ point: CGPoint, in bounds: CGRect, includeActionBar: Bool = true) -> HitZone {
        if includeActionBar {
            for (action, rect) in actionButtons(in: bounds) {
                if rect.insetBy(dx: -1, dy: -4).contains(point) {
                    return .action(action)
                }
            }
        }
        var bestCorner: ScaleCorner?
        var bestDist: CGFloat = 24
        for (corner, pt) in handlePositions() {
            let d = hypot(point.x - pt.x, point.y - pt.y)
            if d < bestDist {
                bestDist = d
                bestCorner = corner
            }
        }
        if let bestCorner {
            return .handle(bestCorner)
        }
        if paddedBox.insetBy(dx: -8, dy: -8).contains(point) {
            return .body
        }
        return .none
    }
}
