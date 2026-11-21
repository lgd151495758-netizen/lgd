import UIKit

/// Hosts the iPad-only Scratchpad header bar (split resize handle, paper style, multi-page controls,
/// clear, full/split toggle, close) above `ScratchpadCanvasView`.
/// Only `canvas.renderCleanImage(size:)` is projected to the external display — the header bar never appears to students.
final class ScratchpadPanelView: UIView, UIGestureRecognizerDelegate {
    static let headerHeight: CGFloat = 40

    let canvas: ScratchpadCanvasView
    private let session: DocumentSession

    /// Called while the user drags the top header bar in Split Mode to resize the panel vertically.
    var onSplitDragDelta: ((CGFloat) -> Void)?

    private let headerBar = UIView()
    private let topDivider = UIView()
    private let gripView = UIView()
    private let splitModeButton = UIButton(type: .system)
    private let paperControl = UISegmentedControl(items: ScratchpadPaperStyle.allCases.map(\.displayName))
    private let prevPageButton = UIButton(type: .system)
    private let pageLabel = UILabel()
    private let nextPageButton = UIButton(type: .system)
    private let addPageButton = UIButton(type: .system)
    private let clearButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)

    private var lastPanY: CGFloat = 0

    init(session: DocumentSession) {
        self.session = session
        self.canvas = ScratchpadCanvasView(session: session)
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        clipsToBounds = false

        // Subtle upward elevation shadow so Split Mode separates crisply from the HTML problem above.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: -2)
        layer.shadowRadius = 10
        layer.shadowOpacity = 0.14

        setupHeaderBar()
        setupCanvas()
        refreshHeaderState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupHeaderBar() {
        headerBar.backgroundColor = .secondarySystemBackground
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerBar)

        topDivider.backgroundColor = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(topDivider)

        gripView.backgroundColor = UIColor.tertiaryLabel.withAlphaComponent(0.7)
        gripView.layer.cornerRadius = 2
        gripView.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(gripView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHeaderPan(_:)))
        pan.delegate = self
        headerBar.addGestureRecognizer(pan)

        // Left: Half/Full screen toggle
        splitModeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
        splitModeButton.addTarget(self, action: #selector(toggleSplitMode), for: .touchUpInside)

        // Center: Paper style selector
        paperControl.selectedSegmentIndex = ScratchpadPaperStyle.allCases.firstIndex(of: session.scratchpadPaper) ?? 1
        paperControl.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 12, weight: .medium)], for: .normal)
        paperControl.addTarget(self, action: #selector(paperChanged), for: .valueChanged)

        // Right: Page navigation + Clear + Close
        prevPageButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        prevPageButton.addTarget(self, action: #selector(prevPage), for: .touchUpInside)

        pageLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        pageLabel.textAlignment = .center
        pageLabel.textColor = .label

        nextPageButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        nextPageButton.addTarget(self, action: #selector(nextPage), for: .touchUpInside)

        addPageButton.setImage(UIImage(systemName: "plus.circle.fill"), for: .normal)
        addPageButton.accessibilityLabel = "新增草稿页"
        addPageButton.addTarget(self, action: #selector(addPage), for: .touchUpInside)

        clearButton.setTitle("清空", for: .normal)
        clearButton.setTitleColor(.systemRed, for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        clearButton.addTarget(self, action: #selector(clearPage), for: .touchUpInside)

        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.accessibilityLabel = "收起草稿板"
        closeButton.addTarget(self, action: #selector(closeScratchpad), for: .touchUpInside)

        let leftStack = UIStackView(arrangedSubviews: [splitModeButton])
        leftStack.spacing = 8
        leftStack.alignment = .center

        let rightStack = UIStackView(arrangedSubviews: [
            prevPageButton, pageLabel, nextPageButton, addPageButton, clearButton, closeButton,
        ])
        rightStack.spacing = 8
        rightStack.alignment = .center

        let container = UIStackView(arrangedSubviews: [leftStack, paperControl, rightStack])
        container.axis = .horizontal
        container.alignment = .center
        container.distribution = .equalSpacing
        container.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addSubview(container)

        NSLayoutConstraint.activate([
            headerBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerBar.topAnchor.constraint(equalTo: topAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            topDivider.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: headerBar.topAnchor),
            topDivider.heightAnchor.constraint(equalToConstant: 0.5),

            gripView.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
            gripView.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 4),
            gripView.widthAnchor.constraint(equalToConstant: 36),
            gripView.heightAnchor.constraint(equalToConstant: 4),

            paperControl.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            paperControl.heightAnchor.constraint(equalToConstant: 26),

            container.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 12),
            container.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -12),
            container.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor, constant: 2),
        ])
    }

    private func setupCanvas() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func refreshHeaderState() {
        let isFull = session.scratchpadSplitMode == .full
        let iconName = isFull ? "rectangle.split.1x2" : "arrow.up.left.and.arrow.down.right"
        let title = isFull ? " 半屏" : " 全屏"
        splitModeButton.setImage(UIImage(systemName: iconName), for: .normal)
        splitModeButton.setTitle(title, for: .normal)
        gripView.isHidden = isFull

        let idx = ScratchpadPaperStyle.allCases.firstIndex(of: session.scratchpadPaper) ?? 1
        if paperControl.selectedSegmentIndex != idx {
            paperControl.selectedSegmentIndex = idx
        }
        canvas.paperStyle = session.scratchpadPaper

        let current = session.scratchpadPageIndex + 1
        let total = max(1, session.scratchpadPageCount)
        pageLabel.text = "\(current)/\(total)"
        prevPageButton.isEnabled = session.scratchpadPageIndex > 0
        nextPageButton.isEnabled = session.scratchpadPageIndex < total - 1
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view: UIView? = touch.view
        while let current = view, current !== headerBar {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    @objc private func handleHeaderPan(_ recognizer: UIPanGestureRecognizer) {
        guard session.scratchpadSplitMode == .split, let superview else { return }
        let y = recognizer.location(in: superview).y
        switch recognizer.state {
        case .began:
            lastPanY = y
        case .changed:
            let delta = y - lastPanY
            lastPanY = y
            onSplitDragDelta?(delta)
        default:
            break
        }
    }

    @objc private func toggleSplitMode() {
        session.toggleScratchpadSplitMode()
    }

    @objc private func paperChanged() {
        let idx = paperControl.selectedSegmentIndex
        guard idx >= 0, idx < ScratchpadPaperStyle.allCases.count else { return }
        session.scratchpadPaper = ScratchpadPaperStyle.allCases[idx]
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

    @objc private func closeScratchpad() {
        session.isScratchpadOpen = false
    }
}
