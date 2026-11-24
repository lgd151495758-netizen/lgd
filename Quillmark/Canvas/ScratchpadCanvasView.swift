import CoreGraphics
import UIKit

/// Live vector overlay produced by `ScratchpadCanvasView` for 60fps mirroring onto the external display.
struct ScratchpadLiveOverlay {
    var strokePath: CGPath?
    var strokeColor: CGColor?
    var strokeOpacity: Float = 1
    var fillPath: CGPath? = nil
    var fillColor: CGColor? = nil
    var pendingStrokes: [PendingOverlayStroke] = []
    var cursorPath: CGPath?
    var laserGlowPath: CGPath?
    var laserCorePath: CGPath?
    var laserColor: CGColor?
    var laserOpacity: Float = 1

    var isEmpty: Bool {
        strokePath == nil && fillPath == nil && pendingStrokes.isEmpty
            && cursorPath == nil && laserGlowPath == nil && laserCorePath == nil
    }

    /// Translates every path by `offset` (used in Split Mode to place scratchpad ink below the HTML half).
    func translated(by offset: CGPoint) -> ScratchpadLiveOverlay {
        guard offset != .zero else { return self }
        var t = CGAffineTransform(translationX: offset.x, y: offset.y)
        return ScratchpadLiveOverlay(
            strokePath: strokePath?.copy(using: &t),
            strokeColor: strokeColor,
            strokeOpacity: strokeOpacity,
            fillPath: fillPath?.copy(using: &t),
            fillColor: fillColor,
            pendingStrokes: pendingStrokes.map { item in
                PendingOverlayStroke(
                    path: item.path.copy(using: &t) ?? item.path,
                    color: item.color,
                    opacity: item.opacity,
                    isHighlighter: item.isHighlighter,
                    fillPath: item.fillPath?.copy(using: &t),
                    fillColor: item.fillColor
                )
            },
            cursorPath: cursorPath?.copy(using: &t),
            laserGlowPath: laserGlowPath?.copy(using: &t),
            laserCorePath: laserCorePath?.copy(using: &t),
            laserColor: laserColor,
            laserOpacity: laserOpacity
        )
    }
}

/// Interactive math scratchpad canvas supporting the full Quillmark toolset:
/// Pen + Draw-and-Hold (Plan A live reshaping), Lasso (move/scale/recolor/duplicate/delete),
/// 14 Standard Shapes + shading + vertex editing, Virtual Compass + analytic intersection snap,
/// Cover Tape, Trail Laser Pointer, and Precise/Stroke Eraser.
final class ScratchpadCanvasView: UIView, InkInputDelegate, UIScribbleInteractionDelegate {
    private let session: DocumentSession

    /// Called whenever live ink/laser/eraser/lasso preview updates (60fps external display mirroring).
    var onLiveOverlayChanged: ((ScratchpadLiveOverlay?) -> Void)?
    /// Called whenever committed scratchpad strokes or paper style change.
    var onContentDidMutate: (() -> Void)?
    /// Called with active touch Y (local scratchpad coords) so wide 16:9 external screens follow the pen.
    var onActiveFocusY: ((CGFloat) -> Void)?

    var paperStyle: ScratchpadPaperStyle = .grid {
        didSet {
            guard paperStyle != oldValue else { return }
            setNeedsDisplay()
            onContentDidMutate?()
        }
    }

    var pageID: Int {
        session.currentScratchpadPageID
    }

    private let inkRecognizer = InkGestureRecognizer(target: nil, action: nil)
    private let tapeTapRecognizer = UITapGestureRecognizer()

    private let committedFillContainer = CALayer()
    private let committedContainer = CALayer()
    private let lassoPreviewFillContainer = CALayer()
    private let lassoPreviewContainer = CALayer()
    private let liveFillLayer = CAShapeLayer()
    private let liveLayer = CAShapeLayer()
    private let eraserCursor = CAShapeLayer()
    private let laserGlowLayer = CAShapeLayer()
    private let laserCoreLayer = CAShapeLayer()
    private let geometryOverlay = GeometryToolOverlayView()

    private let geometryCache = StrokeGeometryCache()
    private var strokeLayers: [UUID: CAShapeLayer] = [:]
    private var fillLayers: [UUID: CAShapeLayer] = [:]
    private var renderedStrokes: [UUID: InkStroke] = [:]
    private var hiddenStrokeIDs: Set<UUID> = []

    // Active interaction models
    private struct LassoPreviewEntry {
        let basePath: CGPath
        let baseFillPath: CGPath?
        let strokeColor: CGColor
        let fillColor: CGColor?
        let opacity: Float
        let isHighlighter: Bool
    }

    private struct LassoTransformContext {
        let originalStrokes: [InkStroke]
        let selectedIDs: Set<UUID>
        let strokesByID: [UUID: InkStroke]
        let baseBox: CGRect
        var currentScale: CGFloat = 1
        var pivot: CGPoint = .zero
        var currentTranslation: CGPoint = .zero
    }

    private struct ShapeEditContext {
        let strokeID: UUID
        let originalStrokes: [InkStroke]
        let originalStroke: InkStroke
        let basePrimitive: GeometricPrimitive
        var currentPrimitive: GeometricPrimitive
    }

    private enum ActiveInteraction {
        case none
        case normalInput
        case compassNeedle(grabOffset: CGPoint)
        case compassResize
        case compassButton(CompassState.HitZone, startPoint: CGPoint)
        case compassDraw(sweep: CompassSweep, crossedCloseHaptic: Bool)
        case protractorCenter(grabOffset: CGPoint)
        case protractorRay1
        case protractorRay2
        case protractorRotate(lastAngle: CGFloat)
        case protractorButton(ProtractorState.HitZone, startPoint: CGPoint)
        case shapeCreate(preset: ShapePreset, startPoint: CGPoint, rawStart: CGPoint, currentPrimitive: GeometricPrimitive?)
        case selectedHandle(index: Int, context: ShapeEditContext)
        case selectedBody(startPoint: CGPoint, context: ShapeEditContext)
        case selectedAction(SelectedShapeOverlay.ActionButton, startPoint: CGPoint)
        case lassoDraw(points: [CGPoint], rawStart: CGPoint)
        case lassoMove(startPoint: CGPoint, context: LassoTransformContext)
        case lassoScale(corner: LassoSelectionOverlay.ScaleCorner, startCorner: CGPoint, context: LassoTransformContext)
        case lassoAction(LassoSelectionOverlay.ActionButton, startPoint: CGPoint)
    }

    private var compassState = CompassState()
    private var protractorState = ProtractorState()
    private var selectedStrokeID: UUID?
    private var lassoSelectedIDs: [UUID] = []
    private var lassoPreviewEntries: [LassoPreviewEntry] = []
    private var lassoPreviewTransform: CGAffineTransform = .identity
    private var activeInteraction: ActiveInteraction = .none
    private var fingerControlInteraction: ActiveInteraction = .none
    private var cachedSnapPoints: [SnapPoint] = []
    private var lastSnapHapticPoint: CGPoint?

    // Drawing state
    private var liveTool = ToolSettings()
    private var livePoints: [InkPoint] = []
    private var liveStartTime: TimeInterval = 0
    private var pendingEstimates: [NSNumber: Int] = [:]

    // Draw-and-hold snapping
    private var holdTimer: DispatchWorkItem?
    private var holdAnchorPoint: CGPoint = .zero
    private var snappedBaseShape: RecognizedShape?
    private var snappedCurrentShape: RecognizedShape?
    private var snapDragOriginPoint: CGPoint = .zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // Laser pointer
    private let laserEngine = LaserPointerEngine()
    private var laserDisplayLink: CADisplayLink?
    private var laserDisplayLinkProxy: ScratchpadDisplayLinkProxy?
    private var laserFrame: LaserRenderFrame = .empty

    // Eraser state
    private var eraseOriginal: [InkStroke]?
    private var eraseWorking: [InkStroke] = []
    private var lastErasePoint: CGPoint?
    private lazy var multiTouchUndo = MultiTouchUndoGestureController(session: session)

    init(session: DocumentSession) {
        self.session = session
        self.paperStyle = session.scratchpadPaper
        super.init(frame: .zero)
        backgroundColor = .white
        isOpaque = true
        clipsToBounds = true
        contentMode = .redraw

        addInteraction(UIScribbleInteraction(delegate: self))

        layer.addSublayer(committedFillContainer)
        layer.addSublayer(committedContainer)

        lassoPreviewFillContainer.anchorPoint = .zero
        lassoPreviewFillContainer.position = .zero
        lassoPreviewContainer.anchorPoint = .zero
        lassoPreviewContainer.position = .zero
        layer.addSublayer(lassoPreviewFillContainer)
        layer.addSublayer(lassoPreviewContainer)

        liveFillLayer.fillRule = .nonZero
        liveFillLayer.opacity = 0.18
        layer.addSublayer(liveFillLayer)

        liveLayer.fillRule = .nonZero
        layer.addSublayer(liveLayer)

        eraserCursor.fillColor = UIColor.systemGray.withAlphaComponent(0.15).cgColor
        eraserCursor.strokeColor = UIColor.systemGray.cgColor
        eraserCursor.lineWidth = 1
        eraserCursor.isHidden = true
        layer.addSublayer(eraserCursor)

        laserGlowLayer.fillRule = .nonZero
        laserGlowLayer.shadowOffset = .zero
        laserGlowLayer.shadowRadius = 10
        laserGlowLayer.shadowOpacity = 0.9
        layer.addSublayer(laserGlowLayer)

        laserCoreLayer.fillRule = .nonZero
        laserCoreLayer.fillColor = UIColor.white.cgColor
        layer.addSublayer(laserCoreLayer)

        geometryOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(geometryOverlay)
        NSLayoutConstraint.activate([
            geometryOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            geometryOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            geometryOverlay.topAnchor.constraint(equalTo: topAnchor),
            geometryOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        geometryOverlay.onFingerTap = { [weak self] p in self?.handleGeometryControlTap(at: p) }
        geometryOverlay.onFingerPanBegan = { [weak self] p in self?.beginFingerGeometryDrag(at: p) }
        geometryOverlay.onFingerPanChanged = { [weak self] p in self?.updateFingerGeometryDrag(to: p) }
        geometryOverlay.onFingerPanEnded = { [weak self] _ in self?.endFingerGeometryDrag() }

        inkRecognizer.inkDelegate = self
        inkRecognizer.cancelsTouchesInView = true
        addGestureRecognizer(inkRecognizer)

        // Finger tap toggles Cover Tapes on the scratchpad cleanly.
        tapeTapRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        tapeTapRecognizer.addTarget(self, action: #selector(handleFingerTap(_:)))
        addGestureRecognizer(tapeTapRecognizer)

        multiTouchUndo.attach(to: self)

        applyToolConfiguration()
        syncCommittedStrokes()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopLaserLoop()
        holdTimer?.cancel()
    }

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committedFillContainer.frame = bounds
        committedContainer.frame = bounds
        if lassoPreviewTransform == .identity {
            lassoPreviewFillContainer.bounds = bounds
            lassoPreviewFillContainer.position = .zero
            lassoPreviewContainer.bounds = bounds
            lassoPreviewContainer.position = .zero
        }
        liveFillLayer.frame = bounds
        liveLayer.frame = bounds
        eraserCursor.frame = bounds
        laserGlowLayer.frame = bounds
        laserCoreLayer.frame = bounds
        for layer in strokeLayers.values { layer.frame = bounds }
        for layer in fillLayers.values { layer.frame = bounds }
        CATransaction.commit()
        clampCompassToBounds()
    }

    // MARK: Paper Background & Clean Snapshot (External Display)

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        Self.drawPaperBackground(paperStyle, in: bounds, ctx: ctx)
    }

    static func drawPaperBackground(_ style: ScratchpadPaperStyle, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        UIColor.white.setFill()
        ctx.fill(rect)

        switch style {
        case .blank:
            break

        case .grid:
            let step: CGFloat = 24
            ctx.setStrokeColor(UIColor(red: 0.45, green: 0.56, blue: 0.72, alpha: 0.22).cgColor)
            ctx.setLineWidth(0.75)
            var x: CGFloat = step
            while x < rect.maxX {
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += step
            }
            var y: CGFloat = step
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += step
            }
            ctx.strokePath()

        case .dot:
            let step: CGFloat = 24
            let r: CGFloat = 1.35
            ctx.setFillColor(UIColor(red: 0.40, green: 0.50, blue: 0.65, alpha: 0.36).cgColor)
            var y: CGFloat = step
            while y < rect.maxY {
                var x: CGFloat = step
                while x < rect.maxX {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
                y += step
            }

        case .graph:
            let minor: CGFloat = 16
            let major: CGFloat = 80
            ctx.setStrokeColor(UIColor(red: 0.38, green: 0.54, blue: 0.72, alpha: 0.14).cgColor)
            ctx.setLineWidth(0.5)
            var x: CGFloat = minor
            while x < rect.maxX {
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += minor
            }
            var y: CGFloat = minor
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += minor
            }
            ctx.strokePath()

            ctx.setStrokeColor(UIColor(red: 0.32, green: 0.48, blue: 0.68, alpha: 0.28).cgColor)
            ctx.setLineWidth(0.95)
            x = major
            while x < rect.maxX {
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                x += major
            }
            y = major
            while y < rect.maxY {
                ctx.move(to: CGPoint(x: rect.minX, y: y))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
                y += major
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Renders the clean scratchpad (paper background + committed strokes, excluding iPad-only
    /// handles/compass/lasso chrome and any stroke currently being dragged live) for external display.
    func renderCleanImage(size: CGSize) -> UIImage {
        let renderSize = CGSize(width: max(1, size.width), height: max(1, size.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(max(UIScreen.main.scale, 1), 2)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let strokes = session.strokes(onPage: pageID).filter { !hiddenStrokeIDs.contains($0.id) }
        return renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            Self.drawPaperBackground(paperStyle, in: CGRect(origin: .zero, size: renderSize), ctx: ctx)
            Self.drawStrokes(strokes, in: ctx)
        }
    }

    static func drawStrokes(_ strokes: [InkStroke], in ctx: CGContext) {
        // 1. Shading fills underneath outlines
        for stroke in strokes {
            guard let fillColor = stroke.fillColor, let fillPath = stroke.fillPath() else { continue }
            ctx.saveGState()
            ctx.setAlpha(0.18)
            ctx.setFillColor(fillColor.cgColor)
            ctx.addPath(fillPath)
            ctx.fillPath()
            ctx.restoreGState()
        }
        // 2. Outlines (highlighters, tapes, pen ink)
        for stroke in strokes {
            let path = stroke.outlinePath(finished: true)
            ctx.saveGState()
            if stroke.isHighlighter {
                ctx.setAlpha(CGFloat(PageInkView.highlighterOpacity))
                ctx.setBlendMode(.multiply)
                ctx.setFillColor(stroke.color.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            } else if stroke.isTape {
                ctx.setAlpha(stroke.isRevealed ? 0.16 : 0.96)
                ctx.setFillColor(stroke.color.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.25).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [5, 3])
                ctx.addPath(path)
                ctx.strokePath()
            } else {
                ctx.setFillColor(stroke.color.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }
    }

    // MARK: External State Sync

    func applyToolConfiguration() {
        let fingerDrawing = session.tool.fingerDrawing
        inkRecognizer.allowsFingerDrawing = fingerDrawing
        tapeTapRecognizer.isEnabled = !fingerDrawing
        geometryOverlay.isUserInteractionEnabled = !fingerDrawing

        let color: RGBAColor
        switch session.tool.kind {
        case .tape: color = session.tool.tapeColor
        case .laser: color = session.tool.laserColor
        default: color = session.tool.color
        }
        geometryOverlay.activeStrokeColor = UIColor(cgColor: color.cgColor)
    }

    func toolKindDidChange() {
        clearSelectedShape()
        clearLassoSelection()
    }

    func applyGeometryAid(_ aid: GeometryAid) {
        cancelActiveInteraction()
        if aid == .compass {
            clearSelectedShape()
            clearLassoSelection()
            if bounds.width > 0, bounds.height > 0,
               compassState.center == .zero || !bounds.insetBy(dx: 24, dy: 24).contains(compassState.center) {
                compassState.center = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            geometryOverlay.compass = compassState
        } else if aid == .protractor {
            clearSelectedShape()
            clearLassoSelection()
            if bounds.width > 0, bounds.height > 0,
               protractorState.center == .zero || !bounds.insetBy(dx: 24, dy: 24).contains(protractorState.center) {
                protractorState.center = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            geometryOverlay.protractor = protractorState
        }
        geometryOverlay.aid = aid
        applyToolConfiguration()
        if aid == .protractor {
            autoDetectProtractorAngle(triggerHaptic: false)
        }
    }

    func handlePageSwitch() {
        cancelActiveInteraction()
        clearSelectedShape()
        clearLassoSelection()
        syncCommittedStrokes()
        onContentDidMutate?()
    }

    func deactivate() {
        holdTimer?.cancel()
        holdTimer = nil
        stopLaserLoop()
        laserEngine.cancel()
        laserFrame = .empty
        cancelActiveInteraction()
        clearSelectedShape()
        clearLassoSelection()
        setLivePath(nil)
        onLiveOverlayChanged?(nil)
    }

    func syncCommittedStrokes() {
        let strokes = session.strokes(onPage: pageID).filter { !hiddenStrokeIDs.contains($0.id) }
        renderCommitted(strokes)
        refreshSelectedShapeOverlay()
        refreshLassoSelectionOverlay()
    }

    private func renderCommitted(_ strokes: [InkStroke]) {
        let ids = Set(strokes.map(\.id))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for id in Array(strokeLayers.keys) where !ids.contains(id) {
            strokeLayers[id]?.removeFromSuperlayer()
            strokeLayers[id] = nil
            fillLayers[id]?.removeFromSuperlayer()
            fillLayers[id] = nil
            renderedStrokes[id] = nil
        }
        var fillIdx = 0
        var strokeIdx = 0
        for stroke in strokes {
            let layer: CAShapeLayer
            if let existing = strokeLayers[stroke.id] {
                layer = existing
            } else {
                layer = CAShapeLayer()
                layer.frame = bounds
                layer.fillRule = .nonZero
                strokeLayers[stroke.id] = layer
            }
            if renderedStrokes[stroke.id] != stroke {
                layer.fillColor = stroke.color.cgColor
                if stroke.isHighlighter {
                    layer.opacity = PageInkView.highlighterOpacity
                    layer.compositingFilter = "multiplyBlendMode"
                    layer.strokeColor = nil
                    layer.lineDashPattern = nil
                } else if stroke.isTape {
                    layer.opacity = stroke.isRevealed ? 0.16 : 0.96
                    layer.compositingFilter = nil
                    layer.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
                    layer.lineWidth = 1
                    layer.lineDashPattern = [5, 3]
                } else {
                    layer.opacity = 1
                    layer.compositingFilter = nil
                    layer.strokeColor = nil
                    layer.lineDashPattern = nil
                }
                layer.path = stroke.outlinePath(finished: true)

                if let fillColor = stroke.fillColor, let fillPath = stroke.fillPath() {
                    let fl = fillLayers[stroke.id] ?? {
                        let l = CAShapeLayer()
                        l.frame = bounds
                        l.fillRule = .nonZero
                        l.opacity = 0.18
                        fillLayers[stroke.id] = l
                        return l
                    }()
                    fl.fillColor = fillColor.cgColor
                    fl.path = fillPath
                } else if let oldFill = fillLayers.removeValue(forKey: stroke.id) {
                    oldFill.removeFromSuperlayer()
                }
                renderedStrokes[stroke.id] = stroke
            }
            if let fl = fillLayers[stroke.id] {
                Self.ensureLayer(fl, in: committedFillContainer, at: fillIdx)
                fillIdx += 1
            }
            Self.ensureLayer(layer, in: committedContainer, at: strokeIdx)
            strokeIdx += 1
        }
        CATransaction.commit()
    }

    private static func ensureLayer(_ layer: CALayer, in container: CALayer, at index: Int) {
        if let sublayers = container.sublayers, index < sublayers.count, sublayers[index] === layer {
            return
        }
        container.insertSublayer(layer, at: UInt32(index))
    }

    @objc private func handleFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let pt = recognizer.location(in: self)
        let strokes = session.strokes(onPage: pageID)
        for stroke in strokes.reversed() where stroke.isTape {
            if let hitID = LassoEngine.hitTestSingleStroke(from: [stroke], origins: [:],
                                                           at: pt, tolerance: 12, cache: geometryCache) {
                session.toggleTape(id: hitID, page: pageID)
                onContentDidMutate?()
                return
            }
        }
    }

    // MARK: InkInputDelegate

    func inkBegan(_ touch: UITouch, event: UIEvent?) {
        liveTool = session.tool
        let pt = touch.location(in: self)
        onActiveFocusY?(pt.y)

        // 1. Active lasso selection controls
        if let lassoEdit = beginLassoSelectionInteraction(at: pt) {
            activeInteraction = lassoEdit
            return
        }
        if !lassoSelectedIDs.isEmpty {
            clearLassoSelection()
        }

        // 2. Selected shape handles / mini-bar / body
        if let shapeEdit = beginSelectedShapeInteraction(at: pt) {
            activeInteraction = shapeEdit
            return
        }
        if selectedStrokeID != nil {
            clearSelectedShape()
        }

        // 3. Virtual compass
        if let compassEdit = beginCompassInteraction(at: pt, allowDrawing: canDrawWithCompass) {
            activeInteraction = compassEdit
            return
        }

        // 4. Standard math shapes tool
        if liveTool.kind == .shape {
            activeInteraction = beginShapeCreation(at: pt)
            return
        }

        // 5. Lasso tool
        if liveTool.kind == .lasso {
            geometryOverlay.activeLassoPath = [pt]
            activeInteraction = .lassoDraw(points: [pt], rawStart: pt)
            return
        }

        activeInteraction = .normalInput
        switch liveTool.kind {
        case .eraser:
            eraseBegan(touch)
        case .laser:
            laserBegan(touch)
        case .pen, .tape, .shape, .lasso:
            drawBegan(touch, event: event)
        }
    }

    func inkMoved(_ touch: UITouch, event: UIEvent?) {
        let pt = touch.location(in: self)
        onActiveFocusY?(pt.y)
        if handleActiveInteractionMoved(to: pt) {
            return
        }
        switch liveTool.kind {
        case .eraser:
            eraseMoved(touch, event: event)
        case .laser:
            laserMoved(touch, event: event)
        case .pen, .tape, .shape, .lasso:
            drawMoved(touch, event: event)
        }
    }

    func inkEnded(_ touch: UITouch, event: UIEvent?) {
        let pt = touch.location(in: self)
        if handleActiveInteractionEnded(at: pt) {
            return
        }
        activeInteraction = .none
        switch liveTool.kind {
        case .eraser:
            eraseMoved(touch, event: event)
            eraseEnded()
        case .laser:
            laserMoved(touch, event: event)
            laserEnded()
        case .pen, .tape, .shape, .lasso:
            drawEnded(touch, event: event)
        }
    }

    func inkCancelled() {
        holdTimer?.cancel()
        holdTimer = nil
        snappedBaseShape = nil
        snappedCurrentShape = nil
        let wasInteractive: Bool
        switch activeInteraction {
        case .none, .normalInput: wasInteractive = false
        default: wasInteractive = true
        }
        cancelActiveInteraction()
        if wasInteractive { return }
        switch liveTool.kind {
        case .eraser:
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
            syncCommittedStrokes()
        case .laser:
            laserEngine.cancel()
            updateLaserRender()
        case .pen, .tape, .shape, .lasso:
            livePoints.removeAll()
            pendingEstimates.removeAll()
            setLivePath(nil)
        }
    }

    func inkEstimatedPropertiesUpdated(_ touch: UITouch) {
        guard let updateIndex = touch.estimationUpdateIndex, let pointIndex = pendingEstimates[updateIndex] else { return }
        if !touch.estimatedPropertiesExpectingUpdates.contains(.force) {
            pendingEstimates[updateIndex] = nil
        }
        if pointIndex < livePoints.count {
            livePoints[pointIndex].force = forceValue(touch)
        }
    }

    // MARK: Interactive Geometry, Compass & Lasso Dispatch

    private var canDrawWithCompass: Bool {
        switch liveTool.kind {
        case .pen, .tape, .shape: return true
        case .eraser, .laser, .lasso: return false
        }
    }

    private func clampCompassToBounds() {
        guard bounds.width > 64, bounds.height > 64 else { return }
        let safe = bounds.insetBy(dx: 32, dy: 32)
        if compassState.center != .zero {
            compassState.center.x = min(max(safe.minX, compassState.center.x), safe.maxX)
            compassState.center.y = min(max(safe.minY, compassState.center.y), safe.maxY)
            geometryOverlay.compass = compassState
        }
        if protractorState.center != .zero {
            protractorState.center.x = min(max(safe.minX, protractorState.center.x), safe.maxX)
            protractorState.center.y = min(max(safe.minY, protractorState.center.y), safe.maxY)
            geometryOverlay.protractor = protractorState
        }
    }

    private func refreshSnapPoints(excludingStrokeID: UUID? = nil) {
        cachedSnapPoints = GeometrySnapEngine.snapPoints(from: session.strokes(onPage: pageID),
                                                         origins: [:],
                                                         excludingStrokeID: excludingStrokeID)
    }

    private func updateSnapFeedback(_ snap: SnapPoint?) {
        geometryOverlay.activeSnapPoint = snap?.point
        geometryOverlay.activeSnapKind = snap?.kind
        if let snap {
            if let last = lastSnapHapticPoint, hypot(last.x - snap.point.x, last.y - snap.point.y) < 3 {
                return
            }
            lastSnapHapticPoint = snap.point
            haptic.impactOccurred(intensity: 0.6)
        } else {
            lastSnapHapticPoint = nil
        }
    }

    private func beginCompassInteraction(at pt: CGPoint, allowDrawing: Bool) -> ActiveInteraction? {
        if session.geometryAid == .protractor {
            let hit = protractorState.hitTest(pt, in: bounds)
            switch hit {
            case .none: return nil
            case .autoDetectButton, .cycleAngleButton, .stampAngleButton, .closeButton:
                return .protractorButton(hit, startPoint: pt)
            case .center:
                refreshSnapPoints()
                return .protractorCenter(grabOffset: CGPoint(x: protractorState.center.x - pt.x, y: protractorState.center.y - pt.y))
            case .ray1Handle:
                refreshSnapPoints()
                return .protractorRay1
            case .ray2Handle:
                refreshSnapPoints()
                return .protractorRay2
            case .ringRotate:
                let startAngle = atan2(pt.y - protractorState.center.y, pt.x - protractorState.center.x)
                return .protractorRotate(lastAngle: startAngle)
            }
        }
        guard session.geometryAid == .compass else { return nil }
        let hit = compassState.hitTest(pt, in: bounds)
        switch hit {
        case .none: return nil
        case .lockButton, .centerMarkButton, .fullCircleButton:
            return .compassButton(hit, startPoint: pt)
        case .needle:
            refreshSnapPoints()
            return .compassNeedle(grabOffset: CGPoint(x: compassState.center.x - pt.x, y: compassState.center.y - pt.y))
        case .resizeHandle:
            refreshSnapPoints()
            geometryOverlay.isResizingCompass = true
            return .compassResize
        case .drawCircle:
            guard allowDrawing else { return nil }
            let startAngle = atan2(pt.y - compassState.center.y, pt.x - compassState.center.x)
            compassState.armAngle = startAngle
            geometryOverlay.compass = compassState
            configureLiveLayerForCurrentTool()
            let sweep = CompassSweep(startAngle: startAngle)
            geometryOverlay.activeCompassSweep = sweep
            renderCompassLiveSweep(sweep)
            return .compassDraw(sweep: sweep, crossedCloseHaptic: false)
        }
    }

    private func handleActiveInteractionMoved(to pt: CGPoint) -> Bool {
        switch activeInteraction {
        case .none, .normalInput:
            return false

        case let .compassNeedle(grabOffset):
            let raw = CGPoint(x: pt.x + grabOffset.x, y: pt.y + grabOffset.y)
            let snap = compassState.moveCenter(to: raw, snapPoints: cachedSnapPoints)
            geometryOverlay.compass = compassState
            updateSnapFeedback(snap)
            return true

        case .compassResize:
            let snap = compassState.resize(withHandleAt: pt, snapPoints: cachedSnapPoints)
            geometryOverlay.compass = compassState
            updateSnapFeedback(snap)
            return true

        case let .protractorCenter(grabOffset):
            let raw = CGPoint(x: pt.x + grabOffset.x, y: pt.y + grabOffset.y)
            let snap = protractorState.moveCenter(to: raw, snapPoints: cachedSnapPoints)
            if snap != nil {
                autoDetectProtractorAngle(triggerHaptic: false)
            } else if protractorState.autoDetectedSource != nil {
                protractorState.autoDetectedSource = nil
                protractorState.detectedRayAngles = []
            }
            geometryOverlay.protractor = protractorState
            updateSnapFeedback(snap)
            return true

        case .protractorRay1:
            let snap = protractorState.aimRay1(to: pt, snapPoints: cachedSnapPoints)
            geometryOverlay.protractor = protractorState
            updateSnapFeedback(snap)
            return true

        case .protractorRay2:
            let snap = protractorState.aimRay2(to: pt, snapPoints: cachedSnapPoints)
            geometryOverlay.protractor = protractorState
            updateSnapFeedback(snap)
            return true

        case let .protractorRotate(lastAngle):
            let currentAngle = atan2(pt.y - protractorState.center.y, pt.x - protractorState.center.x)
            let delta = atan2(sin(currentAngle - lastAngle), cos(currentAngle - lastAngle))
            protractorState.rotateBoth(by: delta)
            activeInteraction = .protractorRotate(lastAngle: currentAngle)
            geometryOverlay.protractor = protractorState
            return true

        case .compassButton, .protractorButton, .selectedAction, .lassoAction:
            return true

        case var .compassDraw(sweep, crossedCloseHaptic):
            sweep.advance(to: pt, center: compassState.center)
            compassState.armAngle = sweep.currentAngle
            geometryOverlay.compass = compassState
            geometryOverlay.activeCompassSweep = sweep
            if sweep.isFullCircle, !crossedCloseHaptic {
                crossedCloseHaptic = true
                haptic.impactOccurred()
            }
            activeInteraction = .compassDraw(sweep: sweep, crossedCloseHaptic: crossedCloseHaptic)
            renderCompassLiveSweep(sweep)
            return true

        case let .shapeCreate(preset, startPoint, rawStart, _):
            let built = ShapeBuilder.build(preset: preset, from: startPoint, to: pt,
                                           snapPoints: cachedSnapPoints, snapThreshold: 10)
            updateSnapFeedback(built.snapped)
            activeInteraction = .shapeCreate(preset: preset, startPoint: startPoint,
                                             rawStart: rawStart, currentPrimitive: built.primitive)
            let stroke = makeGeometricStroke(built.primitive, allowFill: liveTool.shapeFilled)
            setLivePath(stroke.outlinePath(finished: true),
                        fillPath: stroke.fillPath(),
                        fillColor: stroke.fillColor?.cgColor)
            return true

        case var .selectedHandle(index, context):
            let moved = context.basePrimitive.movingHandle(at: index, to: pt,
                                                           snapPoints: cachedSnapPoints,
                                                           snapThreshold: 10)
            context.currentPrimitive = moved.primitive
            updateSnapFeedback(moved.snapped)
            activeInteraction = .selectedHandle(index: index, context: context)
            renderEditedShape(stroke: context.originalStroke, primitive: context.currentPrimitive)
            return true

        case var .selectedBody(startPoint, context):
            let delta = CGPoint(x: pt.x - startPoint.x, y: pt.y - startPoint.y)
            context.currentPrimitive = context.basePrimitive.translated(by: delta)
            activeInteraction = .selectedBody(startPoint: startPoint, context: context)
            renderEditedShape(stroke: context.originalStroke, primitive: context.currentPrimitive)
            return true

        case var .lassoDraw(points, rawStart):
            if let last = points.last, hypot(pt.x - last.x, pt.y - last.y) >= 2.5 {
                points.append(pt)
            }
            activeInteraction = .lassoDraw(points: points, rawStart: rawStart)
            geometryOverlay.activeLassoPath = points
            return true

        case var .lassoMove(startPoint, context):
            context.currentTranslation = CGPoint(x: pt.x - startPoint.x, y: pt.y - startPoint.y)
            activeInteraction = .lassoMove(startPoint: startPoint, context: context)
            applyLassoLivePreviewTransform(context: context)
            return true

        case var .lassoScale(corner, startCorner, context):
            let pivot = context.pivot
            let v0x = startCorner.x - pivot.x
            let v0y = startCorner.y - pivot.y
            let d0 = max(16, hypot(v0x, v0y))
            let proj = (pt.x - pivot.x) * (v0x / d0) + (pt.y - pivot.y) * (v0y / d0)
            context.currentScale = max(0.25, min(4.0, proj / d0))
            activeInteraction = .lassoScale(corner: corner, startCorner: startCorner, context: context)
            applyLassoLivePreviewTransform(context: context)
            return true
        }
    }

    private func handleActiveInteractionEnded(at pt: CGPoint) -> Bool {
        let current = activeInteraction
        switch current {
        case .none, .normalInput:
            return false

        case .compassNeedle, .compassResize, .protractorRay1, .protractorRay2, .protractorRotate:
            finishActiveInteraction()
            return true

        case .protractorCenter:
            finishActiveInteraction()
            autoDetectProtractorAngle(triggerHaptic: true)
            return true

        case let .compassButton(button, startPoint):
            if hypot(pt.x - startPoint.x, pt.y - startPoint.y) < 28 {
                executeCompassButton(button)
            }
            finishActiveInteraction()
            return true

        case let .protractorButton(button, startPoint):
            if hypot(pt.x - startPoint.x, pt.y - startPoint.y) < 28 {
                executeProtractorButton(button)
            }
            finishActiveInteraction()
            return true

        case let .selectedAction(action, startPoint):
            if hypot(pt.x - startPoint.x, pt.y - startPoint.y) < 28 {
                executeSelectedShapeAction(action)
            }
            finishActiveInteraction()
            return true

        case let .lassoAction(action, startPoint):
            if hypot(pt.x - startPoint.x, pt.y - startPoint.y) < 28 {
                executeLassoAction(action)
            }
            finishActiveInteraction()
            return true

        case let .lassoDraw(points, rawStart):
            finishActiveInteraction()
            geometryOverlay.activeLassoPath = []
            let dragDist = hypot(pt.x - rawStart.x, pt.y - rawStart.y)
            let strokes = session.strokes(onPage: pageID)
            if dragDist < 8, points.count <= 4 {
                if let hitID = LassoEngine.hitTestSingleStroke(from: strokes, origins: [:],
                                                               at: pt, tolerance: 14, cache: geometryCache) {
                    lassoSelectedIDs = [hitID]
                    refreshLassoSelectionOverlay()
                    haptic.impactOccurred()
                }
            } else {
                let ids = LassoEngine.selectStrokeIDs(from: strokes, origins: [:],
                                                      polygon: points, cache: geometryCache)
                if !ids.isEmpty {
                    lassoSelectedIDs = ids
                    refreshLassoSelectionOverlay()
                    haptic.impactOccurred()
                }
            }
            return true

        case let .lassoMove(_, context), let .lassoScale(_, _, context):
            finishActiveInteraction()
            commitLassoTransform(context)
            return true

        case var .compassDraw(sweep, _):
            sweep.advance(to: pt, center: compassState.center)
            finishActiveInteraction()
            if let primitive = sweep.primitive(center: compassState.center, radius: compassState.radius,
                                               showCenterMark: compassState.showCenterMark) {
                commitPreparedStroke(makeGeometricStroke(primitive))
            } else {
                setLivePath(nil)
            }
            return true

        case let .shapeCreate(preset, startPoint, rawStart, _):
            finishActiveInteraction()
            if hypot(pt.x - rawStart.x, pt.y - rawStart.y) < 8 {
                setLivePath(nil)
                let strokes = session.strokes(onPage: pageID)
                for stroke in strokes.reversed() {
                    if let geom = stroke.geometry, geom.hitTestBody(pt, tolerance: 14) {
                        selectedStrokeID = stroke.id
                        refreshSelectedShapeOverlay()
                        haptic.impactOccurred()
                        break
                    }
                }
                return true
            }
            let built = ShapeBuilder.build(preset: preset, from: startPoint, to: pt,
                                           snapPoints: cachedSnapPoints, snapThreshold: 10)
            let stroke = makeGeometricStroke(built.primitive, allowFill: liveTool.shapeFilled)
            commitPreparedStroke(stroke, selectAfterCommit: true)
            return true

        case let .selectedHandle(_, context), let .selectedBody(_, context):
            finishActiveInteraction()
            commitEditedShape(context)
            return true
        }
    }

    private func finishActiveInteraction() {
        activeInteraction = .none
        geometryOverlay.activeCompassSweep = nil
        geometryOverlay.isResizingCompass = false
        geometryOverlay.isEditingSelectedShape = false
        geometryOverlay.isTransformingLasso = false
        updateSnapFeedback(nil)
    }

    private func cancelActiveInteraction() {
        switch activeInteraction {
        case .compassDraw, .shapeCreate:
            setLivePath(nil)
        case .selectedHandle, .selectedBody:
            hiddenStrokeIDs.removeAll()
            setLivePath(nil)
            syncCommittedStrokes()
        case .lassoDraw:
            geometryOverlay.activeLassoPath = []
        case .lassoMove, .lassoScale:
            hiddenStrokeIDs.removeAll()
            clearLassoPreviewLayers()
            syncCommittedStrokes()
        default:
            break
        }
        finishActiveInteraction()
        emitLiveOverlay()
    }

    private func executeCompassButton(_ button: CompassState.HitZone) {
        switch button {
        case .lockButton:
            compassState.isRadiusLocked.toggle()
            geometryOverlay.compass = compassState
            haptic.impactOccurred()
        case .centerMarkButton:
            compassState.showCenterMark.toggle()
            geometryOverlay.compass = compassState
            haptic.impactOccurred()
        case .fullCircleButton:
            liveTool = session.tool
            let stroke = makeGeometricStroke(.circle(center: compassState.center, radius: compassState.radius,
                                                     showCenterMark: compassState.showCenterMark))
            commitPreparedStroke(stroke)
            haptic.impactOccurred()
        default:
            break
        }
    }

    private func executeProtractorButton(_ button: ProtractorState.HitZone) {
        switch button {
        case .autoDetectButton:
            autoDetectProtractorAngle(triggerHaptic: true)
        case .cycleAngleButton:
            protractorState.cycleAngle()
            geometryOverlay.protractor = protractorState
            haptic.impactOccurred()
        case .stampAngleButton:
            liveTool = session.tool
            let arcRadius = min(34, protractorState.radius * 0.28)
            if let primitive = protractorState.stampPrimitive(center: protractorState.center, radius: arcRadius) {
                commitPreparedStroke(makeGeometricStroke(primitive))
                haptic.impactOccurred()
            }
        case .closeButton:
            session.geometryAid = .none
            haptic.impactOccurred()
        default:
            break
        }
    }

    private func autoDetectProtractorAngle(triggerHaptic: Bool) {
        guard session.geometryAid == .protractor else { return }
        let rays = ProtractorAngleDetector.detectVectorRays(
            at: protractorState.center,
            from: session.strokes(onPage: pageID),
            origins: [:],
            tolerance: 16
        )
        if protractorState.applyDetectedRays(rays, source: .vector) {
            geometryOverlay.protractor = protractorState
            if triggerHaptic { haptic.impactOccurred(intensity: 0.7) }
        }
    }

    private func handleGeometryControlTap(at pt: CGPoint) {
        if let lasso = geometryOverlay.lassoSelection,
           case let .action(button) = lasso.hitTest(pt, in: bounds) {
            executeLassoAction(button)
            return
        }
        if let selected = geometryOverlay.selectedShape,
           case let .action(button) = selected.hitTest(pt, in: bounds, bodyHit: false) {
            executeSelectedShapeAction(button)
            return
        }
        if session.geometryAid == .protractor {
            let hit = protractorState.hitTest(pt, in: bounds)
            switch hit {
            case .autoDetectButton, .cycleAngleButton, .stampAngleButton, .closeButton:
                executeProtractorButton(hit)
            default:
                break
            }
            return
        }
        guard session.geometryAid == .compass else { return }
        let hit = compassState.hitTest(pt, in: bounds)
        if hit == .lockButton || hit == .centerMarkButton || hit == .fullCircleButton {
            executeCompassButton(hit)
        }
    }

    private func beginFingerGeometryDrag(at pt: CGPoint) {
        if let lassoEdit = beginLassoSelectionInteraction(at: pt) {
            fingerControlInteraction = lassoEdit
            return
        }
        if let edit = beginSelectedShapeInteraction(at: pt) {
            fingerControlInteraction = edit
            return
        }
        fingerControlInteraction = beginCompassInteraction(at: pt, allowDrawing: false) ?? .none
    }

    private func updateFingerGeometryDrag(to pt: CGPoint) {
        let saved = activeInteraction
        activeInteraction = fingerControlInteraction
        _ = handleActiveInteractionMoved(to: pt)
        fingerControlInteraction = activeInteraction
        activeInteraction = saved
    }

    private func endFingerGeometryDrag() {
        let saved = activeInteraction
        activeInteraction = fingerControlInteraction
        switch activeInteraction {
        case let .lassoMove(_, context), let .lassoScale(_, _, context):
            finishActiveInteraction()
            commitLassoTransform(context)
        case let .selectedHandle(_, context), let .selectedBody(_, context):
            finishActiveInteraction()
            commitEditedShape(context)
        case .protractorCenter:
            finishActiveInteraction()
            autoDetectProtractorAngle(triggerHaptic: true)
        default:
            geometryOverlay.isResizingCompass = false
            geometryOverlay.isEditingSelectedShape = false
            geometryOverlay.isTransformingLasso = false
            updateSnapFeedback(nil)
        }
        fingerControlInteraction = .none
        activeInteraction = saved
    }

    private func renderCompassLiveSweep(_ sweep: CompassSweep) {
        guard let primitive = sweep.primitive(center: compassState.center, radius: compassState.radius,
                                              showCenterMark: compassState.showCenterMark) else {
            setLivePath(nil)
            return
        }
        setLivePath(makeGeometricStroke(primitive).outlinePath(finished: true))
    }

    // MARK: Selected Shape Editing

    private func clearSelectedShape() {
        guard selectedStrokeID != nil || geometryOverlay.selectedShape != nil else { return }
        selectedStrokeID = nil
        geometryOverlay.isEditingSelectedShape = false
        geometryOverlay.selectedShape = nil
    }

    private func overlayModel(for stroke: InkStroke, primitive: GeometricPrimitive) -> SelectedShapeOverlay {
        SelectedShapeOverlay(
            strokeID: stroke.id,
            handles: primitive.controlHandles(),
            boundingBox: primitive.boundingBox(),
            lineStyle: stroke.resolvedLineStyle,
            supportsFill: primitive.supportsFill,
            isFilled: stroke.fillColor != nil,
            isCircularWithCenterMark: primitive.isCircularWithCenterMark,
            showsCenterMark: primitive.showsCenterMark
        )
    }

    private func refreshSelectedShapeOverlay() {
        guard let id = selectedStrokeID else {
            if geometryOverlay.selectedShape != nil { geometryOverlay.selectedShape = nil }
            return
        }
        switch activeInteraction {
        case .selectedHandle, .selectedBody: return
        default: break
        }
        guard let stroke = session.strokes(onPage: pageID).first(where: { $0.id == id }),
              let geom = stroke.geometry else {
            clearSelectedShape()
            return
        }
        geometryOverlay.selectedShape = overlayModel(for: stroke, primitive: geom)
    }

    private func beginSelectedShapeInteraction(at pt: CGPoint) -> ActiveInteraction? {
        guard let id = selectedStrokeID,
              let overlay = geometryOverlay.selectedShape,
              overlay.strokeID == id,
              let stroke = session.strokes(onPage: pageID).first(where: { $0.id == id }),
              let geom = stroke.geometry else { return nil }
        let bodyHit = geom.hitTestBody(pt, tolerance: 14)
        let hit = overlay.hitTest(pt, in: bounds, bodyHit: bodyHit)
        switch hit {
        case .none: return nil
        case let .action(button): return .selectedAction(button, startPoint: pt)
        case let .handle(index):
            return .selectedHandle(index: index, context: startEditingSelectedStroke(stroke, primitive: geom))
        case .body:
            return .selectedBody(startPoint: pt, context: startEditingSelectedStroke(stroke, primitive: geom))
        }
    }

    private func startEditingSelectedStroke(_ stroke: InkStroke, primitive: GeometricPrimitive) -> ShapeEditContext {
        let original = session.strokes(onPage: pageID)
        refreshSnapPoints(excludingStrokeID: stroke.id)
        hiddenStrokeIDs = [stroke.id]
        syncCommittedStrokes()
        onContentDidMutate?()
        geometryOverlay.isEditingSelectedShape = true
        configureLiveLayer(for: stroke)
        renderEditedShape(stroke: stroke, primitive: primitive)
        return ShapeEditContext(strokeID: stroke.id, originalStrokes: original, originalStroke: stroke,
                                basePrimitive: primitive, currentPrimitive: primitive)
    }

    private func renderEditedShape(stroke: InkStroke, primitive: GeometricPrimitive) {
        var preview = stroke
        preview.geometry = primitive
        preview.baked = nil
        preview.points = []
        setLivePath(preview.outlinePath(finished: true),
                    fillPath: preview.fillPath(),
                    fillColor: preview.fillColor?.cgColor)
        geometryOverlay.selectedShape = overlayModel(for: stroke, primitive: primitive)
    }

    private func commitEditedShape(_ context: ShapeEditContext) {
        hiddenStrokeIDs.removeAll()
        var updated = context.originalStroke
        updated.geometry = context.currentPrimitive
        updated.baked = nil
        updated.points = []
        setLivePath(nil)
        if updated != context.originalStroke {
            let after = context.originalStrokes.map { $0.id == updated.id ? updated : $0 }
            session.replaceStrokes(onPage: pageID, before: context.originalStrokes, after: after)
        }
        syncCommittedStrokes()
        onContentDidMutate?()
    }

    private func executeSelectedShapeAction(_ action: SelectedShapeOverlay.ActionButton) {
        guard let id = selectedStrokeID else { return }
        let before = session.strokes(onPage: pageID)
        guard let idx = before.firstIndex(where: { $0.id == id }) else {
            clearSelectedShape()
            return
        }
        var stroke = before[idx]
        switch action {
        case .cycleLineStyle:
            let styles = StrokeLineStyle.allCases
            let nextIdx = ((styles.firstIndex(of: stroke.resolvedLineStyle) ?? 0) + 1) % styles.count
            stroke.lineStyle = styles[nextIdx]
            var after = before
            after[idx] = stroke
            session.replaceStrokes(onPage: pageID, before: before, after: after)
        case .toggleFillOrCenter:
            guard let geom = stroke.geometry else { return }
            if geom.supportsFill {
                stroke.fillColor = (stroke.fillColor == nil) ? stroke.color : nil
            } else if geom.isCircularWithCenterMark {
                stroke.geometry = geom.togglingCenterMark()
            } else {
                return
            }
            var after = before
            after[idx] = stroke
            session.replaceStrokes(onPage: pageID, before: before, after: after)
        case .duplicate:
            var copy = stroke.translated(by: CGPoint(x: 24, y: 24))
            copy.id = UUID()
            session.addStroke(copy, page: pageID)
            selectedStrokeID = copy.id
        case .delete:
            var after = before
            after.remove(at: idx)
            clearSelectedShape()
            session.replaceStrokes(onPage: pageID, before: before, after: after)
        }
        haptic.impactOccurred()
        syncCommittedStrokes()
        onContentDidMutate?()
    }

    private func beginShapeCreation(at pt: CGPoint) -> ActiveInteraction {
        refreshSnapPoints()
        let startSnap = GeometrySnapEngine.nearestPoint(to: pt, in: cachedSnapPoints, threshold: 10)
        updateSnapFeedback(startSnap)
        configureLiveLayerForCurrentTool()
        return .shapeCreate(preset: liveTool.shapePreset, startPoint: startSnap?.point ?? pt,
                            rawStart: pt, currentPrimitive: nil)
    }

    // MARK: Lasso Selection & Batch Actions

    private func clearLassoSelection() {
        guard !lassoSelectedIDs.isEmpty || geometryOverlay.lassoSelection != nil || !geometryOverlay.activeLassoPath.isEmpty else {
            return
        }
        lassoSelectedIDs.removeAll()
        geometryOverlay.activeLassoPath = []
        geometryOverlay.isTransformingLasso = false
        geometryOverlay.lassoSelection = nil
    }

    private func refreshLassoSelectionOverlay() {
        guard !lassoSelectedIDs.isEmpty else {
            if geometryOverlay.lassoSelection != nil { geometryOverlay.lassoSelection = nil }
            return
        }
        switch activeInteraction {
        case .lassoMove, .lassoScale: return
        default: break
        }
        let idSet = Set(lassoSelectedIDs)
        let selected = session.strokes(onPage: pageID).filter { idSet.contains($0.id) }
        guard !selected.isEmpty else {
            clearLassoSelection()
            return
        }
        let box = LassoEngine.documentBounds(of: selected, origins: [:], cache: geometryCache)
        guard !box.isNull, box.minX.isFinite, box.minY.isFinite else {
            clearLassoSelection()
            return
        }
        let firstColor = selected.first?.color
        let sharedColor = selected.allSatisfy({ $0.color == firstColor }) ? firstColor : nil
        geometryOverlay.lassoSelection = LassoSelectionOverlay(
            strokeIDs: selected.map(\.id),
            boundingBox: box,
            activeColor: sharedColor
        )
    }

    private func beginLassoSelectionInteraction(at pt: CGPoint) -> ActiveInteraction? {
        guard !lassoSelectedIDs.isEmpty, let overlay = geometryOverlay.lassoSelection else { return nil }
        switch overlay.hitTest(pt, in: bounds) {
        case .none: return nil
        case let .action(button): return .lassoAction(button, startPoint: pt)
        case .body:
            guard let ctx = startLassoTransform() else { return nil }
            return .lassoMove(startPoint: pt, context: ctx)
        case let .handle(corner):
            guard var ctx = startLassoTransform() else { return nil }
            ctx.pivot = overlay.oppositeCorner(of: corner, in: ctx.baseBox)
            let startCorner = overlay.cornerPoint(of: corner, in: ctx.baseBox)
            return .lassoScale(corner: corner, startCorner: startCorner, context: ctx)
        }
    }

    private func startLassoTransform() -> LassoTransformContext? {
        let original = session.strokes(onPage: pageID)
        let idSet = Set(lassoSelectedIDs)
        let selected = original.filter { idSet.contains($0.id) }
        guard !selected.isEmpty else { return nil }
        let baseBox = LassoEngine.documentBounds(of: selected, origins: [:], cache: geometryCache)
        guard !baseBox.isNull else { return nil }

        clearLassoPreviewLayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewFillContainer.setAffineTransform(.identity)
        lassoPreviewContainer.setAffineTransform(.identity)
        lassoPreviewFillContainer.bounds = bounds
        lassoPreviewFillContainer.position = .zero
        lassoPreviewContainer.bounds = bounds
        lassoPreviewContainer.position = .zero

        var byID: [UUID: InkStroke] = [:]
        var entries: [LassoPreviewEntry] = []
        for stroke in selected {
            byID[stroke.id] = stroke
            let path = stroke.outlinePath(finished: true)
            let fillPath = stroke.fillPath()
            let fillColor = stroke.fillColor?.cgColor
            if let fillPath, let fillColor {
                let fl = CAShapeLayer()
                fl.frame = bounds
                fl.fillRule = .nonZero
                fl.opacity = 0.18
                fl.fillColor = fillColor
                fl.path = fillPath
                lassoPreviewFillContainer.addSublayer(fl)
            }
            let layer = CAShapeLayer()
            layer.frame = bounds
            layer.fillRule = .nonZero
            layer.path = path
            let opacity: Float
            if stroke.isHighlighter {
                opacity = PageInkView.highlighterOpacity
                layer.compositingFilter = "multiplyBlendMode"
            } else if stroke.isTape {
                opacity = stroke.isRevealed ? 0.16 : 0.96
                layer.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
                layer.lineWidth = 1
                layer.lineDashPattern = [5, 3]
            } else {
                opacity = 1
            }
            layer.fillColor = stroke.color.cgColor
            layer.opacity = opacity
            lassoPreviewContainer.addSublayer(layer)
            entries.append(LassoPreviewEntry(basePath: path, baseFillPath: fillPath,
                                             strokeColor: stroke.color.cgColor, fillColor: fillColor,
                                             opacity: opacity, isHighlighter: stroke.isHighlighter))
        }
        lassoPreviewEntries = entries
        lassoPreviewTransform = .identity
        CATransaction.commit()

        hiddenStrokeIDs = idSet
        syncCommittedStrokes()
        onContentDidMutate?()
        geometryOverlay.isTransformingLasso = true
        emitLiveOverlay()
        return LassoTransformContext(originalStrokes: original, selectedIDs: idSet,
                                     strokesByID: byID, baseBox: baseBox)
    }

    private func applyLassoLivePreviewTransform(context: LassoTransformContext) {
        let previewT: CGAffineTransform
        if abs(context.currentScale - 1) > 1e-4 {
            let s = context.currentScale
            let p = context.pivot
            previewT = CGAffineTransform(translationX: p.x, y: p.y)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -p.x, y: -p.y)
        } else {
            previewT = CGAffineTransform(translationX: context.currentTranslation.x,
                                         y: context.currentTranslation.y)
        }
        lassoPreviewTransform = previewT
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewFillContainer.setAffineTransform(previewT)
        lassoPreviewContainer.setAffineTransform(previewT)
        CATransaction.commit()

        if var overlay = geometryOverlay.lassoSelection {
            overlay.boundingBox = context.baseBox.applying(previewT)
            geometryOverlay.lassoSelection = overlay
        }
        emitLiveOverlay()
    }

    private func clearLassoPreviewLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewFillContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
        lassoPreviewContainer.sublayers?.forEach { $0.removeFromSuperlayer() }
        lassoPreviewFillContainer.setAffineTransform(.identity)
        lassoPreviewContainer.setAffineTransform(.identity)
        lassoPreviewEntries.removeAll()
        lassoPreviewTransform = .identity
        CATransaction.commit()
    }

    private func commitLassoTransform(_ context: LassoTransformContext) {
        hiddenStrokeIDs.removeAll()
        clearLassoPreviewLayers()
        let unchanged = abs(context.currentScale - 1) < 1e-3
            && hypot(context.currentTranslation.x, context.currentTranslation.y) < 0.5
        if !unchanged {
            let after = context.originalStrokes.map { stroke -> InkStroke in
                guard let base = context.strokesByID[stroke.id] else { return stroke }
                return LassoEngine.transformStroke(base, scale: context.currentScale,
                                                   around: context.pivot,
                                                   translation: context.currentTranslation)
            }
            session.replaceStrokes(onPage: pageID, before: context.originalStrokes, after: after)
        }
        syncCommittedStrokes()
        emitLiveOverlay()
        onContentDidMutate?()
    }

    private func executeLassoAction(_ action: LassoSelectionOverlay.ActionButton) {
        guard !lassoSelectedIDs.isEmpty else { return }
        let before = session.strokes(onPage: pageID)
        let idSet = Set(lassoSelectedIDs)
        switch action {
        case let .color(idx):
            guard idx >= 0, idx < ToolSettings.palette.count else { return }
            let newColor = ToolSettings.palette[idx]
            let after = before.map { stroke -> InkStroke in
                guard idSet.contains(stroke.id) else { return stroke }
                var copy = stroke
                copy.color = newColor
                if copy.fillColor != nil { copy.fillColor = newColor }
                return copy
            }
            session.replaceStrokes(onPage: pageID, before: before, after: after)
        case .duplicate:
            var newIDs: [UUID] = []
            var copies: [InkStroke] = []
            for stroke in before where idSet.contains(stroke.id) {
                var copy = stroke.translated(by: CGPoint(x: 24, y: 24))
                copy.id = UUID()
                newIDs.append(copy.id)
                copies.append(copy)
            }
            guard !copies.isEmpty else { return }
            lassoSelectedIDs = newIDs
            session.replaceStrokes(onPage: pageID, before: before, after: before + copies)
        case .delete:
            clearLassoSelection()
            session.replaceStrokes(onPage: pageID, before: before, after: before.filter { !idSet.contains($0.id) })
        }
        haptic.impactOccurred()
        syncCommittedStrokes()
        onContentDidMutate?()
    }

    // MARK: Freehand Pen, Tape & Draw-and-Hold

    private func makeGeometricStroke(_ primitive: GeometricPrimitive, allowFill: Bool = false) -> InkStroke {
        if liveTool.kind == .tape {
            return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.tapeColor,
                             width: liveTool.tapeWidth, smoothing: 0, points: [],
                             tool: .tape, lineStyle: .solid, revealed: false, geometry: primitive)
        }
        let fill = (allowFill && primitive.supportsFill) ? liveTool.color : nil
        return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.color,
                         width: liveTool.width, smoothing: 0, points: [],
                         tool: .pen, lineStyle: liveTool.lineStyle, geometry: primitive, fillColor: fill)
    }

    private func configureLiveLayerForCurrentTool() {
        let tape = liveTool.kind == .tape
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if tape {
            liveLayer.fillColor = liveTool.tapeColor.cgColor
            liveLayer.opacity = 0.96
            liveLayer.compositingFilter = nil
            liveLayer.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
            liveLayer.lineWidth = 1
            liveLayer.lineDashPattern = [5, 3]
        } else {
            liveLayer.fillColor = liveTool.color.cgColor
            liveLayer.opacity = 1
            liveLayer.compositingFilter = nil
            liveLayer.strokeColor = nil
            liveLayer.lineDashPattern = nil
        }
        CATransaction.commit()
    }

    private func configureLiveLayer(for stroke: InkStroke) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.fillColor = stroke.color.cgColor
        if stroke.isTape {
            liveLayer.opacity = 0.96
            liveLayer.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
            liveLayer.lineWidth = 1
            liveLayer.lineDashPattern = [5, 3]
        } else {
            liveLayer.opacity = 1
            liveLayer.strokeColor = nil
            liveLayer.lineDashPattern = nil
        }
        liveLayer.compositingFilter = nil
        CATransaction.commit()
    }

    private func drawBegan(_ touch: UITouch, event: UIEvent?) {
        holdTimer?.cancel()
        holdTimer = nil
        snappedBaseShape = nil
        snappedCurrentShape = nil
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        liveStartTime = touch.timestamp
        configureLiveLayerForCurrentTool()
        holdAnchorPoint = touch.location(in: self)
        append(event?.coalescedTouches(for: touch) ?? [touch])
        updateLiveStroke(predicted: [])
        scheduleHoldRecognitionIfNeeded()
    }

    private func drawMoved(_ touch: UITouch, event: UIEvent?) {
        if let baseShape = snappedBaseShape {
            let current = touch.preciseLocation(in: self)
            switch baseShape {
            case let .line(start, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: current, in: cachedSnapPoints,
                                                              threshold: 10, excluding: start, excludeRadius: 8) {
                    snappedCurrentShape = .line(start: start, end: snap.point)
                    updateSnapFeedback(snap)
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: current, initialAnchor: snapDragOriginPoint)
                    updateSnapFeedback(nil)
                }
            case let .arrow(start, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: current, in: cachedSnapPoints,
                                                              threshold: 10, excluding: start, excludeRadius: 8) {
                    snappedCurrentShape = .arrow(start: start, end: snap.point)
                    updateSnapFeedback(snap)
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: current, initialAnchor: snapDragOriginPoint)
                    updateSnapFeedback(nil)
                }
            case let .circle(center, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: current, in: cachedSnapPoints,
                                                              threshold: 10, excluding: center, excludeRadius: 12) {
                    let r = max(12, hypot(snap.point.x - center.x, snap.point.y - center.y))
                    snappedCurrentShape = .circle(center: center, radius: r)
                    updateSnapFeedback(snap)
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: current, initialAnchor: snapDragOriginPoint)
                    updateSnapFeedback(nil)
                }
            case let .parabola(vertex, _, _, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: current, in: cachedSnapPoints,
                                                              threshold: 10, excluding: vertex, excludeRadius: 12) {
                    snappedCurrentShape = baseShape.adjusted(to: snap.point, initialAnchor: snapDragOriginPoint)
                    updateSnapFeedback(snap)
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: current, initialAnchor: snapDragOriginPoint)
                    updateSnapFeedback(nil)
                }
            case .rectangle, .polygon:
                snappedCurrentShape = baseShape.adjusted(to: current, initialAnchor: snapDragOriginPoint)
                updateSnapFeedback(nil)
            }
            if let shape = snappedCurrentShape {
                setLivePath(makeGeometricStroke(shape.primitive).outlinePath(finished: true))
            }
            return
        }

        append(event?.coalescedTouches(for: touch) ?? [touch])
        let predicted = liveTool.prediction ? (event?.predictedTouches(for: touch) ?? []) : []
        updateLiveStroke(predicted: predicted)

        let pt = touch.location(in: self)
        if hypot(pt.x - holdAnchorPoint.x, pt.y - holdAnchorPoint.y) > 6 {
            holdAnchorPoint = pt
            scheduleHoldRecognitionIfNeeded()
        }
    }

    private func drawEnded(_ touch: UITouch, event: UIEvent?) {
        holdTimer?.cancel()
        holdTimer = nil
        updateSnapFeedback(nil)
        if let snapped = snappedCurrentShape {
            snappedBaseShape = nil
            snappedCurrentShape = nil
            livePoints.removeAll(keepingCapacity: true)
            pendingEstimates.removeAll()
            commitPreparedStroke(makeGeometricStroke(snapped.primitive))
            return
        }
        append(event?.coalescedTouches(for: touch) ?? [touch])
        guard !livePoints.isEmpty else {
            setLivePath(nil)
            return
        }
        let stroke = makeStroke(points: livePoints)
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        commitPreparedStroke(stroke)
    }

    private func scheduleHoldRecognitionIfNeeded() {
        holdTimer?.cancel()
        holdTimer = nil
        guard liveTool.kind == .pen && liveTool.drawAndHold else { return }
        let work = DispatchWorkItem { [weak self] in self?.attemptHoldShapeSnap() }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: work)
    }

    private func attemptHoldShapeSnap() {
        holdTimer = nil
        guard snappedBaseShape == nil, livePoints.count >= 4 else { return }
        guard var shape = ShapeRecognizer.recognize(livePoints.map(\.location)) else { return }
        refreshSnapPoints()
        switch shape {
        case let .line(start, end):
            let s = GeometrySnapEngine.nearestPoint(to: start, in: cachedSnapPoints, threshold: 10)?.point ?? start
            if let endSnap = GeometrySnapEngine.nearestPoint(to: end, in: cachedSnapPoints,
                                                             threshold: 10, excluding: s, excludeRadius: 8) {
                shape = .line(start: s, end: endSnap.point)
                updateSnapFeedback(endSnap)
            } else {
                shape = .line(start: s, end: end)
            }
        case let .arrow(start, end):
            let s = GeometrySnapEngine.nearestPoint(to: start, in: cachedSnapPoints, threshold: 10)?.point ?? start
            if let endSnap = GeometrySnapEngine.nearestPoint(to: end, in: cachedSnapPoints,
                                                             threshold: 10, excluding: s, excludeRadius: 8) {
                shape = .arrow(start: s, end: endSnap.point)
                updateSnapFeedback(endSnap)
            } else {
                shape = .arrow(start: s, end: end)
            }
        case let .circle(center, radius):
            if let snap = GeometrySnapEngine.nearestPoint(to: center, in: cachedSnapPoints, threshold: 10) {
                shape = .circle(center: snap.point, radius: radius)
                updateSnapFeedback(snap)
            }
        case let .parabola(vertex, axisAngle, halfWidth, height):
            if let snap = GeometrySnapEngine.nearestPoint(to: vertex, in: cachedSnapPoints, threshold: 10) {
                shape = .parabola(vertex: snap.point, axisAngle: axisAngle, halfWidth: halfWidth, height: height)
                updateSnapFeedback(snap)
            }
        case .rectangle, .polygon:
            break
        }
        snappedBaseShape = shape
        snappedCurrentShape = shape
        snapDragOriginPoint = livePoints.last?.location ?? .zero
        haptic.impactOccurred()
        setLivePath(makeGeometricStroke(shape.primitive).outlinePath(finished: true))
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

    private func inkPoint(from touch: UITouch) -> InkPoint {
        let p = touch.preciseLocation(in: self)
        let isStylus = touch.type == .pencil
        return InkPoint(x: Float(p.x), y: Float(p.y), force: forceValue(touch),
                        azimuth: isStylus ? Float(touch.azimuthAngle(in: self)) : 0,
                        altitude: isStylus ? Float(touch.altitudeAngle) : .pi / 2,
                        t: Float(touch.timestamp - liveStartTime))
    }

    private func makeStroke(points: [InkPoint]) -> InkStroke {
        if liveTool.kind == .tape {
            let shaped = liveTool.tapeStraight ? StrokeProcessor.straightened(points, snapAngleDegrees: 8) : points
            return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.tapeColor,
                             width: liveTool.tapeWidth, smoothing: 0.7, points: shaped,
                             tool: .tape, lineStyle: .solid, revealed: false)
        }
        return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.color, width: liveTool.width,
                         smoothing: liveTool.smoothing, points: points, tool: .pen,
                         lineStyle: liveTool.lineStyle)
    }

    private func updateLiveStroke(predicted: [UITouch]) {
        guard !livePoints.isEmpty else { return }
        let stroke = makeStroke(points: livePoints + predicted.map { inkPoint(from: $0) })
        setLivePath(stroke.outlinePath(finished: false))
    }

    private func setLivePath(_ path: CGPath?, fillPath: CGPath? = nil, fillColor: CGColor? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = path
        liveFillLayer.path = fillPath
        liveFillLayer.fillColor = fillColor
        CATransaction.commit()
        emitLiveOverlay()
    }

    private func commitPreparedStroke(_ stroke: InkStroke, selectAfterCommit: Bool = false) {
        setLivePath(nil)
        session.addStroke(stroke, page: pageID)
        if selectAfterCommit {
            selectedStrokeID = stroke.id
        }
        syncCommittedStrokes()
        onContentDidMutate?()
    }

    // MARK: Laser Pointer

    private func laserBegan(_ touch: UITouch) {
        stopLaserLoop()
        laserEngine.begin(at: touch.preciseLocation(in: self), color: liveTool.laserColor, now: CACurrentMediaTime())
        updateLaserRender()
    }

    private func laserMoved(_ touch: UITouch, event: UIEvent?) {
        let now = CACurrentMediaTime()
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            laserEngine.move(to: sample.preciseLocation(in: self), now: now)
        }
        updateLaserRender()
    }

    private func laserEnded() {
        laserEngine.end(now: CACurrentMediaTime())
        startLaserLoop()
        updateLaserRender()
    }

    private func startLaserLoop() {
        guard laserDisplayLink == nil else { return }
        let proxy = ScratchpadDisplayLinkProxy { [weak self] in self?.updateLaserRender() }
        let link = CADisplayLink(target: proxy, selector: #selector(ScratchpadDisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        laserDisplayLinkProxy = proxy
        laserDisplayLink = link
    }

    private func stopLaserLoop() {
        laserDisplayLink?.invalidate()
        laserDisplayLink = nil
        laserDisplayLinkProxy = nil
    }

    private func updateLaserRender() {
        let frame = laserEngine.frame(at: CACurrentMediaTime())
        laserFrame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame.isActive {
            laserGlowLayer.fillColor = frame.glowColor
            laserGlowLayer.shadowColor = frame.glowColor
            laserGlowLayer.opacity = frame.opacity
            laserGlowLayer.path = frame.glowPath
            laserCoreLayer.opacity = frame.opacity
            laserCoreLayer.path = frame.corePath
        } else {
            laserGlowLayer.path = nil
            laserCoreLayer.path = nil
            stopLaserLoop()
        }
        CATransaction.commit()
        emitLiveOverlay()
    }

    // MARK: Eraser

    private var eraserRadius: CGFloat { CGFloat(liveTool.eraserRadius) }

    private func eraseBegan(_ touch: UITouch) {
        let original = session.strokes(onPage: pageID)
        eraseOriginal = original
        eraseWorking = original
        let p = touch.preciseLocation(in: self)
        lastErasePoint = p
        if applyEraseStep(from: p, to: p) {
            renderCommitted(eraseWorking)
            onContentDidMutate?()
        }
        setEraserCursor(p)
    }

    private func eraseMoved(_ touch: UITouch, event: UIEvent?) {
        guard eraseOriginal != nil else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        let minStepSq: CGFloat = liveTool.eraserMode == .pixel ? 1.44 : 0.25
        var anyChanged = false
        for (idx, sample) in samples.enumerated() {
            let p = sample.preciseLocation(in: self)
            let prev = lastErasePoint ?? p
            let dx = p.x - prev.x
            let dy = p.y - prev.y
            let isLast = (idx == samples.count - 1)
            if !isLast && (dx * dx + dy * dy) < minStepSq {
                continue
            }
            if applyEraseStep(from: prev, to: p) {
                anyChanged = true
            }
            lastErasePoint = p
        }
        if anyChanged {
            renderCommitted(eraseWorking)
            onContentDidMutate?()
        }
        setEraserCursor(lastErasePoint)
    }

    private func eraseEnded() {
        defer {
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
            geometryCache.prune(keeping: Set(eraseWorking.map(\.id)))
        }
        guard let original = eraseOriginal else { return }
        if eraseWorking != original {
            session.replaceStrokes(onPage: pageID, before: original, after: eraseWorking)
            onContentDidMutate?()
        } else {
            syncCommittedStrokes()
        }
        session.didFinishEraseStroke()
    }

    private func applyEraseStep(from a: CGPoint, to b: CGPoint) -> Bool {
        let result = EraserEngine.erase(eraseWorking, from: a, to: b, radius: eraserRadius,
                                        mode: liveTool.eraserMode, highlighterOnly: false,
                                        cache: geometryCache)
        guard result.changed else { return false }
        eraseWorking = result.strokes
        return true
    }

    private func setEraserCursor(_ point: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let point {
            let r = eraserRadius
            eraserCursor.path = CGPath(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r),
                                       transform: nil)
            eraserCursor.isHidden = false
        } else {
            eraserCursor.isHidden = true
        }
        CATransaction.commit()
        emitLiveOverlay()
    }

    // MARK: Presentation Mirroring

    private func emitLiveOverlay() {
        var previewPending: [PendingOverlayStroke] = []
        if !lassoPreviewEntries.isEmpty {
            var transform = lassoPreviewTransform
            for entry in lassoPreviewEntries {
                let path = entry.basePath.copy(using: &transform) ?? entry.basePath
                let fill = entry.baseFillPath?.copy(using: &transform) ?? entry.baseFillPath
                previewPending.append(PendingOverlayStroke(
                    path: path, color: entry.strokeColor, opacity: entry.opacity,
                    isHighlighter: entry.isHighlighter, fillPath: fill, fillColor: entry.fillColor
                ))
            }
        }
        let overlay = ScratchpadLiveOverlay(
            strokePath: liveLayer.path,
            strokeColor: liveLayer.fillColor,
            strokeOpacity: liveLayer.opacity,
            fillPath: liveFillLayer.path,
            fillColor: liveFillLayer.fillColor,
            pendingStrokes: previewPending,
            cursorPath: eraserCursor.isHidden ? nil : eraserCursor.path,
            laserGlowPath: laserFrame.glowPath,
            laserCorePath: laserFrame.corePath,
            laserColor: laserFrame.glowColor,
            laserOpacity: laserFrame.opacity
        )
        onLiveOverlayChanged?(overlay.isEmpty ? nil : overlay)
    }
}

private final class ScratchpadDisplayLinkProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func tick() { handler() }
}
