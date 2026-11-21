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
        isHidden = (aid == .none && selectedShape == nil && activeSnapPoint == nil)
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
        if let selected = selectedShape {
            drawSelectedShape(selected, in: ctx)
        }
        if aid == .compass {
            drawCompass(in: ctx)
        }
        if let snap = activeSnapPoint {
            drawSnapIndicator(at: snap, kind: activeSnapKind, in: ctx)
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
