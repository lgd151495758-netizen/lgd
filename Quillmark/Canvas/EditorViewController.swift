import Combine
import PDFKit
import UIKit

/// Hosts the PDFView and attaches one `PageInkView` overlay per visible page.
final class EditorViewController: UIViewController, PDFPageOverlayViewProvider {
    let session: DocumentSession
    let pdfView = PDFView()
    private var overlays: [Int: PageInkView] = [:]
    private var cancellables = Set<AnyCancellable>()

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

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        switch action {
        case .ignore:
            return
        case .switchPrevious:
            session.tool.switchToPrevious()
        default:
            session.tool.toggleEraser()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyInputMode(fingerDrawing: session.tool.fingerDrawing)
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

extension EditorViewController: UIPencilInteractionDelegate {
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilTap(interaction.preferredTapAction)
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
