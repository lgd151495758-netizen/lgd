import Combine
import PDFKit
import UIKit

/// Hosts the PDFView and attaches one `PageInkView` overlay per visible page.
final class EditorViewController: UIViewController, PDFPageOverlayViewProvider {
    let session: DocumentSession
    let pdfView = PDFView()
    private var overlays: [Int: PageInkView] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var pdfViewHeightConstraint: NSLayoutConstraint?
    private var presentationViewport = PresentationViewport(contentHeight: 0, extraBottomInset: 0, captureRect: .zero)

    init(session: DocumentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        view.clipsToBounds = true

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        let heightConstraint = pdfView.heightAnchor.constraint(equalTo: view.heightAnchor, constant: 0)
        pdfViewHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            heightConstraint,
        ])

        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = true
        pdfView.autoScales = true
        pdfView.pageOverlayViewProvider = self
        pdfView.isInMarkupMode = true
        pdfView.document = session.pdfDocument

        session.pageDidChange = { [weak self] page in
            self?.overlays[page]?.sync()
        }
        session.$tool
            .map(\.fingerDrawing)
            .removeDuplicates()
            .sink { [weak self] fingerDrawing in
                self?.applyInputMode(fingerDrawing: fingerDrawing)
            }
            .store(in: &cancellables)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)
    }

    /// Apple Pencil (2nd generation) double-tap, following the user's system preference.
    fileprivate func handlePencilTap(_ action: UIPencilPreferredAction) {
        session.handlePencilDoubleTap(action)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePresentationViewport()
        applyInputMode(fingerDrawing: session.tool.fingerDrawing)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PresentationCenter.shared.registerSceneAccessory(on: self)
        PresentationCenter.shared.setContentSource(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        PresentationCenter.shared.clearContentSource(self)
        PresentationCenter.shared.unregisterSceneAccessory(from: self)
    }

    /// Fingers always scroll; Apple Pencil never scrolls. With finger drawing on, scrolling
    /// needs two fingers.
    private func applyInputMode(fingerDrawing: Bool) {
        if let scrollView = pdfView.firstDescendant(of: UIScrollView.self) {
            scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            scrollView.panGestureRecognizer.minimumNumberOfTouches = fingerDrawing ? 2 : 1
            scrollView.delaysContentTouches = false
        }
        for overlay in overlays.values {
            overlay.updateInputMode(fingerDrawing: fingerDrawing)
        }
    }

    // MARK: PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = view.document else { return nil }
        let index = document.index(for: page)
        if let existing = overlays[index] {
            return existing
        }
        let overlay = PageInkView(pageIndex: index, pageSize: page.bounds(for: view.displayBox).size, session: session)
        overlays[index] = overlay
        overlay.sync()
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageInkView else { return }
        if overlays[overlay.pageIndex] === overlay {
            overlays[overlay.pageIndex] = nil
        }
    }
}

extension EditorViewController: PresentationContentSource {
    var presentationView: UIView { view }

    func presentationViewportDidChange() {
        updatePresentationViewport()
    }

    private func updatePresentationViewport() {
        let visibleSize = view.bounds.size
        guard visibleSize.width > 0, visibleSize.height > 0 else { return }
        let center = PresentationCenter.shared
        let externalSize = center.isShowingContentOnly ? center.externalDisplaySize : nil
        let viewport = PresentationViewport.compute(
            visibleSize: visibleSize,
            externalSize: externalSize,
            fillMode: center.fillMode
        )
        presentationViewport = viewport
        if let heightConstraint = pdfViewHeightConstraint,
           abs(heightConstraint.constant - viewport.extraBottomInset) > 0.5 {
            heightConstraint.constant = viewport.extraBottomInset
            if let scrollView = pdfView.firstDescendant(of: UIScrollView.self) {
                scrollView.contentInset.bottom = viewport.extraBottomInset
                scrollView.verticalScrollIndicatorInsets.bottom = viewport.extraBottomInset
            }
            view.setNeedsLayout()
        }
    }

    func capturePresentationFrame(completion: @escaping (UIImage?, CGSize) -> Void) {
        updatePresentationViewport()
        let bounds = pdfView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            completion(nil, .zero)
            return
        }
        let target = presentationViewport.captureRect
        let captureRect = (target.width > 0 && target.height > 0) ? target.intersection(bounds) : bounds
        guard captureRect.width > 0, captureRect.height > 0 else {
            completion(nil, .zero)
            return
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(view.window?.screen.scale ?? 2, 2)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
        let image = renderer.image { ctx in
            ctx.cgContext.translateBy(x: -captureRect.minX, y: -captureRect.minY)
            pdfView.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
        completion(image, captureRect.size)
    }
}

extension EditorViewController: UIPencilInteractionDelegate {
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilTap(UIPencilInteraction.preferredTapAction)
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handlePencilTap(UIPencilInteraction.preferredTapAction)
    }
}

extension UIView {
    func firstDescendant<T: UIView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
