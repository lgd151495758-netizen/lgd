import UIKit

/// Floating movable & resizable math sticky-note window (`便签`).
///
/// - Drag the top sticky-note header bar (with Apple Pencil or finger) to place it anywhere over the page.
/// - Drag either bottom corner grip (`⌟` / `⌞`) to resize width and height freely.
/// - Only `canvas.renderCleanImage(size:)` is projected to students — the header bar and corner
///   resize grips stay strictly on the iPad.
final class ScratchpadPanelView: UIView, UIGestureRecognizerDelegate {
    static let headerHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 14

    let canvas: ScratchpadCanvasView
    private let session: DocumentSession

    /// Fired incrementally in superview coordinates while dragging the header bar.
    var onMoveDelta: ((CGPoint) -> Void)?
    /// Fired incrementally while dragging the bottom-right corner resize grip.
    var onResizeBottomRight: ((CGPoint) -> Void)?
    /// Fired incrementally while dragging the bottom-left corner resize grip.
    var onResizeBottomLeft: ((CGPoint) -> Void)?
    /// Fired when a drag or resize finishes so the final frame can be persisted.
    var onFrameInteractionEnded: (() -> Void)?

    private let cardContainer = UIView()
    private let headerBar = UIView()
    private let headerDivider = UIView()
    private let gripView = UIView()
    private let paperMenuButton = UIButton(type: .system)
    private let prevPageButton = UIButton(type: .system)
    private let pageLabel = UILabel()
    private let nextPageButton = UIButton(type: .system)
    private let addPageButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let expandButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let bottomRightGrip = CornerResizeGripView(corner: .bottomRight)
    private let bottomLeftGrip = CornerResizeGripView(corner: .bottomLeft)

    private var lastMoveLocation: CGPoint = .zero
    private var lastResizeRightLocation: CGPoint = .zero
    private var lastResizeLeftLocation: CGPoint = .zero

    init(session: DocumentSession) {
        self.session = session
        self.canvas = ScratchpadCanvasView(session: session)
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false

        setupCardContainer()
        setupHeaderBar()
        setupCanvas()
        setupResizeGrips()
        refreshHeaderState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupCardContainer() {
        cardContainer.backgroundColor = .white
        cardContainer.clipsToBounds = true
        cardContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardContainer)
        NSLayoutConstraint.activate([
            cardContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardContainer.topAnchor.constraint(equalTo: topAnchor),
            cardContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupHeaderBar() {
        // Warm sticky-note header tint so it visually reads as a movable note card above the HTML page.
        headerBar.backgroundColor = UIColor(red: 0.99, green: 0.95, blue: 0.83, alpha: 1.0)
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(headerBar)

        headerDivider.backgroundColor = UIColor(red: 0.86, green: 0.78, blue: 0.56, alpha: 0.7)
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(headerDivider)

        gripView.backgroundColor = UIColor(red: 0.58, green: 0.50, blue: 0.34, alpha: 0.45)
        gripView.layer.cornerRadius = 2
        gripView.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(gripView)

        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMovePan(_:)))
        movePan.delegate = self
        headerBar.addGestureRecognizer(movePan)

        // Left: Compact paper style menu button (fits even when sticky note is resized narrow).
        paperMenuButton.showsMenuAsPrimaryAction = true
        paperMenuButton.titleLabel?.font = .systemFont(ofSize: 12.5, weight: .semibold)
        paperMenuButton.tintColor = UIColor(red: 0.32, green: 0.26, blue: 0.14, alpha: 1.0)
        paperMenuButton.contentEdgeInsets = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        paperMenuButton.backgroundColor = UIColor.black.withAlphaComponent(0.06)
        paperMenuButton.layer.cornerRadius = 7

        // Right: Compact icon buttons for paging, clear, full-screen toggle, and close.
        let iconTint = UIColor(red: 0.30, green: 0.25, blue: 0.14, alpha: 1.0)
        let smallConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

        prevPageButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: smallConfig), for: .normal)
        prevPageButton.tintColor = iconTint
        prevPageButton.addTarget(self, action: #selector(prevPage), for: .touchUpInside)

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        pageLabel.textAlignment = .center
        pageLabel.textColor = iconTint

        nextPageButton.setImage(UIImage(systemName: "chevron.right", withConfiguration: smallConfig), for: .normal)
        nextPageButton.tintColor = iconTint
        nextPageButton.addTarget(self, action: #selector(nextPage), for: .touchUpInside)

        addPageButton.setImage(UIImage(systemName: "plus.circle.fill", withConfiguration: smallConfig), for: .normal)
        addPageButton.tintColor = .systemBlue
        addPageButton.accessibilityLabel = "新增便签页"
        addPageButton.addTarget(self, action: #selector(addPage), for: .touchUpInside)

        clearButton.setImage(UIImage(systemName: "trash", withConfiguration: smallConfig), for: .normal)
        clearButton.tintColor = .systemRed
        clearButton.accessibilityLabel = "清空本页"
        clearButton.addTarget(self, action: #selector(clearPage), for: .touchUpInside)

        expandButton.tintColor = iconTint
        expandButton.accessibilityLabel = "切换满屏或悬浮便签"
        expandButton.addTarget(self, action: #selector(toggleFullMode), for: .touchUpInside)

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: smallConfig), for: .normal)
        closeButton.tintColor = UIColor(red: 0.45, green: 0.40, blue: 0.30, alpha: 0.85)
        closeButton.accessibilityLabel = "收起便签"
        closeButton.addTarget(self, action: #selector(closeStickyNote), for: .touchUpInside)

        let rightStack = UIStackView(arrangedSubviews: [
            prevPageButton, pageLabel, nextPageButton, addPageButton, clearButton, expandButton, closeButton,
        ])
        rightStack.axis = .horizontal
        rightStack.spacing = 6
        rightStack.alignment = .center
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        paperMenuButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(paperMenuButton)
        headerBar.addSubview(rightStack)

        NSLayoutConstraint.activate([
            headerBar.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            headerBar.topAnchor.constraint(equalTo: cardContainer.topAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            headerDivider.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            headerDivider.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 0.6),

            gripView.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
            gripView.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 4),
            gripView.widthAnchor.constraint(equalToConstant: 32),
            gripView.heightAnchor.constraint(equalToConstant: 3.5),

            paperMenuButton.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 8),
            paperMenuButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor, constant: 1),

            rightStack.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor, constant: 1),
        ])
    }

    private func setupCanvas() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
        ])
    }

    private func setupResizeGrips() {
        bottomRightGrip.translatesAutoresizingMaskIntoConstraints = false
        bottomLeftGrip.translatesAutoresizingMaskIntoConstraints = false
        cardContainer.addSubview(bottomRightGrip)
        cardContainer.addSubview(bottomLeftGrip)

        let rightPan = UIPanGestureRecognizer(target: self, action: #selector(handleResizeRightPan(_:)))
        bottomRightGrip.addGestureRecognizer(rightPan)

        let leftPan = UIPanGestureRecognizer(target: self, action: #selector(handleResizeLeftPan(_:)))
        bottomLeftGrip.addGestureRecognizer(leftPan)

        NSLayoutConstraint.activate([
            bottomRightGrip.trailingAnchor.constraint(equalTo: cardContainer.trailingAnchor),
            bottomRightGrip.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
            bottomRightGrip.widthAnchor.constraint(equalToConstant: 32),
            bottomRightGrip.heightAnchor.constraint(equalToConstant: 32),

            bottomLeftGrip.leadingAnchor.constraint(equalTo: cardContainer.leadingAnchor),
            bottomLeftGrip.bottomAnchor.constraint(equalTo: cardContainer.bottomAnchor),
            bottomLeftGrip.widthAnchor.constraint(equalToConstant: 32),
            bottomLeftGrip.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    func refreshHeaderState() {
        let isFull = session.scratchpadSplitMode == .full
        let smallConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        let iconName = isFull ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        expandButton.setImage(UIImage(systemName: iconName, withConfiguration: smallConfig), for: .normal)

        gripView.isHidden = isFull
        bottomRightGrip.isHidden = isFull
        bottomLeftGrip.isHidden = isFull

        // Rounded floating card appearance vs edge-to-edge full-screen whiteboard.
        if isFull {
            cardContainer.layer.cornerRadius = 0
            cardContainer.layer.borderWidth = 0
            layer.shadowOpacity = 0
        } else {
            cardContainer.layer.cornerRadius = Self.cornerRadius
            cardContainer.layer.borderWidth = 0.8
            cardContainer.layer.borderColor = UIColor(red: 0.78, green: 0.70, blue: 0.52, alpha: 0.75).cgColor
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOffset = CGSize(width: 0, height: 6)
            layer.shadowRadius = 16
            layer.shadowOpacity = 0.20
        }

        // Paper style button & menu
        paperMenuButton.setTitle("\(session.scratchpadPaper.displayName) ▾", for: .normal)
        let actions = ScratchpadPaperStyle.allCases.map { style in
            UIAction(title: style.displayName,
                     state: style == session.scratchpadPaper ? .on : .off) { [weak self] _ in
                self?.session.scratchpadPaper = style
            }
        }
        paperMenuButton.menu = UIMenu(children: actions)
        canvas.paperStyle = session.scratchpadPaper

        let current = session.scratchpadPageIndex + 1
        let total = max(1, session.scratchpadPageCount)
        pageLabel.text = "\(current)/\(total)"
        prevPageButton.isEnabled = session.scratchpadPageIndex > 0
        nextPageButton.isEnabled = session.scratchpadPageIndex < total - 1
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let current = view, current !== headerBar {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    @objc private func handleMovePan(_ recognizer: UIPanGestureRecognizer) {
        guard session.scratchpadSplitMode == .floating, let superview else { return }
        let loc = recognizer.location(in: superview)
        switch recognizer.state {
        case .began:
            lastMoveLocation = loc
        case .changed:
            let delta = CGPoint(x: loc.x - lastMoveLocation.x, y: loc.y - lastMoveLocation.y)
            lastMoveLocation = loc
            onMoveDelta?(delta)
        case .ended, .cancelled, .failed:
            onFrameInteractionEnded?()
        default:
            break
        }
    }

    @objc private func handleResizeRightPan(_ recognizer: UIPanGestureRecognizer) {
        guard session.scratchpadSplitMode == .floating, let superview else { return }
        let loc = recognizer.location(in: superview)
        switch recognizer.state {
        case .began:
            lastResizeRightLocation = loc
        case .changed:
            let delta = CGPoint(x: loc.x - lastResizeRightLocation.x, y: loc.y - lastResizeRightLocation.y)
            lastResizeRightLocation = loc
            onResizeBottomRight?(delta)
        case .ended, .cancelled, .failed:
            onFrameInteractionEnded?()
        default:
            break
        }
    }

    @objc private func handleResizeLeftPan(_ recognizer: UIPanGestureRecognizer) {
        guard session.scratchpadSplitMode == .floating, let superview else { return }
        let loc = recognizer.location(in: superview)
        switch recognizer.state {
        case .began:
            lastResizeLeftLocation = loc
        case .changed:
            let delta = CGPoint(x: loc.x - lastResizeLeftLocation.x, y: loc.y - lastResizeLeftLocation.y)
            lastResizeLeftLocation = loc
            onResizeBottomLeft?(delta)
        case .ended, .cancelled, .failed:
            onFrameInteractionEnded?()
        default:
            break
        }
    }

    // MARK: Header Actions

    @objc private func toggleFullMode() {
        session.toggleScratchpadSplitMode()
    }

    @objc private func prevPage() {
        session.selectScratchpadPage(session.scratchpadPageIndex - 1)
    }

    @objc private func nextPage() {
        session.selectScratchpadPage(session.scratchpadPageIndex + 1)
    }

    @objc private func addPage() {
        session.addScratchpadPage()
    }

    @objc private func clearPage() {
        session.clearCurrentScratchpadPage()
    }

    @objc private func closeStickyNote() {
        session.isScratchpadOpen = false
    }
}

/// Subtle diagonal corner grip indicator for freely resizing the floating sticky note (iPad-only).
private final class CornerResizeGripView: UIView {
    enum Corner {
        case bottomRight
        case bottomLeft
    }

    private let corner: Corner

    init(corner: Corner) {
        self.corner = corner
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.saveGState()
        ctx.setStrokeColor(UIColor(red: 0.45, green: 0.40, blue: 0.30, alpha: 0.55).cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)

        let w = bounds.width
        let h = bounds.height
        switch corner {
        case .bottomRight:
            for offset in [CGFloat(7), CGFloat(13)] {
                ctx.move(to: CGPoint(x: w - offset, y: h - 5))
                ctx.addLine(to: CGPoint(x: w - 5, y: h - offset))
            }
        case .bottomLeft:
            for offset in [CGFloat(7), CGFloat(13)] {
                ctx.move(to: CGPoint(x: offset, y: h - 5))
                ctx.addLine(to: CGPoint(x: 5, y: h - offset))
            }
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
