import UIKit

/// Transparent ink layer laid over one PDF page.
/// Committed strokes are vector `CAShapeLayer`s (they stay sharp when the page is zoomed).
/// Highlighter strokes live in a container below pen ink and use a multiply blend, so printed
/// text stays dark underneath. The stroke being drawn lives in `liveLayer`.
final class PageInkView: UIView, InkInputDelegate {
    let pageIndex: Int
    let pageSize: CGSize
    private weak var session: DocumentSession?

    static let highlighterOpacity: Float = 0.6

    private let inkRecognizer = InkGestureRecognizer(target: nil, action: nil)
    private let highlightContainer = CALayer()
    private let inkContainer = CALayer()
    private let liveLayer = CAShapeLayer()
    private let eraserCursor = CAShapeLayer()
    private var strokeLayers: [UUID: CAShapeLayer] = [:]
    private var renderedStrokes: [UUID: InkStroke] = [:]
    private var lastLayoutSize: CGSize = .zero
    private let geometryCache = StrokeGeometryCache()

    // Drawing state
    private var livePoints: [InkPoint] = []
    private var liveTool = ToolSettings()
    private var liveStartTime: TimeInterval = 0
    /// estimationUpdateIndex -> index into the stroke's points, for force values that arrive later.
    private var pendingEstimates: [NSNumber: Int] = [:]
    private var lastCommitted: (id: UUID, points: [InkPoint])?

    // Erasing state
    private var eraseOriginal: [InkStroke]?
    private var eraseWorking: [InkStroke] = []
    private var lastErasePoint: CGPoint?

    init(pageIndex: Int, pageSize: CGSize, session: DocumentSession) {
        self.pageIndex = pageIndex
        self.pageSize = pageSize
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false

        layer.addSublayer(highlightContainer)
        layer.addSublayer(inkContainer)
        liveLayer.fillRule = .nonZero
        layer.addSublayer(liveLayer)
        eraserCursor.fillColor = UIColor.systemGray.withAlphaComponent(0.15).cgColor
        eraserCursor.strokeColor = UIColor.systemGray.cgColor
        eraserCursor.lineWidth = 1
        eraserCursor.isHidden = true
        layer.addSublayer(eraserCursor)

        inkRecognizer.inkDelegate = self
        addGestureRecognizer(inkRecognizer)
        updateInputMode(fingerDrawing: session.tool.fingerDrawing)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var scale: CGFloat { PageMapping.scale(viewSize: bounds.size, pageSize: pageSize) }
    private var pageToView: CGAffineTransform { CGAffineTransform(scaleX: scale, y: scale) }

    func updateInputMode(fingerDrawing: Bool) {
        inkRecognizer.allowsFingerDrawing = fingerDrawing
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let containers: [CALayer] = [highlightContainer, inkContainer, liveLayer, eraserCursor]
        for container in containers {
            container.frame = bounds
        }
        let transform = pageToView
        for (id, shape) in strokeLayers {
            shape.frame = bounds
            if let stroke = renderedStrokes[id] {
                shape.path = stroke.outlinePath(transform: transform)
            }
        }
        CATransaction.commit()
    }

    /// Brings the shape layers in line with the session's strokes for this page.
    func sync() {
        guard let session else { return }
        render(session.strokes(onPage: pageIndex))
    }

    private func render(_ strokes: [InkStroke]) {
        let ids = Set(strokes.map(\.id))
        let transform = pageToView

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in Array(strokeLayers.keys) where !ids.contains(id) {
            strokeLayers[id]?.removeFromSuperlayer()
            strokeLayers[id] = nil
            renderedStrokes[id] = nil
        }
        for stroke in strokes {
            let shape: CAShapeLayer
            if let existing = strokeLayers[stroke.id] {
                shape = existing
            } else {
                shape = CAShapeLayer()
                shape.frame = bounds
                shape.fillRule = .nonZero
                strokeLayers[stroke.id] = shape
            }
            if renderedStrokes[stroke.id] != stroke {
                Self.applyAppearance(highlighter: stroke.isHighlighter, tape: stroke.isTape,
                                     revealed: stroke.isRevealed, color: stroke.color, to: shape)
                shape.path = stroke.outlinePath(transform: transform)
                renderedStrokes[stroke.id] = stroke
            }
            // Re-adding keeps z-order equal to stroke order inside each container.
            let container = stroke.isHighlighter ? highlightContainer : inkContainer
            container.addSublayer(shape)
        }
        CATransaction.commit()
    }

    private static func applyAppearance(highlighter: Bool, tape: Bool = false, revealed: Bool = false,
                                        color: RGBAColor, to shape: CAShapeLayer) {
        shape.fillColor = color.cgColor
        if highlighter {
            shape.opacity = highlighterOpacity
            shape.compositingFilter = "multiplyBlendMode"
            shape.strokeColor = nil
            shape.lineDashPattern = nil
        } else if tape {
            shape.opacity = revealed ? 0.16 : 0.96
            shape.compositingFilter = nil
            shape.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
            shape.lineWidth = 1
            shape.lineDashPattern = [5, 3]
        } else {
            shape.opacity = 1
            shape.compositingFilter = nil
            shape.strokeColor = nil
            shape.lineDashPattern = nil
        }
    }

    // MARK: Input routing

    func inkBegan(_ touch: UITouch, event: UIEvent?) {
        guard let session else { return }
        liveTool = session.tool
        if liveTool.kind == .eraser {
            eraseBegan(touch, event: event)
        } else if liveTool.kind == .lasso {
            return
        } else if liveTool.kind == .laser {
            // Legacy PDF pages simply show a temporary laser path until lifted.
            drawBegan(touch, event: event)
        } else {
            drawBegan(touch, event: event)
        }
    }

    func inkMoved(_ touch: UITouch, event: UIEvent?) {
        if liveTool.kind == .eraser {
            eraseMoved(touch, event: event)
        } else if liveTool.kind == .lasso {
            return
        } else {
            drawMoved(touch, event: event)
        }
    }

    func inkEnded(_ touch: UITouch, event: UIEvent?) {
        if liveTool.kind == .eraser {
            eraseMoved(touch, event: event)
            eraseEnded()
        } else if liveTool.kind == .lasso {
            return
        } else if liveTool.kind == .laser {
            inkCancelled()
        } else {
            append(event?.coalescedTouches(for: touch) ?? [touch])
            commitLiveStroke()
        }
    }

    func inkCancelled() {
        if liveTool.kind == .eraser {
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
            sync()
            return
        }
        livePoints.removeAll()
        pendingEstimates.removeAll()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = nil
        CATransaction.commit()
    }

    // MARK: Drawing

    private func drawBegan(_ touch: UITouch, event: UIEvent?) {
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        lastCommitted = nil
        liveStartTime = touch.timestamp
        let tape = liveTool.kind == .tape
        let color: RGBAColor = tape ? liveTool.tapeColor : (liveTool.kind == .laser ? liveTool.laserColor : liveTool.color)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.applyAppearance(highlighter: false, tape: tape, color: color, to: liveLayer)
        CATransaction.commit()
        append(event?.coalescedTouches(for: touch) ?? [touch])
        updateLiveStroke(predicted: [])
    }

    private func drawMoved(_ touch: UITouch, event: UIEvent?) {
        append(event?.coalescedTouches(for: touch) ?? [touch])
        let predicted = liveTool.prediction ? (event?.predictedTouches(for: touch) ?? []) : []
        updateLiveStroke(predicted: predicted)
    }

    func inkEstimatedPropertiesUpdated(_ touch: UITouch) {
        guard let updateIndex = touch.estimationUpdateIndex, let pointIndex = pendingEstimates[updateIndex] else { return }
        let force = forceValue(touch)
        if !touch.estimatedPropertiesExpectingUpdates.contains(.force) {
            pendingEstimates[updateIndex] = nil
        }
        if var committed = lastCommitted {
            guard pointIndex < committed.points.count else { return }
            committed.points[pointIndex].force = force
            lastCommitted = committed
            session?.refineStroke(id: committed.id, page: pageIndex, points: committed.points)
        } else if pointIndex < livePoints.count {
            livePoints[pointIndex].force = force
        }
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        super.touchesEstimatedPropertiesUpdated(touches)
        for touch in touches {
            inkEstimatedPropertiesUpdated(touch)
        }
    }

    private func append(_ touches: [UITouch]) {
        for touch in touches {
            if let updateIndex = touch.estimationUpdateIndex,
               touch.estimatedPropertiesExpectingUpdates.contains(.force) {
                pendingEstimates[updateIndex] = livePoints.count
            }
            livePoints.append(inkPoint(from: touch))
        }
    }

    private func forceValue(_ touch: UITouch) -> Float {
        PenModel.normalizedForce(raw: touch.force, maximum: touch.maximumPossibleForce, isStylus: touch.type == .pencil)
    }

    private func pagePoint(_ touch: UITouch) -> CGPoint {
        let location = touch.preciseLocation(in: self)
        let s = scale
        return CGPoint(x: location.x / s, y: location.y / s)
    }

    private func inkPoint(from touch: UITouch) -> InkPoint {
        let p = pagePoint(touch)
        let isStylus = touch.type == .pencil
        return InkPoint(x: Float(p.x),
                        y: Float(p.y),
                        force: forceValue(touch),
                        azimuth: isStylus ? Float(touch.azimuthAngle(in: self)) : 0,
                        altitude: isStylus ? Float(touch.altitudeAngle) : .pi / 2,
                        t: Float(touch.timestamp - liveStartTime))
    }

    private func makeStroke(points: [InkPoint]) -> InkStroke {
        if liveTool.kind == .tape {
            let shaped = liveTool.tapeStraight ? StrokeProcessor.straightened(points, snapAngleDegrees: 8) : points
            return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.tapeColor,
                             width: liveTool.tapeWidth, smoothing: 0.7, points: shaped, tool: .tape, revealed: false)
        }
        if liveTool.kind == .shape, let first = points.first, let last = points.last, points.count >= 2 {
            let built = ShapeBuilder.build(preset: liveTool.shapePreset, from: first.location, to: last.location)
            let fill = (liveTool.shapeFilled && built.primitive.supportsFill) ? liveTool.color : nil
            return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.color, width: liveTool.width,
                             smoothing: 0, points: [], tool: .pen, lineStyle: liveTool.lineStyle,
                             geometry: built.primitive, fillColor: fill)
        }
        return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.color, width: liveTool.width,
                         smoothing: liveTool.smoothing, points: points, tool: .pen,
                         lineStyle: liveTool.lineStyle)
    }

    private func updateLiveStroke(predicted: [UITouch]) {
        guard !livePoints.isEmpty else { return }
        let points = livePoints + predicted.map { inkPoint(from: $0) }
        let stroke = makeStroke(points: points)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = stroke.outlinePath(transform: pageToView, finished: false)
        CATransaction.commit()
    }

    private func commitLiveStroke() {
        defer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveLayer.path = nil
            CATransaction.commit()
        }
        guard let session, !livePoints.isEmpty else { return }
        let stroke = makeStroke(points: livePoints)
        // Straightened highlighter points no longer map 1:1 to touches, so skip force refinement.
        if stroke.points.count == livePoints.count {
            lastCommitted = (id: stroke.id, points: stroke.points)
        } else {
            lastCommitted = nil
        }
        livePoints.removeAll(keepingCapacity: true)
        session.addStroke(stroke, page: pageIndex)
    }

    // MARK: Erasing

    private var eraserRadius: CGFloat { CGFloat(liveTool.eraserRadius) }

    private func eraseBegan(_ touch: UITouch, event: UIEvent?) {
        guard let session else { return }
        let original = session.strokes(onPage: pageIndex)
        eraseOriginal = original
        eraseWorking = original
        let p = pagePoint(touch)
        lastErasePoint = p
        applyErase(from: p, to: p)
        setEraserCursor(p)
    }

    private func eraseMoved(_ touch: UITouch, event: UIEvent?) {
        guard eraseOriginal != nil else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let p = pagePoint(sample)
            applyErase(from: lastErasePoint ?? p, to: p)
            lastErasePoint = p
        }
        setEraserCursor(lastErasePoint)
    }

    private func eraseEnded() {
        defer {
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
        }
        guard let session, let original = eraseOriginal else { return }
        if eraseWorking != original {
            session.replaceStrokes(onPage: pageIndex, before: original, after: eraseWorking)
        } else {
            sync()
        }
    }

    private func applyErase(from a: CGPoint, to b: CGPoint) {
        let result = EraserEngine.erase(eraseWorking, from: a, to: b, radius: eraserRadius,
                                        mode: liveTool.eraserMode, highlighterOnly: false,
                                        cache: geometryCache)
        guard result.changed else { return }
        eraseWorking = result.strokes
        render(eraseWorking)
    }

    private func setEraserCursor(_ pagePoint: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let pagePoint {
            let center = pagePoint.applying(pageToView)
            let r = eraserRadius * scale
            eraserCursor.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r),
                                       transform: nil)
            eraserCursor.isHidden = false
        } else {
            eraserCursor.isHidden = true
        }
        CATransaction.commit()
    }
}
