import UIKit

/// Renders the virtual Compass, selected shape edit handles/mini-bar, and magnetic snap indicators
/// on the iPad screen. Lives as a sibling above `WKWebView` (never inside the web view and never
/// mirrored in `LiveOverlayState`), so students on the external display only see crisp geometry.
final class GeometryToolOverlayView: UIView {
    var aid: GeometryAid = .none {
        didSet {
            updateVisibility()
            setNeedsDisplay()
        }
    }
    var compass = CompassState() {
        didSet { setNeedsDisplay() }
    }
    var protractor = ProtractorState() {
        didSet { setNeedsDisplay() }
    }
    /// Selected geometric shape for post-creation vertex editing & quick actions (iPad-only).
    var selectedShape: SelectedShapeOverlay? {
        didSet {
            updateVisibility()
            setNeedsDisplay()
        }
    }
    /// Hides the floating mini-bar while actively dragging a vertex/shape for an unobstructed view.
    var isEditingSelectedShape = false {
        didSet { setNeedsDisplay() }
    }
    /// Freehand lasso loop currently being drawn in view coordinates (iPad-only).
    var activeLassoPath: [CGPoint] = [] {
        didSet {
            updateVisibility()
            setNeedsDisplay()
        }
    }
    /// Active lasso multi-stroke selection box, corner handles & quick-action bar (iPad-only).
    var lassoSelection: LassoSelectionOverlay? {
        didSet {
            updateVisibility()
            setNeedsDisplay()
        }
    }
    /// Hides the lasso floating bar while actively moving or scaling the selection.
    var isTransformingLasso = false {
        didSet { setNeedsDisplay() }
    }
    /// Active sweep readout while drawing an arc with the compass.
    var activeCompassSweep: CompassSweep? {
        didSet { setNeedsDisplay() }
    }
    /// Live radius readout while resizing the compass.
    var isResizingCompass = false {
        didSet { setNeedsDisplay() }
    }
    /// Currently snapped target in view coordinates (rendered as an emerald crosshair).
    var activeSnapPoint: CGPoint? {
        didSet {
            updateVisibility()
            setNeedsDisplay()
        }
    }
    var activeSnapKind: SnapKind? {
        didSet { setNeedsDisplay() }
    }
    var activeStrokeColor: UIColor = .label {
        didSet { setNeedsDisplay() }
    }

    private func updateVisibility() {
        isHidden = (aid == .none
                    && selectedShape == nil
                    && activeSnapPoint == nil
                    && activeLassoPath.isEmpty
                    && lassoSelection == nil)
    }

    // Optional finger callbacks (in addition to primary one-handed Apple Pencil control).
    var onFingerTap: ((CGPoint) -> Void)?
    var onFingerPanBegan: ((CGPoint) -> Void)?
    var onFingerPanChanged: ((CGPoint) -> Void)?
    var onFingerPanEnded: ((CGPoint) -> Void)?

    private let fingerTap = UITapGestureRecognizer()
    private let fingerPan = UIPanGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isHidden = true

        let fingerTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        fingerTap.allowedTouchTypes = fingerTypes
        fingerTap.addTarget(self, action: #selector(handleFingerTap(_:)))
        addGestureRecognizer(fingerTap)

        fingerPan.allowedTouchTypes = fingerTypes
        fingerPan.maximumNumberOfTouches = 1
        fingerPan.addTarget(self, action: #selector(handleFingerPan(_:)))
        addGestureRecognizer(fingerPan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Returns `true` only on manipulative control handles/buttons so finger touches elsewhere
    /// fall straight through to `WKWebView` (scrolling, zooming, page buttons, cover tapes).
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let lasso = lassoSelection {
            switch lasso.hitTest(point, in: bounds, includeActionBar: !isTransformingLasso) {
            case .action, .handle, .body:
                return true
            case .none:
                break
            }
        }
        if let selected = selectedShape {
            switch selected.hitTest(point, in: bounds, bodyHit: false) {
            case .action, .handle:
                return true
            case .none, .body:
                break
            }
        }
        switch aid {
        case .none:
            return false
        case .compass:
            switch compass.hitTest(point, in: bounds) {
            case .needle, .resizeHandle, .lockButton, .centerMarkButton, .fullCircleButton:
                return true
            case .none, .drawCircle:
                return false
            }
        case .protractor:
            switch protractor.hitTest(point, in: bounds) {
            case .center, .ray1Handle, .ray2Handle, .ringRotate,
                 .autoDetectButton, .cycleAngleButton, .stampAngleButton, .closeButton:
                return true
            case .none:
                return false
            }
        }
    }

    @objc private func handleFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onFingerTap?(recognizer.location(in: self))
    }

    @objc private func handleFingerPan(_ recognizer: UIPanGestureRecognizer) {
        let p = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            onFingerPanBegan?(p)
        case .changed:
            onFingerPanChanged?(p)
        case .ended, .cancelled, .failed:
            onFingerPanEnded?(p)
        default:
            break
        }
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        if !activeLassoPath.isEmpty {
            drawActiveLassoPath(in: ctx)
        }
        if let lasso = lassoSelection {
            drawLassoSelection(lasso, in: ctx)
        }
        if let selected = selectedShape {
            drawSelectedShape(selected, in: ctx)
        }
        if aid == .compass {
            drawCompass(in: ctx)
        } else if aid == .protractor {
            drawProtractor(in: ctx)
        }
        if let snap = activeSnapPoint {
            drawSnapIndicator(at: snap, kind: activeSnapKind, in: ctx)
        }
    }

    private func drawActiveLassoPath(in ctx: CGContext) {
        guard activeLassoPath.count >= 2 else { return }
        ctx.saveGState()
        let path = UIBezierPath()
        path.move(to: activeLassoPath[0])
        for pt in activeLassoPath.dropFirst() {
            path.addLine(to: pt)
        }
        path.close()
        UIColor.systemBlue.withAlphaComponent(0.08).setFill()
        path.fill()

        ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.addPath(path.cgPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawLassoSelection(_ lasso: LassoSelectionOverlay, in ctx: CGContext) {
        let box = lasso.paddedBox
        if box.width > 0, box.height > 0 {
            ctx.saveGState()
            let rounded = UIBezierPath(roundedRect: box, cornerRadius: 6)
            UIColor.systemBlue.withAlphaComponent(isTransformingLasso ? 0.04 : 0.06).setFill()
            rounded.fill()

            ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.addPath(rounded.cgPath)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Four corner proportional-scale handles
        for (_, pt) in lasso.handlePositions() {
            let r: CGFloat = 7.5
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4,
                          color: UIColor.black.withAlphaComponent(0.22).cgColor)
            UIColor.white.setFill()
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()

            UIColor.systemBlue.setStroke()
            ctx.setLineWidth(2.2)
            ctx.strokeEllipse(in: rect)
        }

        guard !isTransformingLasso else { return }
        let bar = lasso.actionBarFrame(in: bounds)
        let buttons = lasso.actionButtons(in: bounds)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8,
                      color: UIColor.black.withAlphaComponent(0.18).cgColor)
        let bg = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        UIColor.systemBackground.withAlphaComponent(0.96).setFill()
        bg.fill()
        ctx.restoreGState()

        UIColor.separator.withAlphaComponent(0.6).setStroke()
        let border = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        border.lineWidth = 0.8
        border.stroke()

        let font = UIFont.systemFont(ofSize: 12.5, weight: .semibold)
        for (action, rect) in buttons {
            switch action {
            case let .color(idx):
                guard idx < ToolSettings.palette.count else { continue }
                let swatch = ToolSettings.palette[idx]
                let isSelected = (lasso.activeColor == swatch)
                let r: CGFloat = 8.5
                let dotRect = CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2)
                if isSelected {
                    let ring = dotRect.insetBy(dx: -3, dy: -3)
                    UIColor.label.withAlphaComponent(0.85).setStroke()
                    ctx.setLineWidth(1.6)
                    ctx.strokeEllipse(in: ring)
                }
                ctx.setFillColor(swatch.cgColor)
                ctx.fillEllipse(in: dotRect)
                UIColor.separator.withAlphaComponent(0.45).setStroke()
                ctx.setLineWidth(0.7)
                ctx.strokeEllipse(in: dotRect)

            case .duplicate:
                ctx.setStrokeColor(UIColor.separator.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: rect.minX, y: bar.minY + 7))
                ctx.addLine(to: CGPoint(x: rect.minX, y: bar.maxY - 7))
                ctx.strokePath()
                drawCenteredText("复制", in: rect, font: font, color: .label)

            case .delete:
                ctx.setStrokeColor(UIColor.separator.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: rect.minX, y: bar.minY + 7))
                ctx.addLine(to: CGPoint(x: rect.minX, y: bar.maxY - 7))
                ctx.strokePath()
                drawCenteredText("删除", in: rect, font: font, color: .systemRed)
            }
        }
    }

    private func drawSelectedShape(_ selected: SelectedShapeOverlay, in ctx: CGContext) {
        // Subtle dashed selection bounding frame
        let box = selected.boundingBox.insetBy(dx: -6, dy: -6)
        if box.width > 0, box.height > 0 {
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [4, 4])
            ctx.stroke(box)
            ctx.restoreGState()
        }

        // Crisp draggable vertex / control point handles
        for (idx, pt) in selected.handles.enumerated() {
            let r: CGFloat = (idx == 0 && selected.isCircularWithCenterMark) ? 8.5 : 8.0
            let rect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4,
                          color: UIColor.black.withAlphaComponent(0.22).cgColor)
            UIColor.white.setFill()
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()

            UIColor.systemBlue.setStroke()
            ctx.setLineWidth(2.2)
            ctx.strokeEllipse(in: rect)

            if idx == 0, selected.isCircularWithCenterMark {
                UIColor.systemBlue.setFill()
                ctx.fillEllipse(in: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5))
            }
        }

        guard !isEditingSelectedShape else { return }
        let bar = selected.actionBarFrame(in: bounds)
        let buttons = selected.actionButtons(in: bounds)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8,
                      color: UIColor.black.withAlphaComponent(0.18).cgColor)
        let bg = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        UIColor.systemBackground.withAlphaComponent(0.95).setFill()
        bg.fill()
        ctx.restoreGState()

        UIColor.separator.withAlphaComponent(0.6).setStroke()
        let border = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        border.lineWidth = 0.8
        border.stroke()

        let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        for (i, pair) in buttons.enumerated() {
            let (action, rect) = pair
            if i > 0 {
                ctx.setStrokeColor(UIColor.separator.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(0.8)
                ctx.move(to: CGPoint(x: rect.minX, y: bar.minY + 7))
                ctx.addLine(to: CGPoint(x: rect.minX, y: bar.maxY - 7))
                ctx.strokePath()
            }
            switch action {
            case .cycleLineStyle:
                let title = selected.lineStyle.displayName
                drawCenteredText(title, in: rect, font: font, color: .label)
            case .toggleFillOrCenter:
                let isActive = selected.supportsFill ? selected.isFilled : selected.showsCenterMark
                if isActive {
                    let pill = UIBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerRadius: 14)
                    UIColor.systemBlue.withAlphaComponent(0.18).setFill()
                    pill.fill()
                }
                let title = selected.supportsFill ? "阴影" : "⊙圆心"
                drawCenteredText(title, in: rect, font: font, color: isActive ? .systemBlue : .secondaryLabel)
            case .duplicate:
                drawCenteredText("复制", in: rect, font: font, color: .label)
            case .delete:
                drawCenteredText("删除", in: rect, font: font, color: .systemRed)
            }
        }
    }

    private func drawCompass(in ctx: CGContext) {
        let c = compass.center
        let r = compass.radius
        let foot = compass.penFoot
        let sweeping = activeCompassSweep != nil

        // 1. Faint dashed preview circle showing exact sweep track
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(sweeping ? 0.55 : 0.38).cgColor)
        ctx.setLineWidth(sweeping ? 1.4 : 1.1)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.restoreGState()

        // 2. Subtle radius spoke
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 4])
        ctx.move(to: c)
        ctx.addLine(to: foot)
        ctx.strokePath()
        ctx.restoreGState()

        // 3. Sleek two-legged drafting compass frame (needle leg + pencil leg meeting at top hinge)
        let mid = CGPoint(x: (c.x + foot.x) / 2, y: (c.y + foot.y) / 2)
        let dx = foot.x - c.x
        let dy = foot.y - c.y
        let len = max(1, hypot(dx, dy))
        // Pick the perpendicular direction pointing more "upward" (smaller y) so the hinge stays naturally upright.
        var nx = -dy / len
        var ny = dx / len
        if ny > 0 {
            nx = -nx
            ny = -ny
        }
        let legHeight = max(56, min(115, r * 0.72 + 26))
        let hinge = CGPoint(x: mid.x + nx * legHeight, y: mid.y + ny * legHeight)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6,
                      color: UIColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(UIColor.label.withAlphaComponent(0.52).cgColor)
        ctx.setLineWidth(4.0)
        ctx.move(to: c)
        ctx.addLine(to: hinge)
        ctx.addLine(to: foot)
        ctx.strokePath()

        // Inner metallic highlight
        ctx.setStrokeColor(UIColor.systemBackground.withAlphaComponent(0.82).cgColor)
        ctx.setLineWidth(1.6)
        ctx.move(to: c)
        ctx.addLine(to: hinge)
        ctx.addLine(to: foot)
        ctx.strokePath()
        ctx.restoreGState()

        // Hinge head dot
        let hingeRect = CGRect(x: hinge.x - 7, y: hinge.y - 7, width: 14, height: 14)
        UIColor.systemBackground.withAlphaComponent(0.95).setFill()
        ctx.fillEllipse(in: hingeRect)
        UIColor.label.withAlphaComponent(0.55).setStroke()
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: hingeRect)

        // 4. Needle Pin Handle at exact center O
        let needleR: CGFloat = 17
        let needleRect = CGRect(x: c.x - needleR, y: c.y - needleR, width: needleR * 2, height: needleR * 2)
        UIColor.systemBlue.withAlphaComponent(0.14).setFill()
        ctx.fillEllipse(in: needleRect)
        UIColor.systemBlue.withAlphaComponent(0.85).setStroke()
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: needleRect)

        // Center crosshair inside needle handle
        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: c.x - 6, y: c.y))
        ctx.addLine(to: CGPoint(x: c.x + 6, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 6))
        ctx.addLine(to: CGPoint(x: c.x, y: c.y + 6))
        ctx.strokePath()
        UIColor.systemBlue.setFill()
        ctx.fillEllipse(in: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5))

        // 5. Drawing pen foot tip on the circle
        let footRect = CGRect(x: foot.x - 7, y: foot.y - 7, width: 14, height: 14)
        activeStrokeColor.setFill()
        ctx.fillEllipse(in: footRect)
        UIColor.white.setStroke()
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: footRect)

        // 6. Radius resize handle (↔) on the exact opposite point of the circle (hidden while sweeping)
        if !sweeping {
            let h = compass.resizeHandleCenter
            let hr: CGFloat = 15
            let hRect = CGRect(x: h.x - hr, y: h.y - hr, width: hr * 2, height: hr * 2)
            if compass.isRadiusLocked {
                UIColor.secondarySystemBackground.withAlphaComponent(0.9).setFill()
                ctx.fillEllipse(in: hRect)
                UIColor.secondaryLabel.withAlphaComponent(0.45).setStroke()
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: hRect)
                drawCenteredText("🔒", in: hRect, font: .systemFont(ofSize: 12), color: .secondaryLabel)
            } else {
                UIColor.systemOrange.withAlphaComponent(0.18).setFill()
                ctx.fillEllipse(in: hRect)
                UIColor.systemOrange.withAlphaComponent(0.9).setStroke()
                ctx.setLineWidth(1.6)
                ctx.strokeEllipse(in: hRect)
                drawCenteredText("↔", in: hRect, font: .systemFont(ofSize: 15, weight: .bold), color: .systemOrange)
            }
        }

        // 7. Live angle / radius readout badge
        if let sweep = activeCompassSweep {
            let label = sweep.isFullCircle ? "360° 整圆" : "\(sweep.sweepDegrees)°"
            drawReadoutPill(label, centeredAt: CGPoint(x: c.x, y: c.y - 34), in: ctx)
        } else if isResizingCompass {
            let label = "r = \(Int(r.rounded()))"
            drawReadoutPill(label, centeredAt: CGPoint(x: c.x, y: c.y - 34), in: ctx)
        }

        // 8. Compact floating action bar (🔒 锁半径 | ⊙ 圆心 | ○ 整圆)
        drawCompassActionBar(in: ctx)
    }

    private func drawCompassActionBar(in ctx: CGContext) {
        let bar = compass.actionBarFrame(in: bounds)
        let buttons = compass.buttonFrames(in: bounds)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8,
                      color: UIColor.black.withAlphaComponent(0.18).cgColor)
        let bgPath = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        UIColor.systemBackground.withAlphaComponent(0.94).setFill()
        bgPath.fill()
        ctx.restoreGState()

        UIColor.separator.withAlphaComponent(0.6).setStroke()
        let border = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        border.lineWidth = 0.8
        border.stroke()

        // Active segment highlights
        if compass.isRadiusLocked {
            let pill = UIBezierPath(roundedRect: buttons.lock.insetBy(dx: 3, dy: 3), cornerRadius: 14)
            UIColor.systemBlue.withAlphaComponent(0.18).setFill()
            pill.fill()
        }
        if compass.showCenterMark {
            let pill = UIBezierPath(roundedRect: buttons.centerMark.insetBy(dx: 3, dy: 3), cornerRadius: 14)
            UIColor.systemBlue.withAlphaComponent(0.18).setFill()
            pill.fill()
        }

        // Dividers
        ctx.setStrokeColor(UIColor.separator.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.8)
        for divX in [buttons.lock.maxX, buttons.centerMark.maxX] {
            ctx.move(to: CGPoint(x: divX, y: bar.minY + 7))
            ctx.addLine(to: CGPoint(x: divX, y: bar.maxY - 7))
        }
        ctx.strokePath()

        let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        drawCenteredText(compass.isRadiusLocked ? "🔒已锁" : "🔓锁半径", in: buttons.lock, font: font,
                         color: compass.isRadiusLocked ? .systemBlue : .label)
        drawCenteredText("⊙圆心", in: buttons.centerMark, font: font,
                         color: compass.showCenterMark ? .systemBlue : .secondaryLabel)
        drawCenteredText("○整圆", in: buttons.fullCircle, font: font, color: .systemBlue)
    }

    private func drawProtractor(in ctx: CGContext) {
        let c = protractor.center
        let r = protractor.radius
        let sweep = protractor.sweep
        let accent: UIColor = protractor.isRightAngle ? .systemGreen : .systemBlue
        let dialRect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)

        // 1. Translucent frosted circular dial so printed diagrams underneath remain clearly legible.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 10,
                      color: UIColor.black.withAlphaComponent(0.14).cgColor)
        UIColor.systemBackground.withAlphaComponent(0.68).setFill()
        ctx.fillEllipse(in: dialRect)
        ctx.restoreGState()

        // Outer dial ring border
        ctx.saveGState()
        UIColor.label.withAlphaComponent(0.24).setStroke()
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: dialRect)

        // Inner ring guide
        let innerGuideR = r * 0.72
        UIColor.label.withAlphaComponent(0.10).setStroke()
        ctx.setLineWidth(0.8)
        ctx.strokeEllipse(in: CGRect(x: c.x - innerGuideR, y: c.y - innerGuideR,
                                     width: innerGuideR * 2, height: innerGuideR * 2))
        ctx.restoreGState()

        // 2. Highlighted measured angle sector (wedge) between Ray 1 and Ray 2.
        if sweep.magnitudeRadians > 0.005 {
            let wedge = UIBezierPath()
            wedge.move(to: c)
            wedge.addArc(withCenter: c, radius: r,
                         startAngle: sweep.startAngle, endAngle: sweep.endAngle,
                         clockwise: sweep.clockwise)
            wedge.close()
            accent.withAlphaComponent(0.14).setFill()
            wedge.fill()

            // Crisp colored rim arc along the measured sweep
            let rimArc = UIBezierPath(arcCenter: c, radius: r,
                                      startAngle: sweep.startAngle, endAngle: sweep.endAngle,
                                      clockwise: sweep.clockwise)
            accent.withAlphaComponent(0.88).setStroke()
            rimArc.lineWidth = 3.0
            rimArc.lineCapStyle = .round
            rimArc.stroke()

            // Inner right-angle square `∟` or inner angle arc
            if protractor.isRightAngle {
                let side: CGFloat = 24
                let u1 = CGPoint(x: cos(protractor.ray1Angle), y: sin(protractor.ray1Angle))
                let u2 = CGPoint(x: cos(protractor.ray2Angle), y: sin(protractor.ray2Angle))
                let p1 = CGPoint(x: c.x + side * u1.x, y: c.y + side * u1.y)
                let pCorner = CGPoint(x: c.x + side * (u1.x + u2.x), y: c.y + side * (u1.y + u2.y))
                let p2 = CGPoint(x: c.x + side * u2.x, y: c.y + side * u2.y)
                ctx.saveGState()
                accent.setStroke()
                ctx.setLineWidth(2.0)
                ctx.setLineJoin(.miter)
                ctx.move(to: p1)
                ctx.addLine(to: pCorner)
                ctx.addLine(to: p2)
                ctx.strokePath()
                ctx.restoreGState()
            } else {
                let innerR: CGFloat = 34
                let innerArc = UIBezierPath(arcCenter: c, radius: innerR,
                                            startAngle: sweep.startAngle, endAngle: sweep.endAngle,
                                            clockwise: sweep.clockwise)
                accent.withAlphaComponent(0.75).setStroke()
                innerArc.lineWidth = 1.8
                innerArc.stroke()
            }
        }

        // 3. Precision degree ticks anchored at Ray 1 = 0° in the active sweep direction.
        let tickDir: CGFloat = sweep.clockwise ? 1 : -1
        ctx.saveGState()
        let tickFont = UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        for deg in stride(from: 0, to: 360, by: 5) {
            let theta = protractor.ray1Angle + tickDir * CGFloat(deg) * .pi / 180
            let cosT = cos(theta)
            let sinT = sin(theta)
            let isMajor30 = (deg % 30 == 0)
            let isMajor10 = (deg % 10 == 0)
            let tickLen: CGFloat = isMajor30 ? 11 : (isMajor10 ? 7.5 : 4)
            let alpha: CGFloat = isMajor30 ? 0.55 : (isMajor10 ? 0.35 : 0.20)
            ctx.setStrokeColor(UIColor.label.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(isMajor30 ? 1.3 : 0.8)
            ctx.move(to: CGPoint(x: c.x + (r - tickLen) * cosT, y: c.y + (r - tickLen) * sinT))
            ctx.addLine(to: CGPoint(x: c.x + r * cosT, y: c.y + r * sinT))
            ctx.strokePath()

            if isMajor30 && deg <= 180 {
                let labelR = r - 22
                let lp = CGPoint(x: c.x + labelR * cosT, y: c.y + labelR * sinT)
                let rect = CGRect(x: lp.x - 16, y: lp.y - 7, width: 32, height: 14)
                drawCenteredText("\(deg)°", in: rect, font: tickFont,
                                 color: UIColor.secondaryLabel.withAlphaComponent(0.85))
            }
        }
        ctx.restoreGState()

        // 4. Extended laser sightlines + solid measuring arms (Ray 1 = Blue, Ray 2 = Orange).
        drawProtractorRay(angle: protractor.ray1Angle, color: .systemBlue, handleCenter: protractor.ray1HandleCenter, in: ctx)
        drawProtractorRay(angle: protractor.ray2Angle, color: .systemOrange, handleCenter: protractor.ray2HandleCenter, in: ctx)

        // 5. Precision vertex crosshair O (hollow center pinhole so exact printed corner remains visible).
        let centerR: CGFloat = 16
        let centerRect = CGRect(x: c.x - centerR, y: c.y - centerR, width: centerR * 2, height: centerR * 2)
        UIColor.systemBlue.withAlphaComponent(0.12).setFill()
        ctx.fillEllipse(in: centerRect)
        UIColor.systemBlue.withAlphaComponent(0.85).setStroke()
        ctx.setLineWidth(1.6)
        ctx.strokeEllipse(in: centerRect)

        ctx.saveGState()
        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(1.2)
        // Broken crosshair leaving a clear 4px pinhole right over the vertex
        ctx.move(to: CGPoint(x: c.x - 10, y: c.y)); ctx.addLine(to: CGPoint(x: c.x - 3, y: c.y))
        ctx.move(to: CGPoint(x: c.x + 3, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 10, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - 10)); ctx.addLine(to: CGPoint(x: c.x, y: c.y - 3))
        ctx.move(to: CGPoint(x: c.x, y: c.y + 3)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 10))
        ctx.strokePath()
        ctx.restoreGState()

        // 6. Giant high-contrast automatic digital degree readout badge (no squinting at ticks!).
        let bisector = sweep.bisectorAngle
        let badgeDist = r * 0.54
        let rawBadgeCenter = CGPoint(x: c.x + badgeDist * cos(bisector), y: c.y + badgeDist * sin(bisector))
        let badgeCenter = CGPoint(
            x: min(max(44, rawBadgeCenter.x), max(44, bounds.width - 44)),
            y: min(max(24, rawBadgeCenter.y), max(24, bounds.height - 24))
        )
        let prefix = protractor.autoDetectedSource != nil ? "⚡ " : ""
        let readoutText = "\(prefix)\(protractor.formattedDegrees)"
        drawLargeAngleReadoutPill(readoutText, centeredAt: badgeCenter, accent: accent, in: ctx)

        // 7. Compact floating action bar (⚡识别 | ↻换角 | ∠标角 | ✕)
        drawProtractorActionBar(in: ctx)
    }

    private func drawProtractorRay(angle: CGFloat, color: UIColor, handleCenter: CGPoint, in ctx: CGContext) {
        let c = protractor.center
        let r = protractor.radius
        let cosA = cos(angle)
        let sinA = sin(angle)
        let extPoint = CGPoint(x: c.x + (r + 88) * cosA, y: c.y + (r + 88) * sinA)

        // Extended dashed laser sightline beyond the dial rim for effortless printed-edge alignment.
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.move(to: handleCenter)
        ctx.addLine(to: extPoint)
        ctx.strokePath()
        ctx.restoreGState()

        // Crisp solid measuring ray from vertex O to handle
        ctx.saveGState()
        ctx.setStrokeColor(color.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(2.2)
        ctx.setLineCap(.round)
        ctx.move(to: c)
        ctx.addLine(to: handleCenter)
        ctx.strokePath()
        ctx.restoreGState()

        // Draggable handle knob
        let hr: CGFloat = 13.5
        let hRect = CGRect(x: handleCenter.x - hr, y: handleCenter.y - hr, width: hr * 2, height: hr * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 4,
                      color: UIColor.black.withAlphaComponent(0.22).cgColor)
        UIColor.systemBackground.withAlphaComponent(0.96).setFill()
        ctx.fillEllipse(in: hRect)
        ctx.restoreGState()

        color.setStroke()
        ctx.setLineWidth(2.4)
        ctx.strokeEllipse(in: hRect)

        color.setFill()
        ctx.fillEllipse(in: CGRect(x: handleCenter.x - 3.5, y: handleCenter.y - 3.5, width: 7, height: 7))
    }

    private func drawLargeAngleReadoutPill(_ text: String, centeredAt center: CGPoint, accent: UIColor, in ctx: CGContext) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let rect = CGRect(x: center.x - size.width / 2 - 12, y: center.y - size.height / 2 - 5,
                          width: size.width + 24, height: size.height + 10)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 7,
                      color: UIColor.black.withAlphaComponent(0.24).cgColor)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        accent.withAlphaComponent(0.95).setFill()
        path.fill()
        ctx.restoreGState()

        UIColor.white.withAlphaComponent(0.55).setStroke()
        let border = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        border.lineWidth = 1.0
        border.stroke()

        drawCenteredText(text, in: rect, font: font, color: .white)
    }

    private func drawProtractorActionBar(in ctx: CGContext) {
        let bar = protractor.actionBarFrame(in: bounds)
        let buttons = protractor.buttonFrames(in: bounds)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8,
                      color: UIColor.black.withAlphaComponent(0.18).cgColor)
        let bgPath = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        UIColor.systemBackground.withAlphaComponent(0.95).setFill()
        bgPath.fill()
        ctx.restoreGState()

        UIColor.separator.withAlphaComponent(0.6).setStroke()
        let border = UIBezierPath(roundedRect: bar, cornerRadius: bar.height / 2)
        border.lineWidth = 0.8
        border.stroke()

        if protractor.autoDetectedSource != nil {
            let pill = UIBezierPath(roundedRect: buttons.autoDetect.insetBy(dx: 3, dy: 3), cornerRadius: 14)
            UIColor.systemGreen.withAlphaComponent(0.18).setFill()
            pill.fill()
        }
        if protractor.measureReflex {
            let pill = UIBezierPath(roundedRect: buttons.cycleAngle.insetBy(dx: 3, dy: 3), cornerRadius: 14)
            UIColor.systemBlue.withAlphaComponent(0.18).setFill()
            pill.fill()
        }

        ctx.setStrokeColor(UIColor.separator.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(0.8)
        for divX in [buttons.autoDetect.maxX, buttons.cycleAngle.maxX, buttons.stampAngle.maxX] {
            ctx.move(to: CGPoint(x: divX, y: bar.minY + 7))
            ctx.addLine(to: CGPoint(x: divX, y: bar.maxY - 7))
        }
        ctx.strokePath()

        let font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        drawCenteredText("⚡识别", in: buttons.autoDetect, font: font,
                         color: protractor.autoDetectedSource != nil ? .systemGreen : .label)
        let cycleTitle: String
        if protractor.detectedRayAngles.count >= 3 {
            cycleTitle = "↻邻角"
        } else {
            cycleTitle = protractor.measureReflex ? "↻劣角" : "↻优角"
        }
        drawCenteredText(cycleTitle, in: buttons.cycleAngle, font: font,
                         color: protractor.measureReflex ? .systemBlue : .label)
        drawCenteredText("∠标角", in: buttons.stampAngle, font: font, color: .systemBlue)
        drawCenteredText("✕", in: buttons.close, font: .systemFont(ofSize: 13, weight: .bold), color: .secondaryLabel)
    }

    private func drawSnapIndicator(at point: CGPoint, kind: SnapKind?, in ctx: CGContext) {
        let color = UIColor.systemGreen
        let r: CGFloat = 10
        ctx.saveGState()
        color.withAlphaComponent(0.22).setFill()
        ctx.fillEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        color.setStroke()
        ctx.setLineWidth(2.0)
        ctx.strokeEllipse(in: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2))
        ctx.setLineWidth(1.3)
        ctx.move(to: CGPoint(x: point.x - 14, y: point.y))
        ctx.addLine(to: CGPoint(x: point.x + 14, y: point.y))
        ctx.move(to: CGPoint(x: point.x, y: point.y - 14))
        ctx.addLine(to: CGPoint(x: point.x, y: point.y + 14))
        ctx.strokePath()

        let label: String
        switch kind {
        case .intersection: label = "交点"
        case .center: label = "圆心"
        case .midpoint: label = "中点"
        case .endpoint, .none: label = "端点"
        }
        drawReadoutPill(label, centeredAt: CGPoint(x: point.x, y: point.y - 24), in: ctx, accent: color)
        ctx.restoreGState()
    }

    private func drawReadoutPill(_ text: String, centeredAt center: CGPoint, in ctx: CGContext,
                                 accent: UIColor = .systemBlue) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let rect = CGRect(x: center.x - size.width / 2 - 8, y: center.y - size.height / 2 - 3,
                          width: size.width + 16, height: size.height + 6)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2)
        accent.withAlphaComponent(0.92).setFill()
        path.fill()
        drawCenteredText(text, in: rect, font: font, color: .white)
    }

    private func drawCenteredText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        let drawPoint = CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        (text as NSString).draw(at: drawPoint, withAttributes: attrs)
    }
}
