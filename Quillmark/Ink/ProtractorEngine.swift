import CoreGraphics
import Foundation

// MARK: - Smart Auto-Measuring Protractor (One-Handed Apple Pencil & Finger Operable)

struct ProtractorState: Equatable {
    enum HitZone: Equatable {
        case none
        case center
        case ray1Handle
        case ray2Handle
        case ringRotate
        case autoDetectButton
        case cycleAngleButton
        case stampAngleButton
        case closeButton
    }

    enum DetectionSource: Equatable {
        case vector
        case image
    }

    struct Sweep: Equatable {
        var startAngle: CGFloat
        var endAngle: CGFloat
        var clockwise: Bool
        /// Unsigned angular span in radians (`0...2π`).
        var magnitudeRadians: CGFloat

        var signedDelta: CGFloat {
            clockwise ? magnitudeRadians : -magnitudeRadians
        }

        var bisectorAngle: CGFloat {
            startAngle + signedDelta / 2
        }

        var degrees: CGFloat {
            magnitudeRadians * 180 / .pi
        }
    }

    static let defaultRadius: CGFloat = 132
    static let barSize = CGSize(width: 224, height: 34)
    static let closeButtonWidth: CGFloat = 36

    var center: CGPoint = .zero
    var radius: CGFloat = ProtractorState.defaultRadius
    /// Primary (blue) reference ray angle in UIKit screen radians.
    var ray1Angle: CGFloat = 0
    /// Secondary (orange) measuring ray angle in UIKit screen radians.
    var ray2Angle: CGFloat = -.pi / 3
    /// When `false` (default), measures the interior angle (`0°...180°`); when `true`, measures reflex (`180°...360°`).
    var measureReflex: Bool = false
    /// Sorted ray angles in `[0, 2π)` discovered by automatic vertex/edge detection.
    var detectedRayAngles: [CGFloat] = []
    /// Active adjacent sector index within `detectedRayAngles` (when `count >= 3`).
    var activeRayPairIndex: Int = 0
    /// How the current ray alignment was obtained (`nil` when positioned manually).
    var autoDetectedSource: DetectionSource?

    var ray1HandleCenter: CGPoint {
        CGPoint(x: center.x + radius * cos(ray1Angle), y: center.y + radius * sin(ray1Angle))
    }

    var ray2HandleCenter: CGPoint {
        CGPoint(x: center.x + radius * cos(ray2Angle), y: center.y + radius * sin(ray2Angle))
    }

    /// Active measured sweep from `ray1Angle` to `ray2Angle` respecting `measureReflex`.
    var sweep: Sweep {
        let cwDelta = Self.normalizedPositive(ray2Angle - ray1Angle)
        let minorIsClockwise = cwDelta <= .pi
        let clockwise = measureReflex ? !minorIsClockwise : minorIsClockwise
        let magnitude: CGFloat
        if clockwise {
            magnitude = cwDelta
        } else {
            magnitude = (cwDelta < 1e-6) ? 0 : (2 * .pi - cwDelta)
        }
        return Sweep(startAngle: ray1Angle, endAngle: ray2Angle, clockwise: clockwise, magnitudeRadians: magnitude)
    }

    /// Measured angle in degrees (`0.0...360.0`).
    var measuredDegrees: CGFloat {
        sweep.degrees
    }

    /// `true` when the measured angle is within `0.45°` of a 90° right angle.
    var isRightAngle: Bool {
        abs(measuredDegrees - 90) <= 0.45
    }

    /// Crisp human-readable degree string (shows integer when within `0.05°`, else 1 decimal place).
    var formattedDegrees: String {
        let deg = measuredDegrees
        let rounded = deg.rounded()
        if abs(deg - rounded) < 0.05 {
            let intDeg = Int(rounded)
            return isRightAngle ? "\(intDeg)° 直角" : "\(intDeg)°"
        }
        return String(format: "%.1f°", Double(deg))
    }

    /// Position of the compact action bar (clamped inside `bounds`, never overlapping the protractor dial).
    func actionBarFrame(in bounds: CGRect) -> CGRect {
        let w = Self.barSize.width
        let h = Self.barSize.height
        let x = min(max(12, center.x - w / 2), max(12, bounds.width - w - 12))
        let preferredTop = center.y - radius - h - 22
        let y: CGFloat
        if preferredTop >= 10 {
            y = preferredTop
        } else {
            let below = center.y + radius + 22
            if below + h <= bounds.height - 12 {
                y = below
            } else {
                y = min(max(10, center.y - h - 42), max(10, bounds.height - h - 12))
            }
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func buttonFrames(in bounds: CGRect) -> (autoDetect: CGRect, cycleAngle: CGRect, stampAngle: CGRect, close: CGRect) {
        let bar = actionBarFrame(in: bounds)
        let closeW = Self.closeButtonWidth
        let segW = (bar.width - closeW) / 3
        return (
            autoDetect: CGRect(x: bar.minX, y: bar.minY, width: segW, height: bar.height),
            cycleAngle: CGRect(x: bar.minX + segW, y: bar.minY, width: segW, height: bar.height),
            stampAngle: CGRect(x: bar.minX + 2 * segW, y: bar.minY, width: segW, height: bar.height),
            close: CGRect(x: bar.minX + 3 * segW, y: bar.minY, width: closeW, height: bar.height)
        )
    }

    func hitTest(_ point: CGPoint, in bounds: CGRect) -> HitZone {
        let buttons = buttonFrames(in: bounds)
        if buttons.autoDetect.insetBy(dx: -2, dy: -4).contains(point) { return .autoDetectButton }
        if buttons.cycleAngle.insetBy(dx: -2, dy: -4).contains(point) { return .cycleAngleButton }
        if buttons.stampAngle.insetBy(dx: -2, dy: -4).contains(point) { return .stampAngleButton }
        if buttons.close.insetBy(dx: -2, dy: -4).contains(point) { return .closeButton }

        // Ray handles have priority so close rays stay easy to grab independently.
        let r1 = ray1HandleCenter
        let r2 = ray2HandleCenter
        let d1 = hypot(point.x - r1.x, point.y - r1.y)
        let d2 = hypot(point.x - r2.x, point.y - r2.y)
        if min(d1, d2) <= 24 {
            return d1 <= d2 ? .ray1Handle : .ray2Handle
        }

        // Center vertex handle O
        let distFromCenter = hypot(point.x - center.x, point.y - center.y)
        if distFromCenter <= 26 {
            return .center
        }

        // Outer dial ring allows rotating both arms together (copy/compare angles).
        if abs(distFromCenter - radius) <= 20 {
            return .ringRotate
        }
        return .none
    }

    @discardableResult
    mutating func moveCenter(to rawCenter: CGPoint, snapPoints: [SnapPoint], threshold: CGFloat = 14) -> SnapPoint? {
        if let snap = GeometrySnapEngine.nearestPoint(to: rawCenter, in: snapPoints, threshold: threshold) {
            center = snap.point
            return snap
        }
        center = rawCenter
        return nil
    }

    @discardableResult
    mutating func aimRay1(to rawPoint: CGPoint, snapPoints: [SnapPoint], threshold: CGFloat = 12) -> SnapPoint? {
        let (angle, snap) = aimedAngle(to: rawPoint, snapPoints: snapPoints, threshold: threshold)
        guard let angle else { return snap }
        ray1Angle = angle
        autoDetectedSource = nil
        detectedRayAngles = []
        return snap
    }

    @discardableResult
    mutating func aimRay2(to rawPoint: CGPoint, snapPoints: [SnapPoint], threshold: CGFloat = 12) -> SnapPoint? {
        let (angle, snap) = aimedAngle(to: rawPoint, snapPoints: snapPoints, threshold: threshold)
        guard let angle else { return snap }
        ray2Angle = angle
        autoDetectedSource = nil
        detectedRayAngles = []
        return snap
    }

    mutating func rotateBoth(by deltaRadians: CGFloat) {
        ray1Angle = Self.normalizedSigned(ray1Angle + deltaRadians)
        ray2Angle = Self.normalizedSigned(ray2Angle + deltaRadians)
        autoDetectedSource = nil
        detectedRayAngles = []
    }

    /// Applies an ordered list of automatically detected ray angles (radians) emanating from `center`.
    /// Returns `true` if at least 2 distinct rays were available and applied.
    @discardableResult
    mutating func applyDetectedRays(_ rawAngles: [CGFloat], source: DetectionSource) -> Bool {
        let cleaned = ProtractorAngleDetector.deduplicateSortedAngles(rawAngles, minSeparationDegrees: 6)
        guard cleaned.count >= 2 else { return false }

        detectedRayAngles = cleaned
        autoDetectedSource = source

        if cleaned.count == 2 {
            activeRayPairIndex = 0
            ray1Angle = Self.normalizedSigned(cleaned[0])
            ray2Angle = Self.normalizedSigned(cleaned[1])
            measureReflex = false
            return true
        }

        // For 3+ rays (e.g. T-junction / X-crossing / triangle with altitude), choose the
        // cleanest acute/obtuse adjacent sector (< 175°) first instead of a 180° straight line.
        var bestIdx = 0
        var bestSpan = CGFloat.greatestFiniteMagnitude
        for i in 0..<cleaned.count {
            let a = cleaned[i]
            let b = cleaned[(i + 1) % cleaned.count]
            let span = Self.normalizedPositive(b - a)
            if span < (.pi - 0.08), span < bestSpan {
                bestSpan = span
                bestIdx = i
            }
        }
        activeRayPairIndex = bestIdx
        let a = cleaned[bestIdx]
        let b = cleaned[(bestIdx + 1) % cleaned.count]
        let span = Self.normalizedPositive(b - a)
        ray1Angle = Self.normalizedSigned(a)
        ray2Angle = Self.normalizedSigned(b)
        measureReflex = span > .pi + 1e-4
        return true
    }

    /// Cycles to the next adjacent detected angle when `>= 3` rays meet at `center`,
    /// otherwise toggles between interior (`≤ 180°`) and reflex (`≥ 180°`) measurement.
    mutating func cycleAngle() {
        if detectedRayAngles.count >= 3 {
            activeRayPairIndex = (activeRayPairIndex + 1) % detectedRayAngles.count
            let a = detectedRayAngles[activeRayPairIndex]
            let b = detectedRayAngles[(activeRayPairIndex + 1) % detectedRayAngles.count]
            let span = Self.normalizedPositive(b - a)
            ray1Angle = Self.normalizedSigned(a)
            ray2Angle = Self.normalizedSigned(b)
            measureReflex = span > .pi + 1e-4
        } else {
            measureReflex.toggle()
        }
    }

    /// Produces a crisp permanent vector angle mark (right-angle `∟` for 90°, otherwise an arc)
    /// in document/page coordinates centered at `docCenter` with size `docRadius`.
    func stampPrimitive(center docCenter: CGPoint, radius docRadius: CGFloat) -> GeometricPrimitive? {
        let activeSweep = sweep
        guard activeSweep.magnitudeRadians >= 2 * .pi / 180 else { return nil }
        let r = max(12, docRadius)
        if isRightAngle {
            let side = r * 0.72
            let u1 = CGPoint(x: cos(ray1Angle), y: sin(ray1Angle))
            let u2 = CGPoint(x: cos(ray2Angle), y: sin(ray2Angle))
            let p1 = CGPoint(x: docCenter.x + side * u1.x, y: docCenter.y + side * u1.y)
            let pCorner = CGPoint(x: docCenter.x + side * (u1.x + u2.x), y: docCenter.y + side * (u1.y + u2.y))
            let p2 = CGPoint(x: docCenter.x + side * u2.x, y: docCenter.y + side * u2.y)
            return .polygon(vertices: [p1, pCorner, p2], closed: false)
        }
        return .arc(
            center: docCenter,
            radius: r,
            startAngle: activeSweep.startAngle,
            endAngle: activeSweep.endAngle,
            clockwise: activeSweep.clockwise,
            showCenterMark: false
        )
    }

    private func aimedAngle(to rawPoint: CGPoint, snapPoints: [SnapPoint], threshold: CGFloat) -> (CGFloat?, SnapPoint?) {
        let snap = GeometrySnapEngine.nearestPoint(
            to: rawPoint,
            in: snapPoints,
            threshold: threshold,
            excluding: center,
            excludeRadius: 12
        )
        let target = snap?.point ?? rawPoint
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard hypot(dx, dy) > 6 else { return (nil, snap) }
        return (atan2(dy, dx), snap)
    }

    static func normalizedPositive(_ angle: CGFloat) -> CGFloat {
        let twoPi = 2 * CGFloat.pi
        var a = angle.truncatingRemainder(dividingBy: twoPi)
        if a < 0 { a += twoPi }
        return a
    }

    static func normalizedSigned(_ angle: CGFloat) -> CGFloat {
        atan2(sin(angle), cos(angle))
    }
}

// MARK: - Automatic Vector & Image Angle Detector

/// Automatically finds geometric rays emanating from a protractor vertex — first with zero-error
/// analytic inspection of drawn Quillmark strokes, and second via fast radial contrast scanning of
/// printed PDF exam diagrams or live HTML courseware bitmaps.
enum ProtractorAngleDetector {
    struct ImageRayDetectionResult: Equatable {
        /// Optional micro-refinement offset from the sampled patch center onto the printed vertex (in patch pixels).
        var vertexOffset: CGPoint
        /// Sorted ray angles in `[0, 2π)` (UIKit screen radians).
        var rayAngles: [CGFloat]
    }

    // MARK: 1. Analytic Vector Ray Detection (0.0° Error)

    /// Finds all rays emanating from `vertex` across parametric shapes and straight hand-drawn strokes.
    static func detectVectorRays(at vertex: CGPoint,
                                 from strokes: [InkStroke],
                                 origins: [UUID: CGPoint] = [:],
                                 tolerance: CGFloat = 14) -> [CGFloat] {
        var rays: [CGFloat] = []
        let minRayLen: CGFloat = 14

        func emitSegment(a: CGPoint, b: CGPoint) {
            let abx = b.x - a.x
            let aby = b.y - a.y
            let len = hypot(abx, aby)
            guard len >= minRayLen else { return }

            let da = hypot(vertex.x - a.x, vertex.y - a.y)
            let db = hypot(vertex.x - b.x, vertex.y - b.y)
            if da <= tolerance {
                rays.append(atan2(b.y - a.y, b.x - a.x))
                return
            }
            if db <= tolerance {
                rays.append(atan2(a.y - b.y, a.x - b.x))
                return
            }

            // Check if `vertex` sits on the interior of the segment (e.g. a crossing intersection).
            let lenSq = len * len
            let t = ((vertex.x - a.x) * abx + (vertex.y - a.y) * aby) / lenSq
            guard t > 0 && t < 1 else { return }
            let projX = a.x + t * abx
            let projY = a.y + t * aby
            guard hypot(vertex.x - projX, vertex.y - projY) <= tolerance else { return }
            if t * len >= minRayLen {
                rays.append(atan2(a.y - projY, a.x - projX))
            }
            if (1 - t) * len >= minRayLen {
                rays.append(atan2(b.y - projY, b.x - projX))
            }
        }

        for stroke in strokes where !stroke.isTape && !stroke.isHighlighter {
            let origin = origins[stroke.id] ?? .zero
            if let rawGeom = stroke.geometry {
                let geom = (origin == .zero) ? rawGeom : rawGeom.translated(by: origin)
                switch geom {
                case let .segment(a, b, _, _):
                    emitSegment(a: a, b: b)
                case let .polygon(vertices, closed):
                    guard vertices.count >= 2 else { break }
                    let edgeCount = closed ? vertices.count : vertices.count - 1
                    for i in 0..<edgeCount {
                        emitSegment(a: vertices[i], b: vertices[(i + 1) % vertices.count])
                    }
                case let .axes(o, xMin, xMax, yMin, yMax, _):
                    emitSegment(a: CGPoint(x: o.x + xMin, y: o.y), b: CGPoint(x: o.x + xMax, y: o.y))
                    emitSegment(a: CGPoint(x: o.x, y: o.y + yMin), b: CGPoint(x: o.x, y: o.y + yMax))
                case .circle, .arc, .ellipse, .parabola:
                    break
                }
                continue
            }

            // Freehand / baked strokes: detect locally straight rays departing from `vertex`.
            let pts: [CGPoint]
            if let baked = stroke.baked, !baked.isEmpty {
                pts = baked.filter { $0.radius > 0 }.map {
                    CGPoint(x: $0.point.x + origin.x, y: $0.point.y + origin.y)
                }
            } else {
                pts = stroke.points.map {
                    CGPoint(x: CGFloat($0.x) + origin.x, y: CGFloat($0.y) + origin.y)
                }
            }
            guard pts.count >= 2 else { continue }
            var bestIndex: Int?
            var bestDist = tolerance
            for (i, p) in pts.enumerated() {
                let d = hypot(p.x - vertex.x, p.y - vertex.y)
                if d <= bestDist {
                    bestDist = d
                    bestIndex = i
                }
            }
            guard let pivot = bestIndex else { continue }

            // Walk forward and backward along the polyline to estimate straight outgoing tangents.
            for step in [-1, 1] {
                if let angle = estimateLocalRayAngle(points: pts, fromIndex: pivot, step: step,
                                                     minReach: 18, maxReach: 72) {
                    rays.append(angle)
                }
            }
        }

        return deduplicateSortedAngles(rays, minSeparationDegrees: 5)
    }

    private static func estimateLocalRayAngle(points: [CGPoint],
                                              fromIndex: Int,
                                              step: Int,
                                              minReach: CGFloat,
                                              maxReach: CGFloat) -> CGFloat? {
        let origin = points[fromIndex]
        var idx = fromIndex + step
        var chosen: CGPoint?
        var collected: [CGPoint] = []
        while idx >= 0 && idx < points.count {
            let p = points[idx]
            let d = hypot(p.x - origin.x, p.y - origin.y)
            collected.append(p)
            if d >= minReach {
                chosen = p
                if d >= maxReach { break }
            }
            idx += step
        }
        guard let end = chosen else { return nil }
        let dx = end.x - origin.x
        let dy = end.y - origin.y
        let chord = hypot(dx, dy)
        guard chord >= minReach else { return nil }

        // Reject wildly curved scribbles: require intermediate points to stay reasonably close to the chord.
        var maxDeviation: CGFloat = 0
        for p in collected {
            let cross = abs((p.x - origin.x) * dy - (p.y - origin.y) * dx) / chord
            if cross > maxDeviation { maxDeviation = cross }
        }
        guard maxDeviation <= max(6, chord * 0.14) else { return nil }
        return atan2(dy, dx)
    }

    // MARK: 2. Printed PDF & HTML Local Bitmap Radial Ray Detection

    /// Scans a local raster patch centered near `center` (in pixel coordinates of `cgImage`) for
    /// straight printed/rendered lines radiating outward from the vertex. Works on both light PDFs
    /// and dark-theme HTML courseware, filters out nearby printed letters, and refines vertex position.
    static func detectImageRays(in cgImage: CGImage, center: CGPoint) -> ImageRayDetectionResult? {
        let width = cgImage.width
        let height = cgImage.height
        guard width >= 48, height >= 48 else { return nil }

        // Render into a compact 8-bit grayscale buffer (1 byte per pixel).
        var luma = [UInt8](repeating: 255, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let rendered: Bool = luma.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress,
                  let ctx = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        return detectImageRays(grayscale: luma, width: width, height: height, center: center)
    }

    static func detectImageRays(grayscale luma: [UInt8],
                                width: Int,
                                height: Int,
                                center: CGPoint) -> ImageRayDetectionResult? {
        guard width >= 48, height >= 48, luma.count == width * height else { return nil }
        let cx = min(max(12, Int(center.x.rounded())), width - 13)
        let cy = min(max(12, Int(center.y.rounded())), height - 13)

        // 1. Estimate local background luminance via histogram median so both light PDFs and dark HTML work.
        var hist = [Int](repeating: 0, count: 256)
        let total = width * height
        for v in luma { hist[Int(v)] += 1 }
        var acc = 0
        var bgLuma = 255
        for level in 0..<256 {
            acc += hist[level]
            if acc * 2 >= total {
                bgLuma = level
                break
            }
        }

        // 2. Build unsigned contrast map `|luma - bgLuma|`.
        var contrast = [UInt8](repeating: 0, count: total)
        var maxContrast: UInt8 = 0
        for i in 0..<total {
            let diff = abs(Int(luma[i]) - bgLuma)
            let c = UInt8(min(255, diff))
            contrast[i] = c
            if c > maxContrast { maxContrast = c }
        }
        guard maxContrast >= 40 else { return nil }
        let noiseFloor = UInt8(max(28, Int(Double(maxContrast) * 0.28)))

        // 3. Two-stage vertex micro-refinement within ±8px (2px coarse -> 1px fine) onto the true corner.
        let maxR = CGFloat(min(62, min(min(cx, width - 1 - cx), min(cy, height - 1 - cy)) - 2))
        guard maxR >= 26 else { return nil }

        let coarseSteps = 120 // every 3°
        let fineSteps = 180   // every 2°
        let originScore = coarseVertexScore(contrast: contrast, width: width, height: height,
                                            cx: CGFloat(cx), cy: CGFloat(cy),
                                            maxR: maxR, noiseFloor: noiseFloor, steps: fineSteps)

        var bestCenterX = CGFloat(cx)
        var bestCenterY = CGFloat(cy)
        var bestCoarseScore = coarseVertexScore(contrast: contrast, width: width, height: height,
                                                cx: CGFloat(cx), cy: CGFloat(cy),
                                                maxR: maxR, noiseFloor: noiseFloor, steps: coarseSteps)

        let searchRadius = 8
        for dy in stride(from: -searchRadius, through: searchRadius, by: 2) {
            for dx in stride(from: -searchRadius, through: searchRadius, by: 2) {
                if dx == 0 && dy == 0 { continue }
                if dx * dx + dy * dy > searchRadius * searchRadius + 2 { continue }
                let px = cx + dx
                let py = cy + dy
                guard px >= 12, px < width - 12, py >= 12, py < height - 12 else { continue }
                if !hasInkNear(contrast: contrast, width: width, x: px, y: py, floor: noiseFloor) {
                    continue
                }
                let localMaxR = CGFloat(min(62, min(min(px, width - 1 - px), min(py, height - 1 - py)) - 2))
                guard localMaxR >= 26 else { continue }
                let score = coarseVertexScore(contrast: contrast, width: width, height: height,
                                              cx: CGFloat(px), cy: CGFloat(py),
                                              maxR: localMaxR, noiseFloor: noiseFloor, steps: coarseSteps)
                if score > bestCoarseScore {
                    bestCoarseScore = score
                    bestCenterX = CGFloat(px)
                    bestCenterY = CGFloat(py)
                }
            }
        }

        // Fine 1px local pass around the coarse winner to pin the exact corner pixel.
        let seedX = Int(bestCenterX)
        let seedY = Int(bestCenterY)
        var bestFineScore = coarseVertexScore(contrast: contrast, width: width, height: height,
                                              cx: bestCenterX, cy: bestCenterY,
                                              maxR: maxR, noiseFloor: noiseFloor, steps: fineSteps)
        for dy in -2...2 {
            for dx in -2...2 {
                let px = seedX + dx
                let py = seedY + dy
                guard px >= 12, px < width - 12, py >= 12, py < height - 12 else { continue }
                let distFromDropSq = (px - cx) * (px - cx) + (py - cy) * (py - cy)
                guard distFromDropSq <= (searchRadius + 1) * (searchRadius + 1) else { continue }
                if !hasInkNear(contrast: contrast, width: width, x: px, y: py, floor: noiseFloor) {
                    continue
                }
                let localMaxR = CGFloat(min(62, min(min(px, width - 1 - px), min(py, height - 1 - py)) - 2))
                guard localMaxR >= 26 else { continue }
                let score = coarseVertexScore(contrast: contrast, width: width, height: height,
                                              cx: CGFloat(px), cy: CGFloat(py),
                                              maxR: localMaxR, noiseFloor: noiseFloor, steps: fineSteps)
                if score > bestFineScore {
                    bestFineScore = score
                    bestCenterX = CGFloat(px)
                    bestCenterY = CGFloat(py)
                }
            }
        }

        // Only move the user's vertex if the refined corner is sharper than the drop point.
        if bestFineScore <= originScore * 1.05 {
            bestCenterX = CGFloat(cx)
            bestCenterY = CGFloat(cy)
        }

        // 4. Fine 0.5° radial scan (720 bins) with continuity filtering (rejects nearby letters/labels).
        let finalMaxR = CGFloat(min(62, min(min(Int(bestCenterX), width - 1 - Int(bestCenterX)),
                                            min(Int(bestCenterY), height - 1 - Int(bestCenterY))) - 2))
        guard finalMaxR >= 24 else { return nil }

        let binCount = 720 // 0.5° per bin
        var scores = [Double](repeating: 0, count: binCount)
        let rStart: CGFloat = 7
        let rStep: CGFloat = 1.5
        let sampleCount = max(12, Int((finalMaxR - rStart) / rStep))
        let halfSample = sampleCount / 2

        for bin in 0..<binCount {
            let theta = CGFloat(bin) * (2 * .pi) / CGFloat(binCount)
            let cosT = cos(theta)
            let sinT = sin(theta)
            let perpX = -sinT
            let perpY = cosT

            var hitCount = 0
            var innerHits = 0
            var outerHits = 0
            var weightedSum = 0.0
            var gapRun = 0
            var maxContiguous = 0
            var currentRun = 0

            for s in 0..<sampleCount {
                let r = rStart + CGFloat(s) * rStep
                let bx = bestCenterX + r * cosT
                let by = bestCenterY + r * sinT
                let peakC = maxPerpendicularContrast(contrast: contrast, width: width, height: height,
                                                     bx: bx, by: by, perpX: perpX, perpY: perpY)
                if peakC >= noiseFloor {
                    hitCount += 1
                    if s < halfSample { innerHits += 1 } else { outerHits += 1 }
                    currentRun += 1
                    gapRun = 0
                    if currentRun > maxContiguous { maxContiguous = currentRun }
                    weightedSum += Double(min(peakC, 190))
                } else {
                    gapRun += 1
                    // Allow short gaps (e.g. dashed auxiliary lines), break long gaps.
                    if gapRun > 4 {
                        currentRun = 0
                    }
                }
            }

            let coverage = Double(hitCount) / Double(sampleCount)
            let contiguousFrac = Double(maxContiguous) / Double(sampleCount)
            // Real geometric edges radiate continuously through both inner and outer rings;
            // nearby text labels ("A", "60°") only hit a short cluster and get filtered out.
            if coverage >= 0.42, contiguousFrac >= 0.30, innerHits >= 3, outerHits >= 3 {
                scores[bin] = weightedSum * coverage
            }
        }

        // 5. Circular smoothing + Non-Maximum Suppression + parabolic sub-degree refinement.
        var smooth = [Double](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let prev = scores[(i - 1 + binCount) % binCount]
            let curr = scores[i]
            let next = scores[(i + 1) % binCount]
            smooth[i] = 0.25 * prev + 0.5 * curr + 0.25 * next
        }

        guard let globalMax = smooth.max(), globalMax > 300 else { return nil }
        let peakThreshold = max(300.0, globalMax * 0.36)

        var candidates: [(bin: Int, score: Double)] = []
        for i in 0..<binCount {
            let v = smooth[i]
            guard v >= peakThreshold else { continue }
            let prev = smooth[(i - 1 + binCount) % binCount]
            let next = smooth[(i + 1) % binCount]
            if v >= prev && v >= next && (v > prev || v > next) {
                candidates.append((i, v))
            }
        }
        candidates.sort { $0.score > $1.score }

        let minSeparationBins = 22 // 11° suppression radius
        var accepted: [(angle: CGFloat, score: Double)] = []
        for cand in candidates {
            let tooClose = accepted.contains { existing in
                let existingBin = Int((existing.angle / (2 * .pi) * CGFloat(binCount)).rounded()) % binCount
                let diff = abs(cand.bin - existingBin)
                let circ = min(diff, binCount - diff)
                return circ < minSeparationBins
            }
            if tooClose { continue }

            // Parabolic sub-bin interpolation across (bin-1, bin, bin+1)
            let y0 = smooth[(cand.bin - 1 + binCount) % binCount]
            let y1 = smooth[cand.bin]
            let y2 = smooth[(cand.bin + 1) % binCount]
            let denom = (y0 - 2 * y1 + y2)
            let shift = abs(denom) > 1e-6 ? max(-0.5, min(0.5, 0.5 * (y0 - y2) / denom)) : 0
            let refinedBin = (Double(cand.bin) + shift).truncatingRemainder(dividingBy: Double(binCount))
            let positiveBin = refinedBin < 0 ? refinedBin + Double(binCount) : refinedBin
            let angle = CGFloat(positiveBin) * (2 * .pi) / CGFloat(binCount)
            accepted.append((angle, cand.score))
            if accepted.count >= 6 { break }
        }

        let sortedAngles = deduplicateSortedAngles(accepted.map(\.angle), minSeparationDegrees: 10)
        guard sortedAngles.count >= 2 else { return nil }

        let offset = CGPoint(x: bestCenterX - center.x, y: bestCenterY - center.y)
        return ImageRayDetectionResult(vertexOffset: offset, rayAngles: sortedAngles)
    }

    private static func hasInkNear(contrast: [UInt8], width: Int, x: Int, y: Int, floor: UInt8) -> Bool {
        for dy in -1...1 {
            let row = (y + dy) * width
            for dx in -1...1 {
                if contrast[row + x + dx] >= floor { return true }
            }
        }
        return false
    }

    private static func maxPerpendicularContrast(contrast: [UInt8],
                                                 width: Int,
                                                 height: Int,
                                                 bx: CGFloat,
                                                 by: CGFloat,
                                                 perpX: CGFloat,
                                                 perpY: CGFloat) -> UInt8 {
        var best: UInt8 = 0
        for d in [-1.5, 0.0, 1.5] as [CGFloat] {
            let ix = Int((bx + perpX * d).rounded())
            let iy = Int((by + perpY * d).rounded())
            if ix >= 0, ix < width, iy >= 0, iy < height {
                let c = contrast[iy * width + ix]
                if c > best { best = c }
            }
        }
        return best
    }

    private static func coarseVertexScore(contrast: [UInt8],
                                          width: Int,
                                          height: Int,
                                          cx: CGFloat,
                                          cy: CGFloat,
                                          maxR: CGFloat,
                                          noiseFloor: UInt8,
                                          steps: Int) -> Double {
        var top1 = 0.0
        var top1Bin = -1
        var top2 = 0.0
        let rStart: CGFloat = 3
        let rSamples = 18
        let rStep = (maxR - rStart) / CGFloat(max(1, rSamples - 1))

        var binScores = [Double](repeating: 0, count: steps)
        for bin in 0..<steps {
            let theta = CGFloat(bin) * (2 * .pi) / CGFloat(steps)
            let cosT = cos(theta)
            let sinT = sin(theta)
            var hits = 0
            var innerHits = 0
            var sum = 0.0
            for s in 0..<rSamples {
                let r = rStart + CGFloat(s) * rStep
                let ix = Int((cx + r * cosT).rounded())
                let iy = Int((cy + r * sinT).rounded())
                if ix >= 0, ix < width, iy >= 0, iy < height {
                    let c = contrast[iy * width + ix]
                    if c >= noiseFloor {
                        hits += 1
                        let weight = (s < 5) ? 1.35 : 1.0
                        if s < 5 { innerHits += 1 }
                        sum += Double(min(c, 190)) * weight
                    }
                }
            }
            if hits >= 7 && innerHits >= 3 {
                let score = sum * (Double(hits) / Double(rSamples))
                binScores[bin] = score
                if score > top1 {
                    top1 = score
                    top1Bin = bin
                }
            }
        }

        guard top1Bin >= 0 else { return 0 }
        let minBinSep = max(4, steps / 24) // >= 15° apart
        for bin in 0..<steps {
            let diff = abs(bin - top1Bin)
            let circ = min(diff, steps - diff)
            if circ >= minBinSep && binScores[bin] > top2 {
                top2 = binScores[bin]
            }
        }
        guard top2 > 0 else { return 0 }
        return top1 + top2
    }

    /// Normalizes angles to `[0, 2π)`, sorts ascending, and merges duplicates closer than `minSeparationDegrees`.
    static func deduplicateSortedAngles(_ angles: [CGFloat], minSeparationDegrees: CGFloat) -> [CGFloat] {
        guard !angles.isEmpty else { return [] }
        let minSep = minSeparationDegrees * .pi / 180
        let sorted = angles.map { ProtractorState.normalizedPositive($0) }.sorted()
        var merged: [CGFloat] = []
        for a in sorted {
            if let last = merged.last, abs(a - last) < minSep {
                continue
            }
            merged.append(a)
        }
        // Handle wrap-around near 0 / 2π
        if merged.count >= 2, let first = merged.first, let last = merged.last {
            if (2 * .pi - last + first) < minSep {
                merged.removeLast()
            }
        }
        return merged
    }
}
