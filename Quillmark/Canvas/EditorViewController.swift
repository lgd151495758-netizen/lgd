import Combine
import PDFKit
import UIKit

/// First-class PDF annotation editor with full Quillmark tool parity:
/// Ballpoint Pen + Draw-and-Hold (Plan A live reshaping), Lasso (move/scale/recolor/duplicate/delete),
/// 14 Standard Shapes + 18% shading fill + vertex editing & mini-bar, Virtual Compass + analytic
/// intersection snap, Cover Tape (finger tap reveal/hide + cover/reveal all), Trail Laser Pointer,
/// Precise/Stroke Eraser, freely movable & resizable Floating Sticky Note, Scribble suppression,
/// and 60fps borderless external display projection + Freeze.
final class EditorViewController: UIViewController, DocumentTabViewController, PDFPageOverlayViewProvider, InkInputDelegate,
    UIScribbleInteractionDelegate, UIGestureRecognizerDelegate {

    let session: DocumentSession
    var isManagedByTabDeck: Bool = false
    private var isTabActive: Bool = true
    private var hasRestoredViewport: Bool = false
    private var isRestoringViewport: Bool = false
    private let pencilInteraction = UIPencilInteraction()
    let pdfView = PDFView()
    private var overlays: [Int: PageInkView] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var scrollViewObserved = false
    private weak var pdfScrollView: UIScrollView?
    private let projectionRenderer = PDFProjectionRenderer()
    private var pdfDocumentRevision: UInt64 = 0
    private var viewportRecordWork: DispatchWorkItem?
    private var scrollSettleWork: DispatchWorkItem?
    private var lastScrollActivityAt: CFAbsoluteTime = 0
    private var needsHighResSettleRefresh = false
    private var pdfViewHeightConstraint: NSLayoutConstraint?
    private var presentationViewport = PresentationViewport(contentHeight: 0, extraBottomInset: 0, captureRect: .zero)
    private var captureOriginY: CGFloat = 0

    // Unified gesture & vector overlay hierarchy (sibling above pdfView; iPad chrome never projected)
    private let inkRecognizer = InkGestureRecognizer(target: nil, action: nil)
    private let tapeTapRecognizer = UITapGestureRecognizer()
    private let lassoPreviewFillContainer = CALayer()
    private let lassoPreviewContainer = CALayer()
    private let liveFillLayer = CAShapeLayer()
    private let liveLayer = CAShapeLayer()
    private let eraserCursor = CAShapeLayer()
    private let laserGlowLayer = CAShapeLayer()
    private let laserCoreLayer = CAShapeLayer()
    private let geometryOverlay = GeometryToolOverlayView()
    private lazy var scratchpadPanel = ScratchpadPanelView(session: session)
    private var stickyNoteFrame: CGRect = .zero
    private var scratchpadLiveOverlay: ScratchpadLiveOverlay?
    private let geometryCache = StrokeGeometryCache()

    private struct LassoPreviewEntry {
        let baseViewPath: CGPath
        let baseFillPath: CGPath?
        let strokeColor: CGColor
        let fillColor: CGColor?
        let opacity: Float
        let isHighlighter: Bool
    }

    private struct LassoTransformContext {
        let pageIndex: Int
        let originalStrokes: [InkStroke]
        let selectedIDs: Set<UUID>
        let strokesByID: [UUID: InkStroke]
        let basePageBox: CGRect
        let baseViewTransform: CGAffineTransform
        var currentScale: CGFloat = 1
        var pivotPage: CGPoint = .zero
        var currentTranslation: CGPoint = .zero
    }

    private struct ShapeEditContext {
        let pageIndex: Int
        let strokeID: UUID
        let originalStrokes: [InkStroke]
        let originalStroke: InkStroke
        let basePagePrimitive: GeometricPrimitive
        var currentPagePrimitive: GeometricPrimitive
    }

    private enum ActiveInteraction {
        case none
        case normalInput
        case compassNeedle(grabOffset: CGPoint)
        case compassResize
        case compassButton(CompassState.HitZone, startPoint: CGPoint)
        case compassDraw(pageIndex: Int, sweep: CompassSweep, crossedCloseHaptic: Bool)
        case protractorCenter(grabOffset: CGPoint)
        case protractorRay1
        case protractorRay2
        case protractorRotate(lastAngle: CGFloat)
        case protractorButton(ProtractorState.HitZone, startPoint: CGPoint)
        case shapeCreate(pageIndex: Int, preset: ShapePreset, startPage: CGPoint, rawStartView: CGPoint, currentPrimitive: GeometricPrimitive?)
        case selectedHandle(index: Int, context: ShapeEditContext)
        case selectedBody(startPage: CGPoint, context: ShapeEditContext)
        case selectedAction(SelectedShapeOverlay.ActionButton, startPoint: CGPoint)
        case lassoDraw(pageIndex: Int, pagePoints: [CGPoint], rawStartView: CGPoint)
        case lassoMove(startPage: CGPoint, context: LassoTransformContext)
        case lassoScale(corner: LassoSelectionOverlay.ScaleCorner, startCornerPage: CGPoint, context: LassoTransformContext)
        case lassoAction(LassoSelectionOverlay.ActionButton, startPoint: CGPoint)
    }

    // Virtual Compass, Smart Protractor, Selected Shape, Lasso & Snap Points
    private var compassState = CompassState()
    private var protractorState = ProtractorState()
    private var selectedStrokeID: UUID?
    private var selectedPageIndex: Int = 0
    private var lassoSelectedIDs: [UUID] = []
    private var lassoPageIndex: Int = 0
    private var lassoPreviewEntries: [LassoPreviewEntry] = []
    private var lassoPreviewTransform: CGAffineTransform = .identity
    private var activeInteraction: ActiveInteraction = .none
    private var fingerControlInteraction: ActiveInteraction = .none
    private var cachedPageSnapPoints: [SnapPoint] = []
    private var cachedViewSnapPoints: [SnapPoint] = []
    private var lastSnapHapticPoint: CGPoint?

    // Drawing state (PDF page points on activeDrawPageIndex)
    private var activeDrawPageIndex: Int = 0
    private var liveTool = ToolSettings()
    private var livePoints: [InkPoint] = []
    private var liveStartTime: TimeInterval = 0
    private var pendingEstimates: [NSNumber: Int] = [:]
    private var lastCommitted: (id: UUID, page: Int, points: [InkPoint])?

    // Draw-and-hold shape snapping
    private var holdTimer: DispatchWorkItem?
    private var holdAnchorViewPoint: CGPoint = .zero
    private var snappedBaseShape: RecognizedShape?
    private var snappedCurrentShape: RecognizedShape?
    private var snapDragOriginPagePoint: CGPoint = .zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // Laser pointer (view coordinates so it sweeps seamlessly across PDF page gaps)
    private let laserEngine = LaserPointerEngine()
    private var laserDisplayLink: CADisplayLink?
    private var laserDisplayLinkProxy: PDFDisplayLinkProxy?
    private var laserFrame: LaserRenderFrame = .empty

    // Erasing state (PDF page points on activeErasePageIndex)
    private var activeErasePageIndex: Int = 0
    private var eraseOriginal: [InkStroke]?
    private var eraseWorking: [InkStroke] = []
    private var lastErasePoint: CGPoint?

    init(session: DocumentSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopLaserLoop()
        holdTimer?.cancel()
        viewportRecordWork?.cancel()
        scrollSettleWork?.cancel()
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

        // Block Apple Pencil Scribble on the container and PDFView hierarchy.
        view.addInteraction(UIScribbleInteraction(delegate: self))
        pdfView.addInteraction(UIScribbleInteraction(delegate: self))

        // Pin anchorPoint to (0, 0) so affine scale transforms match CGPath/CGRect coordinates exactly.
        lassoPreviewFillContainer.anchorPoint = .zero
        lassoPreviewFillContainer.position = .zero
        lassoPreviewContainer.anchorPoint = .zero
        lassoPreviewContainer.position = .zero
        view.layer.addSublayer(lassoPreviewFillContainer)
        view.layer.addSublayer(lassoPreviewContainer)

        liveFillLayer.fillRule = .nonZero
        liveFillLayer.opacity = 0.18
        view.layer.addSublayer(liveFillLayer)

        liveLayer.fillRule = .nonZero
        view.layer.addSublayer(liveLayer)

        eraserCursor.fillColor = UIColor.systemGray.withAlphaComponent(0.15).cgColor
        eraserCursor.strokeColor = UIColor.systemGray.cgColor
        eraserCursor.lineWidth = 1
        eraserCursor.isHidden = true
        view.layer.addSublayer(eraserCursor)

        laserGlowLayer.fillRule = .nonZero
        laserGlowLayer.shadowOffset = .zero
        laserGlowLayer.shadowRadius = 10
        laserGlowLayer.shadowOpacity = 0.9
        view.layer.addSublayer(laserGlowLayer)

        laserCoreLayer.fillRule = .nonZero
        laserCoreLayer.fillColor = UIColor.white.cgColor
        view.layer.addSublayer(laserCoreLayer)

        // iPad-only Compass, Selected Shape, Lasso & Snap overlay (never projected to external display).
        geometryOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(geometryOverlay)
        NSLayoutConstraint.activate([
            geometryOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            geometryOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            geometryOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            geometryOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        geometryOverlay.onFingerTap = { [weak self] p in self?.handleGeometryControlTap(at: p) }
        geometryOverlay.onFingerPanBegan = { [weak self] p in self?.beginFingerGeometryDrag(at: p) }
        geometryOverlay.onFingerPanChanged = { [weak self] p in self?.updateFingerGeometryDrag(to: p) }
        geometryOverlay.onFingerPanEnded = { [weak self] _ in self?.endFingerGeometryDrag() }

        // Floating movable & resizable math sticky-note window (header bar & resize grips are iPad-only).
        scratchpadPanel.isHidden = !session.isScratchpadOpen
        view.addSubview(scratchpadPanel)
        scratchpadPanel.onMoveDelta = { [weak self] delta in
            guard let self, self.view.bounds.width > 0 else { return }
            let moved = self.stickyNoteFrame.offsetBy(dx: delta.x, dy: delta.y)
            self.stickyNoteFrame = StickyNoteLayout.clamped(moved, in: self.view.bounds)
            self.scratchpadPanel.frame = self.stickyNoteFrame
            PresentationCenter.shared.requestFrameRefresh()
        }
        scratchpadPanel.onResizeBottomRight = { [weak self] delta in
            guard let self, self.view.bounds.width > 0 else { return }
            self.stickyNoteFrame = StickyNoteLayout.resizingBottomRight(from: self.stickyNoteFrame, delta: delta, in: self.view.bounds)
            self.scratchpadPanel.frame = self.stickyNoteFrame
            PresentationCenter.shared.requestFrameRefresh()
        }
        scratchpadPanel.onResizeBottomLeft = { [weak self] delta in
            guard let self, self.view.bounds.width > 0 else { return }
            self.stickyNoteFrame = StickyNoteLayout.resizingBottomLeft(from: self.stickyNoteFrame, delta: delta, in: self.view.bounds)
            self.scratchpadPanel.frame = self.stickyNoteFrame
            PresentationCenter.shared.requestFrameRefresh()
        }
        scratchpadPanel.onFrameInteractionEnded = { [weak self] in
            guard let self else { return }
            self.session.setScratchpadFrame(self.stickyNoteFrame)
            PresentationCenter.shared.requestFrameRefresh()
        }
        scratchpadPanel.canvas.onLiveOverlayChanged = { [weak self] overlay in
            self?.scratchpadLiveOverlay = overlay
            self?.pushPresentationOverlay()
        }
        scratchpadPanel.canvas.onContentDidMutate = {
            PresentationCenter.shared.requestFrameRefresh()
        }
        scratchpadPanel.canvas.onActiveFocusY = { [weak self] localY in
            guard let self else { return }
            let offsetY: CGFloat = (self.session.scratchpadSplitMode == .full)
                ? 0
                : (self.stickyNoteFrame.minY + ScratchpadPanelView.headerHeight)
            self.updatePresentationViewport(focusY: offsetY + localY)
        }

        inkRecognizer.inkDelegate = self
        inkRecognizer.delegate = self
        inkRecognizer.cancelsTouchesInView = true
        view.addGestureRecognizer(inkRecognizer)

        // Finger tap reveals/hides Cover Tapes on PDF pages without disturbing undo stack.
        tapeTapRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]
        tapeTapRecognizer.delegate = self
        tapeTapRecognizer.cancelsTouchesInView = false
        tapeTapRecognizer.addTarget(self, action: #selector(handleFingerTap(_:)))
        view.addGestureRecognizer(tapeTapRecognizer)

        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)

        bindSession()
        bindPDFNotifications()
        updateActiveDocumentPageIndex()
        applyGestureRules()
    }

    private func bindSession() {
        session.pageDidChange = { [weak self] changedPage in
            guard let self else { return }
            if changedPage < 0 {
                self.scratchpadPanel.canvas.syncCommittedStrokes()
                PresentationCenter.shared.requestFrameRefresh()
            } else {
                self.overlays[changedPage]?.sync()
                self.refreshSelectedShapeOverlay()
                self.refreshLassoSelectionOverlay()
                PresentationCenter.shared.requestFrameRefresh()
            }
        }
        session.allPagesDidChange = { [weak self] in
            guard let self else { return }
            self.clearSelectedShape()
            self.clearLassoSelection()
            for overlay in self.overlays.values {
                overlay.hiddenStrokeIDs = []
                overlay.sync()
            }
            self.scratchpadPanel.canvas.syncCommittedStrokes()
            PresentationCenter.shared.requestFrameRefresh()
        }
        session.requestJumpToPDFPage = { [weak self] pageIndex in
            guard let self else { return }
            guard self.hasRestoredViewport, self.view.window != nil, self.pdfView.bounds.width > 0 else {
                // Keep `pendingJumpToPDFPageIndex` queued until layout / tab activation completes.
                return
            }
            let target = self.session.consumePendingJumpToPDFPage() ?? pageIndex
            self.navigatePDFToPage(target)
        }
        session.pdfDocumentDidReload = { [weak self] targetPageIndex in
            guard let self else { return }
            self.clearSelectedShape()
            self.clearLassoSelection()
            let savedScale = self.pdfView.scaleFactor
            self.overlays.removeAll()
            self.pdfDocumentRevision &+= 1
            self.projectionRenderer.invalidateDocument()
            self.pdfView.document = self.session.pdfDocument
            if savedScale.isFinite, savedScale > 0.1 {
                self.pdfView.scaleFactor = savedScale
            }
            if let doc = self.pdfView.document,
               targetPageIndex >= 0, targetPageIndex < doc.pageCount,
               let page = doc.page(at: targetPageIndex) {
                self.pdfView.go(to: page)
            }
            self.updateActiveDocumentPageIndex()
            self.applyGestureRules()
            self.recordCurrentViewport()
            PresentationCenter.shared.requestFrameRefresh()
        }
        session.$tool
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.applyGestureRules()
                    self?.syncGeometryOverlayAppearance()
                    self?.scratchpadPanel.canvas.applyToolConfiguration()
                }
            }
            .store(in: &cancellables)
        session.$tool
            .map(\.kind)
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.clearSelectedShape()
                    self?.clearLassoSelection()
                    self?.scratchpadPanel.canvas.toolKindDidChange()
                }
            }
            .store(in: &cancellables)
        session.$geometryAid
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.syncGeometryAidTarget() }
            }
            .store(in: &cancellables)
        session.$isScratchpadOpen
            .removeDuplicates()
            .sink { [weak self] isOpen in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !isOpen {
                        self.scratchpadPanel.canvas.deactivate()
                        self.scratchpadLiveOverlay = nil
                    } else {
                        self.clearSelectedShape()
                        self.clearLassoSelection()
                        self.scratchpadPanel.refreshHeaderState()
                        self.scratchpadPanel.canvas.syncCommittedStrokes()
                    }
                    self.updateScratchpadLayout()
                    self.syncGeometryAidTarget()
                    self.pushPresentationOverlay()
                    PresentationCenter.shared.requestFrameRefresh()
                }
            }
            .store(in: &cancellables)
        session.$scratchpadSplitMode
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scratchpadPanel.refreshHeaderState()
                    self.updateScratchpadLayout()
                    self.pushPresentationOverlay()
                    PresentationCenter.shared.requestFrameRefresh()
                }
            }
            .store(in: &cancellables)
        session.$scratchpadPageIndex
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.scratchpadPanel.refreshHeaderState()
                    self.scratchpadPanel.canvas.handlePageSwitch()
                }
            }
            .store(in: &cancellables)
        session.$scratchpadPageCount
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.scratchpadPanel.refreshHeaderState() }
            }
            .store(in: &cancellables)
        session.$scratchpadPaper
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.scratchpadPanel.refreshHeaderState() }
            }
            .store(in: &cancellables)
    }

    private func bindPDFNotifications() {
        NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: pdfView)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateActiveDocumentPageIndex()
                if self.selectedStrokeID != nil {
                    self.refreshSelectedShapeOverlay()
                }
                if !self.lassoSelectedIDs.isEmpty {
                    self.refreshLassoSelectionOverlay()
                }
                self.scheduleViewportRecord()
                PresentationCenter.shared.markContentActive()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: pdfView)
            .sink { [weak self] _ in
                self?.handleScrollOrZoomChanged()
            }
            .store(in: &cancellables)
        attachScrollViewObserversIfNeeded()
    }

    private func attachScrollViewObserversIfNeeded() {
        guard !scrollViewObserved, let scrollView = pdfView.firstDescendant(of: UIScrollView.self) else { return }
        scrollViewObserved = true
        pdfScrollView = scrollView
        scrollView.publisher(for: \.contentOffset)
            .sink { [weak self] _ in
                self?.handleScrollOrZoomChanged()
            }
            .store(in: &cancellables)
        scrollView.publisher(for: \.zoomScale)
            .sink { [weak self] _ in
                self?.handleScrollOrZoomChanged()
            }
            .store(in: &cancellables)
    }

    private func handleScrollOrZoomChanged() {
        if selectedStrokeID != nil {
            refreshSelectedShapeOverlay()
        }
        if !lassoSelectedIDs.isEmpty {
            refreshLassoSelectionOverlay()
        }
        scheduleViewportRecord()
        lastScrollActivityAt = CFAbsoluteTimeGetCurrent()
        PresentationCenter.shared.markContentActive()
        if PresentationCenter.shared.isExternalDisplayConnected {
            scheduleScrollSettleRefresh()
        }
    }

    private func scheduleViewportRecord() {
        guard hasRestoredViewport, !isRestoringViewport else { return }
        viewportRecordWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recordCurrentViewport()
        }
        viewportRecordWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func scheduleScrollSettleRefresh() {
        scrollSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard PresentationCenter.shared.isExternalDisplayConnected else {
                self.needsHighResSettleRefresh = false
                return
            }
            if let sv = self.pdfScrollView,
               sv.isTracking || sv.isDragging || sv.isDecelerating || sv.isZooming {
                if self.needsHighResSettleRefresh {
                    self.scheduleScrollSettleRefresh()
                }
                return
            }
            if self.needsHighResSettleRefresh {
                self.needsHighResSettleRefresh = false
                PresentationCenter.shared.requestFrameRefresh()
            }
        }
        scrollSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
    }

    fileprivate func handlePencilTap(_ action: UIPencilPreferredAction) {
        session.handlePencilDoubleTap(action)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if lassoPreviewTransform == .identity {
            lassoPreviewFillContainer.bounds = view.bounds
            lassoPreviewFillContainer.position = .zero
            lassoPreviewContainer.bounds = view.bounds
            lassoPreviewContainer.position = .zero
        }
        liveFillLayer.frame = view.bounds
        liveLayer.frame = view.bounds
        eraserCursor.frame = view.bounds
        laserGlowLayer.frame = view.bounds
        laserCoreLayer.frame = view.bounds
        CATransaction.commit()
        attachScrollViewObserversIfNeeded()
        updatePresentationViewport(focusY: nil)
        updateScratchpadLayout()
        clampGeometryAidsToBounds()
        refreshSelectedShapeOverlay()
        refreshLassoSelectionOverlay()
        applyGestureRules()
        if pdfView.bounds.width > 0, pdfView.bounds.height > 0 {
            restoreSavedViewportIfNeeded()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isManagedByTabDeck else { return }
        PresentationCenter.shared.registerSceneAccessory(on: self)
        PresentationCenter.shared.setContentSource(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopLaserLoop()
        holdTimer?.cancel()
        scratchpadPanel.canvas.deactivate()
        saveStateNow()
        guard !isManagedByTabDeck else { return }
        PresentationCenter.shared.clearContentSource(self)
        PresentationCenter.shared.unregisterSceneAccessory(from: self)
    }

    // MARK: DocumentTabViewController & Viewport Persistence

    func setTabActive(_ active: Bool, releasePresentation: Bool) {
        isTabActive = active
        pencilInteraction.isEnabled = active
        if active {
            updatePresentationViewport(focusY: nil)
            applyGestureRules()
            PresentationCenter.shared.setContentSource(self)
            pushPresentationOverlay()
            if hasRestoredViewport, pdfView.bounds.width > 0,
               let pendingPage = session.consumePendingJumpToPDFPage() {
                navigatePDFToPage(pendingPage)
            }
        } else {
            inkRecognizer.cancelIfActive()
            stopLaserLoop()
            laserEngine.cancel()
            laserFrame = .empty
            holdTimer?.cancel()
            holdTimer = nil
            viewportRecordWork?.cancel()
            viewportRecordWork = nil
            scrollSettleWork?.cancel()
            scrollSettleWork = nil
            needsHighResSettleRefresh = false
            projectionRenderer.clearCache()
            scratchpadPanel.canvas.deactivate()
            scratchpadLiveOverlay = nil
            if releasePresentation {
                PresentationCenter.shared.clearContentSource(self)
            }
        }
    }

    func saveStateNow() {
        viewportRecordWork?.cancel()
        viewportRecordWork = nil
        recordCurrentViewport()
        session.saveNow()
    }

    private func recordCurrentViewport() {
        guard hasRestoredViewport, !isRestoringViewport, pdfView.bounds.width > 0 else { return }
        guard let sv = pdfScrollView ?? pdfView.firstDescendant(of: UIScrollView.self), sv.contentSize.height > 0 else { return }
        session.updateViewport(ViewportState(
            offsetX: sv.contentOffset.x,
            offsetY: sv.contentOffset.y,
            zoomScale: pdfView.scaleFactor,
            pageIndex: session.activeDocumentPageIndex
        ))
    }

    private func navigatePDFToPage(_ pageIndex: Int) {
        guard let doc = pdfView.document,
              pageIndex >= 0, pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else { return }
        clearSelectedShape()
        clearLassoSelection()
        pdfView.go(to: page)
        updateActiveDocumentPageIndex()
        recordCurrentViewport()
        PresentationCenter.shared.requestFrameRefresh()
    }

    private func restoreSavedViewportIfNeeded() {
        guard !hasRestoredViewport, !isRestoringViewport else { return }
        if let pendingPage = session.consumePendingJumpToPDFPage() {
            isRestoringViewport = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self else { return }
                self.isRestoringViewport = false
                self.hasRestoredViewport = true
                self.navigatePDFToPage(pendingPage)
            }
            return
        }
        guard let saved = session.savedViewport, saved.isValid else {
            hasRestoredViewport = true
            return
        }
        isRestoringViewport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            guard let self else { return }
            if saved.zoomScale > 0 {
                let minScale = self.pdfView.minScaleFactor
                let maxScale = self.pdfView.maxScaleFactor
                if minScale > 0, maxScale >= minScale {
                    let clampedZoom = min(max(saved.zoomScale, minScale), maxScale)
                    if abs(self.pdfView.scaleFactor - clampedZoom) > 0.015 {
                        self.pdfView.scaleFactor = clampedZoom
                    }
                }
            }
            if let sv = self.pdfView.firstDescendant(of: UIScrollView.self),
               sv.contentSize.height > 0 {
                let clamped = ViewportState.clampedOffset(
                    CGPoint(x: saved.offsetX, y: saved.offsetY),
                    contentSize: sv.contentSize,
                    boundsSize: sv.bounds.size
                )
                sv.setContentOffset(clamped, animated: false)
            } else if let pageIdx = saved.pageIndex,
                      let page = self.pdfView.document?.page(at: pageIdx) {
                self.pdfView.go(to: page)
            }
            self.isRestoringViewport = false
            self.hasRestoredViewport = true
            self.updateActiveDocumentPageIndex()
        }
    }

    // MARK: Sticky Note & Geometry Aid Routing

    private func syncGeometryAidTarget() {
        if session.isScratchpadOpen {
            applyGeometryAid(.none)
            scratchpadPanel.canvas.applyGeometryAid(session.geometryAid)
        } else {
            scratchpadPanel.canvas.applyGeometryAid(.none)
            applyGeometryAid(session.geometryAid)
        }
    }

    private func stickyCanvasFrameInView() -> CGRect {
        let headerH = ScratchpadPanelView.headerHeight
        return CGRect(x: stickyNoteFrame.minX,
                      y: stickyNoteFrame.minY + headerH,
                      width: max(1, stickyNoteFrame.width),
                      height: max(1, stickyNoteFrame.height - headerH))
    }

    private func updateScratchpadLayout() {
        let isOpen = session.isScratchpadOpen
        scratchpadPanel.isHidden = !isOpen
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        if stickyNoteFrame == .zero {
            stickyNoteFrame = session.savedScratchpadFrame ?? StickyNoteLayout.defaultFrame(in: view.bounds)
        }
        stickyNoteFrame = StickyNoteLayout.clamped(stickyNoteFrame, in: view.bounds)
        let targetFrame = (session.scratchpadSplitMode == .full) ? view.bounds : stickyNoteFrame
        if scratchpadPanel.frame != targetFrame {
            scratchpadPanel.frame = targetFrame
        }
    }

    // MARK: Gestures & Scribble Suppression

    private static func setAllowedTouchTypesIfNeeded(_ types: [NSNumber], on recognizer: UIGestureRecognizer) {
        guard recognizer.state != .began && recognizer.state != .changed else { return }
        if recognizer.allowedTouchTypes != types {
            recognizer.allowedTouchTypes = types
        }
    }

    private func ensurePDFZoomBounds() {
        guard pdfView.bounds.width > 0, pdfView.bounds.height > 0, pdfView.document != nil else { return }
        let fit = pdfView.scaleFactorForSizeToFit
        guard fit.isFinite, fit > 0 else { return }
        let desiredMin = min(fit * 0.5, 0.5)
        let desiredMax = max(fit * 5.0, 5.0)
        if !pdfView.minScaleFactor.isFinite || pdfView.minScaleFactor <= 0 || pdfView.minScaleFactor > desiredMin * 1.05 {
            pdfView.minScaleFactor = desiredMin
        }
        if !pdfView.maxScaleFactor.isFinite || pdfView.maxScaleFactor <= pdfView.minScaleFactor || pdfView.maxScaleFactor < desiredMax * 0.95 {
            pdfView.maxScaleFactor = desiredMax
        }
    }

    private func applyGestureRules() {
        let fingerDrawing = session.tool.fingerDrawing
        inkRecognizer.allowsFingerDrawing = fingerDrawing
        if tapeTapRecognizer.isEnabled != !fingerDrawing {
            tapeTapRecognizer.isEnabled = !fingerDrawing
        }
        if geometryOverlay.isUserInteractionEnabled != !fingerDrawing {
            geometryOverlay.isUserInteractionEnabled = !fingerDrawing
        }

        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        let scrollTypes = [direct, pointer]
        let otherTypes = fingerDrawing ? [pointer] : [direct, pointer]
        let scrollView = pdfView.firstDescendant(of: UIScrollView.self)

        for recognizer in Self.allGestureRecognizers(in: pdfView) where recognizer !== inkRecognizer {
            let isScrollOrZoom = (scrollView != nil &&
                (recognizer === scrollView!.panGestureRecognizer || recognizer === scrollView!.pinchGestureRecognizer))
                || InkGestureRecognizer.isScrollOrZoomGesture(recognizer)
            Self.setAllowedTouchTypesIfNeeded(isScrollOrZoom ? scrollTypes : otherTypes, on: recognizer)
        }
        if let scrollView {
            let targetMinTouches = fingerDrawing ? 2 : 1
            if scrollView.panGestureRecognizer.minimumNumberOfTouches != targetMinTouches {
                scrollView.panGestureRecognizer.minimumNumberOfTouches = targetMinTouches
            }
            if let pinch = scrollView.pinchGestureRecognizer, !pinch.isEnabled {
                pinch.isEnabled = true
            }
            if scrollView.delaysContentTouches {
                scrollView.delaysContentTouches = false
            }
        }
        ensurePDFZoomBounds()
        suppressSystemScribble(in: pdfView)
    }

    private func suppressSystemScribble(in root: UIView) {
        for subview in root.subviews {
            for interaction in subview.interactions {
                if let scribble = interaction as? UIScribbleInteraction, scribble.delegate === self {
                    continue
                } else if String(describing: type(of: interaction)).contains("Scribble") {
                    subview.removeInteraction(interaction)
                }
            }
            suppressSystemScribble(in: subview)
        }
    }

    private static func allGestureRecognizers(in view: UIView) -> [UIGestureRecognizer] {
        var result = view.gestureRecognizers ?? []
        for subview in view.subviews {
            result.append(contentsOf: allGestureRecognizers(in: subview))
        }
        return result
    }

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if session.isScratchpadOpen {
            let pt = touch.location(in: scratchpadPanel)
            if scratchpadPanel.bounds.contains(pt) {
                return false
            }
        }
        if gestureRecognizer === tapeTapRecognizer {
            if let hitView = touch.view, hitView.isDescendant(of: geometryOverlay) {
                return false
            }
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === tapeTapRecognizer {
            return true
        }
        // Never run simultaneously with scrollView.panGestureRecognizer while writing with Apple Pencil
        // (doing so allows a resting palm or Pencil to scroll the page underneath active strokes!).
        // Only allow 2-finger pinch/scroll coexistence in Finger Drawing mode when not using Pencil.
        if gestureRecognizer === inkRecognizer,
           session.tool.fingerDrawing,
           !inkRecognizer.isTrackingPencil,
           InkGestureRecognizer.isTwoFingerScrollOrPinchGesture(otherGestureRecognizer) {
            return true
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === inkRecognizer else { return false }
        // A 2-finger pinch recognizer can never be triggered by a single Apple Pencil;
        // never deadlock pinch waiting for Pencil-only inkRecognizer to fail.
        if InkGestureRecognizer.isPinchGesture(otherGestureRecognizer) {
            return false
        }
        let typeName = String(describing: type(of: otherGestureRecognizer))
        if typeName.contains("Scribble") {
            return true
        }
        let pencilType = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        if otherGestureRecognizer.allowedTouchTypes.contains(pencilType),
           let otherView = otherGestureRecognizer.view, otherView.isDescendant(of: pdfView) {
            return true
        }
        return false
    }

    @objc private func handleFingerTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, !session.tool.fingerDrawing else { return }
        let viewPoint = recognizer.location(in: view)
        guard let pageIdx = pageIndex(at: viewPoint) else { return }
        let pt = pagePoint(fromView: viewPoint, pageIndex: pageIdx)
        let tol = 14 / viewScale(for: pageIdx)
        let strokes = session.strokes(onPage: pageIdx)
        for stroke in strokes.reversed() where stroke.isTape {
            if let hitID = LassoEngine.hitTestSingleStroke(from: [stroke], origins: [:],
                                                           at: pt, tolerance: tol, cache: geometryCache) {
                session.toggleTape(id: hitID, page: pageIdx)
                return
            }
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

    // MARK: PDF Page Coordinate Mapping

    private func updateActiveDocumentPageIndex() {
        guard let doc = pdfView.document, let current = pdfView.currentPage else { return }
        let idx = doc.index(for: current)
        if idx != NSNotFound, idx >= 0, idx != session.activeDocumentPageIndex {
            session.activeDocumentPageIndex = idx
        }
    }

    private func pageIndex(at viewPoint: CGPoint) -> Int? {
        guard let document = pdfView.document, document.pageCount > 0 else { return nil }
        let pdfPt = pdfView.convert(viewPoint, from: view)
        if let page = pdfView.page(for: pdfPt, nearest: true) {
            let idx = document.index(for: page)
            if idx != NSNotFound { return idx }
        }
        if let current = pdfView.currentPage {
            let idx = document.index(for: current)
            if idx != NSNotFound { return idx }
        }
        return 0
    }

    /// Exact affine transform mapping top-left PDF page points on `pageIndex` into `self.view` coordinates.
    private func pageToViewTransform(for pageIndex: Int) -> CGAffineTransform {
        if let overlay = overlays[pageIndex], overlay.window != nil, overlay.bounds.width > 0 {
            let s = overlay.pageScale
            let origin = overlay.convert(CGPoint.zero, to: view)
            let unitX = overlay.convert(CGPoint(x: 1, y: 0), to: view)
            let unitY = overlay.convert(CGPoint(x: 0, y: 1), to: view)
            let overlayToView = CGAffineTransform(
                a: unitX.x - origin.x, b: unitX.y - origin.y,
                c: unitY.x - origin.x, d: unitY.y - origin.y,
                tx: origin.x, ty: origin.y
            )
            return CGAffineTransform(scaleX: s, y: s).concatenating(overlayToView)
        }
        guard let page = pdfView.document?.page(at: pageIndex) else { return .identity }
        let pageRect = page.bounds(for: pdfView.displayBox)
        let rectInPDF = pdfView.convert(pageRect, from: page)
        let rectInView = view.convert(rectInPDF, from: pdfView)
        let sx = rectInView.width / max(1, pageRect.width)
        let sy = rectInView.height / max(1, pageRect.height)
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: rectInView.minX, ty: rectInView.minY)
    }

    private func viewScale(for pageIndex: Int) -> CGFloat {
        let t = pageToViewTransform(for: pageIndex)
        return max(0.25, hypot(t.a, t.b))
    }

    private func pagePoint(fromView viewPoint: CGPoint, pageIndex: Int) -> CGPoint {
        viewPoint.applying(pageToViewTransform(for: pageIndex).inverted())
    }

    private func pagePoint(_ touch: UITouch, pageIndex: Int) -> CGPoint {
        pagePoint(fromView: touch.preciseLocation(in: view), pageIndex: pageIndex)
    }

    // MARK: InkInputDelegate

    func inkBegan(_ touch: UITouch, event: UIEvent?) {
        liveTool = session.tool
        let viewPoint = touch.location(in: view)
        updatePresentationViewport(focusY: viewPoint.y)

        if let touchedPage = pageIndex(at: viewPoint), session.activeDocumentPageIndex != touchedPage {
            session.activeDocumentPageIndex = touchedPage
        }

        // 1. Active lasso selection box, corner scale handles, or floating color/copy/delete bar.
        if let lassoInteraction = beginLassoSelectionInteraction(at: viewPoint) {
            activeInteraction = lassoInteraction
            return
        }
        if !lassoSelectedIDs.isEmpty {
            clearLassoSelection()
        }

        // 2. Selected shape handles, mini-bar buttons, or body drag take priority.
        if let editInteraction = beginSelectedShapeInteraction(at: viewPoint) {
            activeInteraction = editInteraction
            return
        }
        if selectedStrokeID != nil {
            clearSelectedShape()
        }

        // 3. Virtual compass handles, buttons, or circle sweep.
        if let aidInteraction = beginGeometryAidInteraction(at: viewPoint, allowDrawing: canDrawWithGeometryAid) {
            activeInteraction = aidInteraction
            return
        }

        // 4. Standard geometric shape tool (drag to create, or quick tap to select existing shape).
        if liveTool.kind == .shape {
            if let creation = beginShapeCreation(at: viewPoint) {
                activeInteraction = creation
            }
            return
        }

        // 5. Lasso tool: draw a freeform selection loop (or quick tap a stroke to select it).
        if liveTool.kind == .lasso {
            if let draw = beginLassoDraw(at: viewPoint) {
                activeInteraction = draw
            }
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
        let viewPoint = touch.location(in: view)
        updatePresentationViewport(focusY: viewPoint.y)

        if handleGeometryAidMoved(to: viewPoint) {
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
        let viewPoint = touch.location(in: view)
        if handleGeometryAidEnded(at: viewPoint) {
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
        let wasGeometryAid: Bool
        switch activeInteraction {
        case .none, .normalInput: wasGeometryAid = false
        default: wasGeometryAid = true
        }
        cancelGeometryAidInteraction()
        if wasGeometryAid { return }
        switch liveTool.kind {
        case .eraser:
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
            overlays[activeErasePageIndex]?.sync()
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
        let force = forceValue(touch)
        if !touch.estimatedPropertiesExpectingUpdates.contains(.force) {
            pendingEstimates[updateIndex] = nil
        }
        if var committed = lastCommitted {
            guard pointIndex < committed.points.count else { return }
            committed.points[pointIndex].force = force
            lastCommitted = committed
            session.refineStroke(id: committed.id, page: committed.page, points: committed.points)
        } else if pointIndex < livePoints.count {
            livePoints[pointIndex].force = force
        }
    }

    // MARK: Virtual Compass, Standard Shapes & Selected Shape Editing

    private var canDrawWithGeometryAid: Bool {
        switch liveTool.kind {
        case .pen, .tape, .shape: return true
        case .eraser, .laser, .lasso: return false
        }
    }

    private func applyGeometryAid(_ aid: GeometryAid) {
        cancelGeometryAidInteraction()
        if aid == .compass {
            clearSelectedShape()
            clearLassoSelection()
            let bounds = view.bounds
            if bounds.width > 0, bounds.height > 0,
               compassState.center == .zero || !bounds.insetBy(dx: 24, dy: 24).contains(compassState.center) {
                compassState.center = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            geometryOverlay.compass = compassState
        } else if aid == .protractor {
            clearSelectedShape()
            clearLassoSelection()
            let bounds = view.bounds
            if bounds.width > 0, bounds.height > 0,
               protractorState.center == .zero || !bounds.insetBy(dx: 24, dy: 24).contains(protractorState.center) {
                protractorState.center = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            geometryOverlay.protractor = protractorState
        }
        geometryOverlay.aid = aid
        syncGeometryOverlayAppearance()
        if aid == .protractor {
            autoDetectProtractorAngle(allowImageFallback: true, triggerHaptic: false)
        }
        pushPresentationOverlay()
    }

    private func clampGeometryAidsToBounds() {
        let bounds = view.bounds
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

    private func syncGeometryOverlayAppearance() {
        let color = session.tool.activeStrokeColor
        geometryOverlay.activeStrokeColor = UIColor(cgColor: color.cgColor)
        pushPresentationOverlay()
    }

    private func refreshSnapPoints(forPage pageIndex: Int, excludingStrokeID: UUID? = nil) {
        let pageSnaps = GeometrySnapEngine.snapPoints(from: session.strokes(onPage: pageIndex),
                                                      origins: [:],
                                                      excludingStrokeID: excludingStrokeID)
        let transform = pageToViewTransform(for: pageIndex)
        cachedPageSnapPoints = pageSnaps
        cachedViewSnapPoints = pageSnaps.map { SnapPoint(point: $0.point.applying(transform), kind: $0.kind) }
    }

    private func refreshAllVisibleViewSnapPoints() {
        var allViewSnaps: [SnapPoint] = []
        for pageIdx in overlays.keys.sorted() {
            let pageSnaps = GeometrySnapEngine.snapPoints(from: session.strokes(onPage: pageIdx), origins: [:])
            let transform = pageToViewTransform(for: pageIdx)
            allViewSnaps.append(contentsOf: pageSnaps.map { SnapPoint(point: $0.point.applying(transform), kind: $0.kind) })
        }
        cachedViewSnapPoints = allViewSnaps
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

    // MARK: Selected Shape State & Helpers

    private func selectStroke(_ id: UUID, onPage pageIndex: Int) {
        selectedStrokeID = id
        selectedPageIndex = pageIndex
        refreshSelectedShapeOverlay()
    }

    private func clearSelectedShape() {
        guard selectedStrokeID != nil || geometryOverlay.selectedShape != nil else { return }
        if let id = selectedStrokeID {
            overlays[selectedPageIndex]?.hiddenStrokeIDs.remove(id)
        }
        selectedStrokeID = nil
        geometryOverlay.isEditingSelectedShape = false
        geometryOverlay.selectedShape = nil
    }

    private func overlayModel(for stroke: InkStroke, pageIndex: Int,
                              pagePrimitive: GeometricPrimitive) -> SelectedShapeOverlay {
        let transform = pageToViewTransform(for: pageIndex)
        let handles = pagePrimitive.controlHandles().map { $0.applying(transform) }
        let box = pagePrimitive.boundingBox().applying(transform)
        return SelectedShapeOverlay(
            strokeID: stroke.id,
            handles: handles,
            boundingBox: box,
            lineStyle: stroke.resolvedLineStyle,
            supportsFill: pagePrimitive.supportsFill,
            isFilled: stroke.fillColor != nil,
            isCircularWithCenterMark: pagePrimitive.isCircularWithCenterMark,
            showsCenterMark: pagePrimitive.showsCenterMark
        )
    }

    private func refreshSelectedShapeOverlay() {
        guard let id = selectedStrokeID else {
            if geometryOverlay.selectedShape != nil {
                geometryOverlay.selectedShape = nil
            }
            return
        }
        switch activeInteraction {
        case .selectedHandle, .selectedBody:
            return
        default:
            break
        }
        guard let stroke = session.strokes(onPage: selectedPageIndex).first(where: { $0.id == id }),
              let geom = stroke.geometry else {
            clearSelectedShape()
            return
        }
        geometryOverlay.selectedShape = overlayModel(for: stroke, pageIndex: selectedPageIndex, pagePrimitive: geom)
    }

    private func beginSelectedShapeInteraction(at viewPoint: CGPoint) -> ActiveInteraction? {
        guard let id = selectedStrokeID,
              let overlay = geometryOverlay.selectedShape,
              overlay.strokeID == id,
              let stroke = session.strokes(onPage: selectedPageIndex).first(where: { $0.id == id }),
              let geom = stroke.geometry else { return nil }

        let pt = pagePoint(fromView: viewPoint, pageIndex: selectedPageIndex)
        let pageTol = 14 / viewScale(for: selectedPageIndex)
        let bodyHit = geom.hitTestBody(pt, tolerance: pageTol)
        let hit = overlay.hitTest(viewPoint, in: view.bounds, bodyHit: bodyHit)

        switch hit {
        case .none:
            return nil
        case let .action(button):
            return .selectedAction(button, startPoint: viewPoint)
        case let .handle(index):
            let context = startEditingSelectedStroke(stroke, pageIndex: selectedPageIndex, pagePrimitive: geom)
            return .selectedHandle(index: index, context: context)
        case .body:
            let context = startEditingSelectedStroke(stroke, pageIndex: selectedPageIndex, pagePrimitive: geom)
            return .selectedBody(startPage: pt, context: context)
        }
    }

    private func startEditingSelectedStroke(_ stroke: InkStroke, pageIndex: Int,
                                            pagePrimitive: GeometricPrimitive) -> ShapeEditContext {
        let originalStrokes = session.strokes(onPage: pageIndex)
        refreshSnapPoints(forPage: pageIndex, excludingStrokeID: stroke.id)
        overlays[pageIndex]?.hiddenStrokeIDs.insert(stroke.id)
        geometryOverlay.isEditingSelectedShape = true
        configureLiveLayer(for: stroke)
        renderEditedShape(stroke: stroke, pageIndex: pageIndex, pagePrimitive: pagePrimitive)
        return ShapeEditContext(
            pageIndex: pageIndex,
            strokeID: stroke.id,
            originalStrokes: originalStrokes,
            originalStroke: stroke,
            basePagePrimitive: pagePrimitive,
            currentPagePrimitive: pagePrimitive
        )
    }

    private func configureLiveLayer(for stroke: InkStroke) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if stroke.isHighlighter {
            liveLayer.fillColor = stroke.color.cgColor
            liveLayer.opacity = PageInkView.highlighterOpacity
            liveLayer.compositingFilter = "multiplyBlendMode"
            liveLayer.strokeColor = nil
            liveLayer.lineDashPattern = nil
        } else if stroke.isTape {
            liveLayer.fillColor = stroke.color.cgColor
            liveLayer.opacity = 0.96
            liveLayer.compositingFilter = nil
            liveLayer.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
            liveLayer.lineWidth = 1
            liveLayer.lineDashPattern = [5, 3]
        } else {
            liveLayer.fillColor = stroke.color.cgColor
            liveLayer.opacity = 1
            liveLayer.compositingFilter = nil
            liveLayer.strokeColor = nil
            liveLayer.lineDashPattern = nil
        }
        CATransaction.commit()
    }

    private func renderEditedShape(stroke: InkStroke, pageIndex: Int, pagePrimitive: GeometricPrimitive) {
        var preview = stroke
        preview.geometry = pagePrimitive
        preview.baked = nil
        preview.points = []
        let transform = pageToViewTransform(for: pageIndex)
        let outline = preview.outlinePath(transform: transform, finished: true)
        let fill = preview.fillPath(transform: transform)
        setLivePath(outline, fillPath: fill, fillColor: preview.fillColor?.cgColor)
        geometryOverlay.selectedShape = overlayModel(for: stroke, pageIndex: pageIndex, pagePrimitive: pagePrimitive)
    }

    private func commitEditedShape(_ context: ShapeEditContext) {
        var updated = context.originalStroke
        updated.geometry = context.currentPagePrimitive
        updated.baked = nil
        updated.points = []

        overlays[context.pageIndex]?.hiddenStrokeIDs.remove(context.strokeID)
        setLivePath(nil)

        if updated == context.originalStroke {
            overlays[context.pageIndex]?.sync()
            refreshSelectedShapeOverlay()
            return
        }

        let after = context.originalStrokes.map { $0.id == updated.id ? updated : $0 }
        session.replaceStrokes(onPage: context.pageIndex, before: context.originalStrokes, after: after)
        refreshSelectedShapeOverlay()
    }

    private func executeSelectedShapeAction(_ action: SelectedShapeOverlay.ActionButton) {
        guard let id = selectedStrokeID else { return }
        let pageIdx = selectedPageIndex
        let before = session.strokes(onPage: pageIdx)
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
            session.replaceStrokes(onPage: pageIdx, before: before, after: after)
            haptic.impactOccurred()

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
            session.replaceStrokes(onPage: pageIdx, before: before, after: after)
            haptic.impactOccurred()

        case .duplicate:
            var copy = stroke.translated(by: CGPoint(x: 24, y: 24))
            copy.id = UUID()
            session.addStroke(copy, page: pageIdx)
            selectStroke(copy.id, onPage: pageIdx)
            haptic.impactOccurred()

        case .delete:
            var after = before
            after.remove(at: idx)
            clearSelectedShape()
            session.replaceStrokes(onPage: pageIdx, before: before, after: after)
            haptic.impactOccurred()
        }
    }

    private func hitTestExistingGeometricStroke(atPage pagePoint: CGPoint, pageIndex: Int) -> InkStroke? {
        let tolerance = 14 / viewScale(for: pageIndex)
        let strokes = session.strokes(onPage: pageIndex)
        for stroke in strokes.reversed() {
            guard let geom = stroke.geometry else { continue }
            if geom.hitTestBody(pagePoint, tolerance: tolerance) {
                return stroke
            }
        }
        return nil
    }

    private func beginShapeCreation(at viewPoint: CGPoint) -> ActiveInteraction? {
        guard let pageIdx = pageIndex(at: viewPoint) else { return nil }
        refreshSnapPoints(forPage: pageIdx)
        let rawPage = pagePoint(fromView: viewPoint, pageIndex: pageIdx)
        let pageThreshold = 10 / viewScale(for: pageIdx)
        let startSnap = GeometrySnapEngine.nearestPoint(to: rawPage, in: cachedPageSnapPoints, threshold: pageThreshold)
        let startPage = startSnap?.point ?? rawPage
        if let startSnap {
            let transform = pageToViewTransform(for: pageIdx)
            updateSnapFeedback(SnapPoint(point: startSnap.point.applying(transform), kind: startSnap.kind))
        }
        configureLiveLayerForCurrentTool()
        return .shapeCreate(pageIndex: pageIdx, preset: liveTool.shapePreset, startPage: startPage,
                            rawStartView: viewPoint, currentPrimitive: nil)
    }

    private func renderShapeCreationPreview(_ primitive: GeometricPrimitive, pageIndex: Int) {
        let stroke = makeGeometricStroke(primitive, allowFill: liveTool.shapeFilled)
        let transform = pageToViewTransform(for: pageIndex)
        setLivePath(stroke.outlinePath(transform: transform, finished: true),
                    fillPath: stroke.fillPath(transform: transform),
                    fillColor: stroke.fillColor?.cgColor)
    }

    // MARK: Compass & Active Geometry Interaction Dispatch

    private func beginGeometryAidInteraction(at viewPoint: CGPoint, allowDrawing: Bool) -> ActiveInteraction? {
        if session.geometryAid == .protractor {
            let hit = protractorState.hitTest(viewPoint, in: view.bounds)
            switch hit {
            case .none:
                return nil
            case .autoDetectButton, .cycleAngleButton, .stampAngleButton, .closeButton:
                return .protractorButton(hit, startPoint: viewPoint)
            case .center:
                refreshAllVisibleViewSnapPoints()
                let offset = CGPoint(x: protractorState.center.x - viewPoint.x, y: protractorState.center.y - viewPoint.y)
                return .protractorCenter(grabOffset: offset)
            case .ray1Handle:
                refreshAllVisibleViewSnapPoints()
                return .protractorRay1
            case .ray2Handle:
                refreshAllVisibleViewSnapPoints()
                return .protractorRay2
            case .ringRotate:
                let startAngle = atan2(viewPoint.y - protractorState.center.y, viewPoint.x - protractorState.center.x)
                return .protractorRotate(lastAngle: startAngle)
            }
        }
        guard session.geometryAid == .compass else { return nil }
        let hit = compassState.hitTest(viewPoint, in: view.bounds)
        switch hit {
        case .none:
            return nil
        case .lockButton, .centerMarkButton, .fullCircleButton:
            return .compassButton(hit, startPoint: viewPoint)
        case .needle:
            refreshAllVisibleViewSnapPoints()
            let offset = CGPoint(x: compassState.center.x - viewPoint.x, y: compassState.center.y - viewPoint.y)
            return .compassNeedle(grabOffset: offset)
        case .resizeHandle:
            refreshAllVisibleViewSnapPoints()
            geometryOverlay.isResizingCompass = true
            return .compassResize
        case .drawCircle:
            guard allowDrawing, let pageIdx = pageIndex(at: compassState.center) else { return nil }
            let startAngle = atan2(viewPoint.y - compassState.center.y, viewPoint.x - compassState.center.x)
            compassState.armAngle = startAngle
            geometryOverlay.compass = compassState
            configureLiveLayerForCurrentTool()
            let sweep = CompassSweep(startAngle: startAngle)
            geometryOverlay.activeCompassSweep = sweep
            renderCompassLiveSweep(sweep, pageIndex: pageIdx)
            return .compassDraw(pageIndex: pageIdx, sweep: sweep, crossedCloseHaptic: false)
        }
    }

    private func handleGeometryAidMoved(to viewPoint: CGPoint) -> Bool {
        switch activeInteraction {
        case .none, .normalInput:
            return false

        case let .compassNeedle(grabOffset):
            let rawCenter = CGPoint(x: viewPoint.x + grabOffset.x, y: viewPoint.y + grabOffset.y)
            let snap = compassState.moveCenter(to: rawCenter, snapPoints: cachedViewSnapPoints)
            geometryOverlay.compass = compassState
            updateSnapFeedback(snap)
            pushPresentationOverlay()
            return true

        case .compassResize:
            let snap = compassState.resize(withHandleAt: viewPoint, snapPoints: cachedViewSnapPoints)
            geometryOverlay.compass = compassState
            updateSnapFeedback(snap)
            pushPresentationOverlay()
            return true

        case let .protractorCenter(grabOffset):
            let rawCenter = CGPoint(x: viewPoint.x + grabOffset.x, y: viewPoint.y + grabOffset.y)
            let snap = protractorState.moveCenter(to: rawCenter, snapPoints: cachedViewSnapPoints)
            if snap != nil {
                autoDetectProtractorAngle(allowImageFallback: false, triggerHaptic: false)
            } else if protractorState.autoDetectedSource != nil {
                protractorState.autoDetectedSource = nil
                protractorState.detectedRayAngles = []
            }
            geometryOverlay.protractor = protractorState
            updateSnapFeedback(snap)
            pushPresentationOverlay()
            return true

        case .protractorRay1:
            let snap = protractorState.aimRay1(to: viewPoint, snapPoints: cachedViewSnapPoints)
            geometryOverlay.protractor = protractorState
            updateSnapFeedback(snap)
            pushPresentationOverlay()
            return true

        case .protractorRay2:
            let snap = protractorState.aimRay2(to: viewPoint, snapPoints: cachedViewSnapPoints)
            geometryOverlay.protractor = protractorState
            updateSnapFeedback(snap)
            pushPresentationOverlay()
            return true

        case let .protractorRotate(lastAngle):
            let currentAngle = atan2(viewPoint.y - protractorState.center.y, viewPoint.x - protractorState.center.x)
            let delta = atan2(sin(currentAngle - lastAngle), cos(currentAngle - lastAngle))
            protractorState.rotateBoth(by: delta)
            activeInteraction = .protractorRotate(lastAngle: currentAngle)
            geometryOverlay.protractor = protractorState
            pushPresentationOverlay()
            return true

        case .compassButton, .protractorButton, .selectedAction, .lassoAction:
            return true

        case var .compassDraw(pageIdx, sweep, crossedCloseHaptic):
            sweep.advance(to: viewPoint, center: compassState.center)
            compassState.armAngle = sweep.currentAngle
            geometryOverlay.compass = compassState
            geometryOverlay.activeCompassSweep = sweep
            if sweep.isFullCircle, !crossedCloseHaptic {
                crossedCloseHaptic = true
                haptic.impactOccurred()
            }
            activeInteraction = .compassDraw(pageIndex: pageIdx, sweep: sweep, crossedCloseHaptic: crossedCloseHaptic)
            renderCompassLiveSweep(sweep, pageIndex: pageIdx)
            return true

        case let .shapeCreate(pageIdx, preset, startPage, rawStartView, _):
            let currentPage = pagePoint(fromView: viewPoint, pageIndex: pageIdx)
            let pageThreshold = 10 / viewScale(for: pageIdx)
            let built = ShapeBuilder.build(preset: preset, from: startPage, to: currentPage,
                                           snapPoints: cachedPageSnapPoints, snapThreshold: pageThreshold)
            if let snap = built.snapped {
                let transform = pageToViewTransform(for: pageIdx)
                updateSnapFeedback(SnapPoint(point: snap.point.applying(transform), kind: snap.kind))
            } else {
                updateSnapFeedback(nil)
            }
            activeInteraction = .shapeCreate(pageIndex: pageIdx, preset: preset, startPage: startPage,
                                             rawStartView: rawStartView, currentPrimitive: built.primitive)
            renderShapeCreationPreview(built.primitive, pageIndex: pageIdx)
            return true

        case var .selectedHandle(index, context):
            let currentPage = pagePoint(fromView: viewPoint, pageIndex: context.pageIndex)
            let pageThreshold = 10 / viewScale(for: context.pageIndex)
            let moved = context.basePagePrimitive.movingHandle(at: index, to: currentPage,
                                                               snapPoints: cachedPageSnapPoints,
                                                               snapThreshold: pageThreshold)
            context.currentPagePrimitive = moved.primitive
            if let snap = moved.snapped {
                let transform = pageToViewTransform(for: context.pageIndex)
                updateSnapFeedback(SnapPoint(point: snap.point.applying(transform), kind: snap.kind))
            } else {
                updateSnapFeedback(nil)
            }
            activeInteraction = .selectedHandle(index: index, context: context)
            renderEditedShape(stroke: context.originalStroke, pageIndex: context.pageIndex,
                              pagePrimitive: context.currentPagePrimitive)
            return true

        case var .selectedBody(startPage, context):
            let currentPage = pagePoint(fromView: viewPoint, pageIndex: context.pageIndex)
            let delta = CGPoint(x: currentPage.x - startPage.x, y: currentPage.y - startPage.y)
            context.currentPagePrimitive = context.basePagePrimitive.translated(by: delta)
            activeInteraction = .selectedBody(startPage: startPage, context: context)
            renderEditedShape(stroke: context.originalStroke, pageIndex: context.pageIndex,
                              pagePrimitive: context.currentPagePrimitive)
            return true

        case var .lassoDraw(pageIdx, pagePoints, rawStartView):
            let currentPage = pagePoint(fromView: viewPoint, pageIndex: pageIdx)
            if let last = pagePoints.last, hypot(currentPage.x - last.x, currentPage.y - last.y) >= 2.5 {
                pagePoints.append(currentPage)
            }
            activeInteraction = .lassoDraw(pageIndex: pageIdx, pagePoints: pagePoints, rawStartView: rawStartView)
            let transform = pageToViewTransform(for: pageIdx)
            geometryOverlay.activeLassoPath = pagePoints.map { $0.applying(transform) }
            return true

        case var .lassoMove(startPage, context):
            let currentPage = pagePoint(fromView: viewPoint, pageIndex: context.pageIndex)
            let delta = CGPoint(x: currentPage.x - startPage.x, y: currentPage.y - startPage.y)
            context.currentTranslation = delta
            activeInteraction = .lassoMove(startPage: startPage, context: context)
            applyLassoLivePreviewTransform(context: context)
            return true

        case var .lassoScale(corner, startCornerPage, context):
            let currentPage = pagePoint(fromView: viewPoint, pageIndex: context.pageIndex)
            let pivotPage = context.pivotPage
            let v0x = startCornerPage.x - pivotPage.x
            let v0y = startCornerPage.y - pivotPage.y
            let d0 = max(16, hypot(v0x, v0y))
            let ux = v0x / d0
            let uy = v0y / d0
            let proj = (currentPage.x - pivotPage.x) * ux + (currentPage.y - pivotPage.y) * uy
            context.currentScale = max(0.25, min(4.0, proj / d0))
            activeInteraction = .lassoScale(corner: corner, startCornerPage: startCornerPage, context: context)
            applyLassoLivePreviewTransform(context: context)
            return true
        }
    }

    private func handleGeometryAidEnded(at viewPoint: CGPoint) -> Bool {
        let current = activeInteraction
        switch current {
        case .none, .normalInput:
            return false

        case .compassNeedle, .compassResize, .protractorRay1, .protractorRay2, .protractorRotate:
            finishGeometryAidInteraction()
            return true

        case .protractorCenter:
            finishGeometryAidInteraction()
            autoDetectProtractorAngle(allowImageFallback: true, triggerHaptic: true)
            return true

        case let .compassButton(button, startPoint):
            if hypot(viewPoint.x - startPoint.x, viewPoint.y - startPoint.y) < 28 {
                executeCompassButton(button)
            }
            finishGeometryAidInteraction()
            return true

        case let .protractorButton(button, startPoint):
            if hypot(viewPoint.x - startPoint.x, viewPoint.y - startPoint.y) < 28 {
                executeProtractorButton(button)
            }
            finishGeometryAidInteraction()
            return true

        case let .selectedAction(action, startPoint):
            if hypot(viewPoint.x - startPoint.x, viewPoint.y - startPoint.y) < 28 {
                executeSelectedShapeAction(action)
            }
            finishGeometryAidInteraction()
            return true

        case let .lassoAction(action, startPoint):
            if hypot(viewPoint.x - startPoint.x, viewPoint.y - startPoint.y) < 28 {
                executeLassoAction(action)
            }
            finishGeometryAidInteraction()
            return true

        case let .lassoDraw(pageIdx, pagePoints, rawStartView):
            finishGeometryAidInteraction()
            geometryOverlay.activeLassoPath = []
            let dragDist = hypot(viewPoint.x - rawStartView.x, viewPoint.y - rawStartView.y)
            let strokes = session.strokes(onPage: pageIdx)
            if dragDist < 8, pagePoints.count <= 4 {
                let pt = pagePoint(fromView: viewPoint, pageIndex: pageIdx)
                let pageTol = 14 / viewScale(for: pageIdx)
                if let hitID = LassoEngine.hitTestSingleStroke(from: strokes, origins: [:],
                                                               at: pt, tolerance: pageTol, cache: geometryCache) {
                    selectLassoStrokes([hitID], onPage: pageIdx)
                    haptic.impactOccurred()
                }
            } else {
                let ids = LassoEngine.selectStrokeIDs(from: strokes, origins: [:],
                                                      polygon: pagePoints, cache: geometryCache)
                if !ids.isEmpty {
                    selectLassoStrokes(ids, onPage: pageIdx)
                    haptic.impactOccurred()
                }
            }
            return true

        case let .lassoMove(_, context), let .lassoScale(_, _, context):
            finishGeometryAidInteraction()
            commitLassoTransform(context)
            return true

        case var .compassDraw(pageIdx, sweep, _):
            sweep.advance(to: viewPoint, center: compassState.center)
            finishGeometryAidInteraction()
            let centerPage = pagePoint(fromView: compassState.center, pageIndex: pageIdx)
            let radiusPage = compassState.radius / viewScale(for: pageIdx)
            setLivePath(nil)
            if let primitive = sweep.primitive(center: centerPage, radius: radiusPage,
                                               showCenterMark: compassState.showCenterMark) {
                let stroke = makeGeometricStroke(primitive)
                session.addStroke(stroke, page: pageIdx)
            }
            return true

        case let .shapeCreate(pageIdx, preset, startPage, rawStartView, _):
            finishGeometryAidInteraction()
            let dragDist = hypot(viewPoint.x - rawStartView.x, viewPoint.y - rawStartView.y)
            setLivePath(nil)
            if dragDist < 8 {
                let pt = pagePoint(fromView: viewPoint, pageIndex: pageIdx)
                if let hitStroke = hitTestExistingGeometricStroke(atPage: pt, pageIndex: pageIdx) {
                    selectStroke(hitStroke.id, onPage: pageIdx)
                    haptic.impactOccurred()
                }
                return true
            }
            let currentPage = pagePoint(fromView: viewPoint, pageIndex: pageIdx)
            let pageThreshold = 10 / viewScale(for: pageIdx)
            let built = ShapeBuilder.build(preset: preset, from: startPage, to: currentPage,
                                           snapPoints: cachedPageSnapPoints, snapThreshold: pageThreshold)
            let stroke = makeGeometricStroke(built.primitive, allowFill: liveTool.shapeFilled)
            session.addStroke(stroke, page: pageIdx)
            selectStroke(stroke.id, onPage: pageIdx)
            return true

        case let .selectedHandle(_, context), let .selectedBody(_, context):
            finishGeometryAidInteraction()
            commitEditedShape(context)
            return true
        }
    }

    private func finishGeometryAidInteraction() {
        activeInteraction = .none
        geometryOverlay.activeCompassSweep = nil
        geometryOverlay.isResizingCompass = false
        geometryOverlay.isEditingSelectedShape = false
        geometryOverlay.isTransformingLasso = false
        updateSnapFeedback(nil)
    }

    private func cancelGeometryAidInteraction() {
        switch activeInteraction {
        case .compassDraw, .shapeCreate:
            setLivePath(nil)
        case let .selectedHandle(_, context), let .selectedBody(_, context):
            overlays[context.pageIndex]?.hiddenStrokeIDs.remove(context.strokeID)
            setLivePath(nil)
        case .lassoDraw:
            geometryOverlay.activeLassoPath = []
        case let .lassoMove(_, context), let .lassoScale(_, _, context):
            clearLassoPreviewLayers()
            overlays[context.pageIndex]?.hiddenStrokeIDs.subtract(context.selectedIDs)
            pushPresentationOverlay()
        default:
            break
        }
        finishGeometryAidInteraction()
        refreshSelectedShapeOverlay()
        refreshLassoSelectionOverlay()
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
            guard let pageIdx = pageIndex(at: compassState.center) else { return }
            liveTool = session.tool
            let centerPage = pagePoint(fromView: compassState.center, pageIndex: pageIdx)
            let radiusPage = compassState.radius / viewScale(for: pageIdx)
            let stroke = makeGeometricStroke(.circle(center: centerPage, radius: radiusPage,
                                                     showCenterMark: compassState.showCenterMark))
            session.addStroke(stroke, page: pageIdx)
            haptic.impactOccurred()
        default:
            break
        }
    }

    private func executeProtractorButton(_ button: ProtractorState.HitZone) {
        switch button {
        case .autoDetectButton:
            autoDetectProtractorAngle(allowImageFallback: true, triggerHaptic: true, announceFailure: true)
        case .cycleAngleButton:
            protractorState.cycleAngle()
            geometryOverlay.protractor = protractorState
            pushPresentationOverlay()
            haptic.impactOccurred()
        case .stampAngleButton:
            guard let pageIdx = pageIndex(at: protractorState.center) else { return }
            liveTool = session.tool
            let centerPage = pagePoint(fromView: protractorState.center, pageIndex: pageIdx)
            let arcRadiusPage = min(34, protractorState.radius * 0.28) / viewScale(for: pageIdx)
            if let primitive = protractorState.stampPrimitive(center: centerPage, radius: arcRadiusPage) {
                let stroke = makeGeometricStroke(primitive)
                session.addStroke(stroke, page: pageIdx)
                haptic.impactOccurred()
                NotificationCenter.default.post(
                    name: .quillmarkUndoRedoFeedback,
                    object: nil,
                    userInfo: ["message": "已标注 \(protractorState.formattedDegrees)"]
                )
            }
        case .closeButton:
            session.geometryAid = .none
            haptic.impactOccurred()
        default:
            break
        }
    }

    /// Automatically measures the angle at `protractorState.center`: first checks exact vector strokes
    /// on the page, then falls back to local radial contrast scanning of printed PDF diagrams.
    private func autoDetectProtractorAngle(allowImageFallback: Bool, triggerHaptic: Bool, announceFailure: Bool = false) {
        guard session.geometryAid == .protractor else { return }
        if let pageIdx = pageIndex(at: protractorState.center) {
            let centerPage = pagePoint(fromView: protractorState.center, pageIndex: pageIdx)
            let pageTol = 16 / viewScale(for: pageIdx)
            let vectorRays = ProtractorAngleDetector.detectVectorRays(
                at: centerPage,
                from: session.strokes(onPage: pageIdx),
                origins: [:],
                tolerance: pageTol
            )
            if protractorState.applyDetectedRays(vectorRays, source: .vector) {
                geometryOverlay.protractor = protractorState
                pushPresentationOverlay()
                if triggerHaptic { haptic.impactOccurred(intensity: 0.7) }
                return
            }
        }

        guard allowImageFallback, pdfView.bounds.width > 48, pdfView.bounds.height > 48 else {
            if announceFailure {
                NotificationCenter.default.post(
                    name: .quillmarkUndoRedoFeedback,
                    object: nil,
                    userInfo: ["message": "未检测到明显角边，请将圆心对准顶点或手动拖射线"]
                )
            }
            return
        }
        let patchSize: CGFloat = 144
        let half = patchSize / 2
        let ptInPDF = view.convert(protractorState.center, to: pdfView)
        guard pdfView.bounds.contains(ptInPDF) else { return }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: patchSize, height: patchSize), format: format)
        let patchImage = renderer.image { rendererCtx in
            let ctx = rendererCtx.cgContext
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: patchSize, height: patchSize))
            ctx.translateBy(x: half - ptInPDF.x, y: half - ptInPDF.y)
            pdfView.drawHierarchy(in: pdfView.bounds, afterScreenUpdates: false)
        }
        guard let cgImage = patchImage.cgImage,
              let detected = ProtractorAngleDetector.detectImageRays(in: cgImage, center: CGPoint(x: half, y: half)) else {
            if announceFailure {
                NotificationCenter.default.post(
                    name: .quillmarkUndoRedoFeedback,
                    object: nil,
                    userInfo: ["message": "未检测到明显角边，请将圆心对准顶点或手动拖射线"]
                )
            }
            return
        }
        protractorState.center.x += detected.vertexOffset.x
        protractorState.center.y += detected.vertexOffset.y
        if protractorState.applyDetectedRays(detected.rayAngles, source: .image) {
            geometryOverlay.protractor = protractorState
            pushPresentationOverlay()
            if triggerHaptic { haptic.impactOccurred(intensity: 0.7) }
        }
    }

    private func handleGeometryControlTap(at viewPoint: CGPoint) {
        if let lasso = geometryOverlay.lassoSelection,
           case let .action(button) = lasso.hitTest(viewPoint, in: view.bounds) {
            executeLassoAction(button)
            return
        }
        if let selected = geometryOverlay.selectedShape,
           case let .action(button) = selected.hitTest(viewPoint, in: view.bounds, bodyHit: false) {
            executeSelectedShapeAction(button)
            return
        }
        if session.geometryAid == .protractor {
            let hit = protractorState.hitTest(viewPoint, in: view.bounds)
            switch hit {
            case .autoDetectButton, .cycleAngleButton, .stampAngleButton, .closeButton:
                executeProtractorButton(hit)
            default:
                break
            }
            return
        }
        guard session.geometryAid == .compass else { return }
        let hit = compassState.hitTest(viewPoint, in: view.bounds)
        if hit == .lockButton || hit == .centerMarkButton || hit == .fullCircleButton {
            executeCompassButton(hit)
        }
    }

    private func beginFingerGeometryDrag(at viewPoint: CGPoint) {
        if let lassoEdit = beginLassoSelectionInteraction(at: viewPoint) {
            fingerControlInteraction = lassoEdit
            return
        }
        if let edit = beginSelectedShapeInteraction(at: viewPoint) {
            fingerControlInteraction = edit
            return
        }
        fingerControlInteraction = beginGeometryAidInteraction(at: viewPoint, allowDrawing: false) ?? .none
    }

    private func updateFingerGeometryDrag(to viewPoint: CGPoint) {
        let saved = activeInteraction
        activeInteraction = fingerControlInteraction
        _ = handleGeometryAidMoved(to: viewPoint)
        fingerControlInteraction = activeInteraction
        activeInteraction = saved
    }

    private func endFingerGeometryDrag() {
        let saved = activeInteraction
        activeInteraction = fingerControlInteraction
        switch activeInteraction {
        case let .lassoMove(_, context), let .lassoScale(_, _, context):
            finishGeometryAidInteraction()
            commitLassoTransform(context)
        case let .selectedHandle(_, context), let .selectedBody(_, context):
            finishGeometryAidInteraction()
            commitEditedShape(context)
        case .protractorCenter:
            finishGeometryAidInteraction()
            autoDetectProtractorAngle(allowImageFallback: true, triggerHaptic: true)
        default:
            geometryOverlay.isResizingCompass = false
            geometryOverlay.isEditingSelectedShape = false
            geometryOverlay.isTransformingLasso = false
            updateSnapFeedback(nil)
        }
        fingerControlInteraction = .none
        activeInteraction = saved
    }

    // MARK: Lasso Selection, GPU Move/Scale Preview & Batch Actions

    private func selectLassoStrokes(_ ids: [UUID], onPage pageIndex: Int) {
        lassoSelectedIDs = ids
        lassoPageIndex = pageIndex
        refreshLassoSelectionOverlay()
    }

    private func clearLassoSelection() {
        guard !lassoSelectedIDs.isEmpty || geometryOverlay.lassoSelection != nil || !geometryOverlay.activeLassoPath.isEmpty else {
            return
        }
        overlays[lassoPageIndex]?.hiddenStrokeIDs.subtract(lassoSelectedIDs)
        lassoSelectedIDs.removeAll()
        geometryOverlay.activeLassoPath = []
        geometryOverlay.isTransformingLasso = false
        geometryOverlay.lassoSelection = nil
    }

    private func refreshLassoSelectionOverlay() {
        guard !lassoSelectedIDs.isEmpty else {
            if geometryOverlay.lassoSelection != nil {
                geometryOverlay.lassoSelection = nil
            }
            return
        }
        switch activeInteraction {
        case .lassoMove, .lassoScale:
            return
        default:
            break
        }
        let idSet = Set(lassoSelectedIDs)
        let selected = session.strokes(onPage: lassoPageIndex).filter { idSet.contains($0.id) }
        guard !selected.isEmpty else {
            clearLassoSelection()
            return
        }
        let pageBox = LassoEngine.documentBounds(of: selected, origins: [:], cache: geometryCache)
        guard !pageBox.isNull, pageBox.minX.isFinite, pageBox.minY.isFinite else {
            clearLassoSelection()
            return
        }
        let viewBox = pageBox.applying(pageToViewTransform(for: lassoPageIndex))
        let firstColor = selected.first?.color
        let sharedColor = selected.allSatisfy({ $0.color == firstColor }) ? firstColor : nil
        geometryOverlay.lassoSelection = LassoSelectionOverlay(
            strokeIDs: selected.map(\.id),
            boundingBox: viewBox,
            activeColor: sharedColor
        )
    }

    private func beginLassoDraw(at viewPoint: CGPoint) -> ActiveInteraction? {
        guard let pageIdx = pageIndex(at: viewPoint) else { return nil }
        let pagePt = pagePoint(fromView: viewPoint, pageIndex: pageIdx)
        geometryOverlay.activeLassoPath = [viewPoint]
        return .lassoDraw(pageIndex: pageIdx, pagePoints: [pagePt], rawStartView: viewPoint)
    }

    private func beginLassoSelectionInteraction(at viewPoint: CGPoint) -> ActiveInteraction? {
        guard !lassoSelectedIDs.isEmpty,
              let overlay = geometryOverlay.lassoSelection else { return nil }
        let hit = overlay.hitTest(viewPoint, in: view.bounds)
        switch hit {
        case .none:
            return nil
        case let .action(button):
            return .lassoAction(button, startPoint: viewPoint)
        case .body:
            guard let context = startLassoTransform() else { return nil }
            let startPage = pagePoint(fromView: viewPoint, pageIndex: context.pageIndex)
            return .lassoMove(startPage: startPage, context: context)
        case let .handle(corner):
            guard var context = startLassoTransform() else { return nil }
            context.pivotPage = overlay.oppositeCorner(of: corner, in: context.basePageBox)
            let startCornerPage = overlay.cornerPoint(of: corner, in: context.basePageBox)
            return .lassoScale(corner: corner, startCornerPage: startCornerPage, context: context)
        }
    }

    private func startLassoTransform() -> LassoTransformContext? {
        let pageIdx = lassoPageIndex
        let originalStrokes = session.strokes(onPage: pageIdx)
        let selectedSet = Set(lassoSelectedIDs)
        let selectedStrokes = originalStrokes.filter { selectedSet.contains($0.id) }
        guard !selectedStrokes.isEmpty else { return nil }

        let basePageBox = LassoEngine.documentBounds(of: selectedStrokes, origins: [:], cache: geometryCache)
        guard !basePageBox.isNull else { return nil }

        let transform = pageToViewTransform(for: pageIdx)
        var strokesByID: [UUID: InkStroke] = [:]
        clearLassoPreviewLayers()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewFillContainer.setAffineTransform(.identity)
        lassoPreviewContainer.setAffineTransform(.identity)
        lassoPreviewFillContainer.bounds = view.bounds
        lassoPreviewFillContainer.position = .zero
        lassoPreviewContainer.bounds = view.bounds
        lassoPreviewContainer.position = .zero

        var entries: [LassoPreviewEntry] = []
        for stroke in selectedStrokes {
            strokesByID[stroke.id] = stroke
            let viewPath = stroke.outlinePath(transform: transform, finished: true)
            let fillPath = stroke.fillPath(transform: transform)
            let fillColor = stroke.fillColor?.cgColor

            if let fillPath, let fillColor {
                let fl = CAShapeLayer()
                fl.frame = lassoPreviewFillContainer.bounds
                fl.fillRule = .nonZero
                fl.opacity = 0.18
                fl.fillColor = fillColor
                fl.path = fillPath
                lassoPreviewFillContainer.addSublayer(fl)
            }

            let layer = CAShapeLayer()
            layer.frame = lassoPreviewContainer.bounds
            layer.fillRule = .nonZero
            layer.path = viewPath
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

            entries.append(LassoPreviewEntry(
                baseViewPath: viewPath,
                baseFillPath: fillPath,
                strokeColor: stroke.color.cgColor,
                fillColor: fillColor,
                opacity: opacity,
                isHighlighter: stroke.isHighlighter
            ))
        }
        lassoPreviewEntries = entries
        lassoPreviewTransform = .identity
        CATransaction.commit()

        overlays[pageIdx]?.hiddenStrokeIDs.formUnion(selectedSet)
        geometryOverlay.isTransformingLasso = true
        pushPresentationOverlay()

        return LassoTransformContext(
            pageIndex: pageIdx,
            originalStrokes: originalStrokes,
            selectedIDs: selectedSet,
            strokesByID: strokesByID,
            basePageBox: basePageBox,
            baseViewTransform: transform
        )
    }

    private func applyLassoLivePreviewTransform(context: LassoTransformContext) {
        let baseT = context.baseViewTransform
        let previewT: CGAffineTransform
        if abs(context.currentScale - 1) > 1e-4 {
            let pivotView = context.pivotPage.applying(baseT)
            let s = context.currentScale
            previewT = CGAffineTransform(translationX: pivotView.x, y: pivotView.y)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -pivotView.x, y: -pivotView.y)
        } else {
            let originView = CGPoint.zero.applying(baseT)
            let shiftedView = context.currentTranslation.applying(baseT)
            previewT = CGAffineTransform(translationX: shiftedView.x - originView.x,
                                         y: shiftedView.y - originView.y)
        }

        lassoPreviewTransform = previewT
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewFillContainer.setAffineTransform(previewT)
        lassoPreviewContainer.setAffineTransform(previewT)
        CATransaction.commit()

        if var overlay = geometryOverlay.lassoSelection {
            let baseViewBox = context.basePageBox.applying(baseT)
            overlay.boundingBox = baseViewBox.applying(previewT)
            geometryOverlay.lassoSelection = overlay
        }
        pushPresentationOverlay()
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
        let isUnchanged = abs(context.currentScale - 1) < 1e-3
            && hypot(context.currentTranslation.x, context.currentTranslation.y) < 0.5
        clearLassoPreviewLayers()
        overlays[context.pageIndex]?.hiddenStrokeIDs.subtract(context.selectedIDs)

        if isUnchanged {
            overlays[context.pageIndex]?.sync()
            refreshLassoSelectionOverlay()
            pushPresentationOverlay()
            return
        }

        let after = context.originalStrokes.map { stroke -> InkStroke in
            guard let original = context.strokesByID[stroke.id] else { return stroke }
            return LassoEngine.transformStroke(original,
                                               scale: context.currentScale,
                                               around: context.pivotPage,
                                               translation: context.currentTranslation)
        }
        session.replaceStrokes(onPage: context.pageIndex, before: context.originalStrokes, after: after)
        refreshLassoSelectionOverlay()
        pushPresentationOverlay()
    }

    private func executeLassoAction(_ action: LassoSelectionOverlay.ActionButton) {
        guard !lassoSelectedIDs.isEmpty else { return }
        let pageIdx = lassoPageIndex
        let before = session.strokes(onPage: pageIdx)
        let selectedSet = Set(lassoSelectedIDs)

        switch action {
        case let .color(idx):
            guard idx >= 0, idx < ToolSettings.palette.count else { return }
            let newColor = ToolSettings.palette[idx]
            let after = before.map { stroke -> InkStroke in
                guard selectedSet.contains(stroke.id) else { return stroke }
                var copy = stroke
                copy.color = newColor
                if copy.fillColor != nil {
                    copy.fillColor = newColor
                }
                return copy
            }
            session.replaceStrokes(onPage: pageIdx, before: before, after: after)
            refreshLassoSelectionOverlay()
            haptic.impactOccurred()

        case .duplicate:
            var newIDs: [UUID] = []
            var copies: [InkStroke] = []
            for stroke in before where selectedSet.contains(stroke.id) {
                var copy = stroke.translated(by: CGPoint(x: 24, y: 24))
                copy.id = UUID()
                newIDs.append(copy.id)
                copies.append(copy)
            }
            guard !copies.isEmpty else { return }
            let after = before + copies
            lassoSelectedIDs = newIDs
            session.replaceStrokes(onPage: pageIdx, before: before, after: after)
            refreshLassoSelectionOverlay()
            haptic.impactOccurred()

        case .delete:
            let after = before.filter { !selectedSet.contains($0.id) }
            clearLassoSelection()
            session.replaceStrokes(onPage: pageIdx, before: before, after: after)
            haptic.impactOccurred()
        }
    }

    private func renderCompassLiveSweep(_ sweep: CompassSweep, pageIndex: Int) {
        let centerPage = pagePoint(fromView: compassState.center, pageIndex: pageIndex)
        let radiusPage = compassState.radius / viewScale(for: pageIndex)
        guard let primitive = sweep.primitive(center: centerPage, radius: radiusPage,
                                              showCenterMark: compassState.showCenterMark) else {
            setLivePath(nil)
            return
        }
        let stroke = makeGeometricStroke(primitive)
        setLivePath(stroke.outlinePath(transform: pageToViewTransform(for: pageIndex), finished: true))
    }

    private func makeGeometricStroke(_ primitive: GeometricPrimitive, allowFill: Bool = false) -> InkStroke {
        if liveTool.kind == .tape {
            return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.tapeColor,
                             width: liveTool.tapeWidth, smoothing: 0, points: [],
                             tool: .tape, lineStyle: .solid, revealed: false, geometry: primitive)
        }
        let color = liveTool.activeStrokeColor
        let fill = (allowFill && primitive.supportsFill) ? color : nil
        return InkStroke(id: UUID(), pen: .ballpoint, color: color,
                         width: liveTool.activeStrokeWidth, smoothing: 0, points: [],
                         tool: .pen, lineStyle: liveTool.activeLineStyle, geometry: primitive, fillColor: fill)
    }

    // MARK: Drawing (Pen, Tape & Draw-and-Hold)

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
            liveLayer.fillColor = liveTool.activeStrokeColor.cgColor
            liveLayer.opacity = 1
            liveLayer.compositingFilter = nil
            liveLayer.strokeColor = nil
            liveLayer.lineDashPattern = nil
        }
        CATransaction.commit()
    }

    private func drawBegan(_ touch: UITouch, event: UIEvent?) {
        guard let pageIdx = pageIndex(at: touch.location(in: view)) else { return }
        activeDrawPageIndex = pageIdx
        holdTimer?.cancel()
        holdTimer = nil
        snappedBaseShape = nil
        snappedCurrentShape = nil
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        lastCommitted = nil
        liveStartTime = touch.timestamp

        configureLiveLayerForCurrentTool()

        holdAnchorViewPoint = touch.location(in: view)
        append(event?.coalescedTouches(for: touch) ?? [touch])
        updateLiveStroke(predicted: [])
        scheduleHoldRecognitionIfNeeded()
    }

    private func drawMoved(_ touch: UITouch, event: UIEvent?) {
        if let baseShape = snappedBaseShape {
            let pageIdx = activeDrawPageIndex
            let currentPage = pagePoint(touch, pageIndex: pageIdx)
            let pageThreshold = 10 / viewScale(for: pageIdx)
            let transform = pageToViewTransform(for: pageIdx)
            switch baseShape {
            case let .line(start, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: currentPage, in: cachedPageSnapPoints,
                                                              threshold: pageThreshold, excluding: start, excludeRadius: 8) {
                    snappedCurrentShape = .line(start: start, end: snap.point)
                    updateSnapFeedback(SnapPoint(point: snap.point.applying(transform), kind: snap.kind))
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: currentPage, initialAnchor: snapDragOriginPagePoint)
                    updateSnapFeedback(nil)
                }
            case let .arrow(start, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: currentPage, in: cachedPageSnapPoints,
                                                              threshold: pageThreshold, excluding: start, excludeRadius: 8) {
                    snappedCurrentShape = .arrow(start: start, end: snap.point)
                    updateSnapFeedback(SnapPoint(point: snap.point.applying(transform), kind: snap.kind))
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: currentPage, initialAnchor: snapDragOriginPagePoint)
                    updateSnapFeedback(nil)
                }
            case let .circle(center, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: currentPage, in: cachedPageSnapPoints,
                                                              threshold: pageThreshold, excluding: center, excludeRadius: 12) {
                    let r = max(12, hypot(snap.point.x - center.x, snap.point.y - center.y))
                    snappedCurrentShape = .circle(center: center, radius: r)
                    updateSnapFeedback(SnapPoint(point: snap.point.applying(transform), kind: snap.kind))
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: currentPage, initialAnchor: snapDragOriginPagePoint)
                    updateSnapFeedback(nil)
                }
            case let .parabola(vertex, _, _, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: currentPage, in: cachedPageSnapPoints,
                                                              threshold: pageThreshold, excluding: vertex, excludeRadius: 12) {
                    snappedCurrentShape = baseShape.adjusted(to: snap.point, initialAnchor: snapDragOriginPagePoint)
                    updateSnapFeedback(SnapPoint(point: snap.point.applying(transform), kind: snap.kind))
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: currentPage, initialAnchor: snapDragOriginPagePoint)
                    updateSnapFeedback(nil)
                }
            case .rectangle, .polygon:
                snappedCurrentShape = baseShape.adjusted(to: currentPage, initialAnchor: snapDragOriginPagePoint)
                updateSnapFeedback(nil)
            }
            renderSnappedLiveShape()
            return
        }

        append(event?.coalescedTouches(for: touch) ?? [touch])
        let predicted = liveTool.prediction ? (event?.predictedTouches(for: touch) ?? []) : []
        updateLiveStroke(predicted: predicted)

        let viewPos = touch.location(in: view)
        if hypot(viewPos.x - holdAnchorViewPoint.x, viewPos.y - holdAnchorViewPoint.y) > 6 {
            holdAnchorViewPoint = viewPos
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
            commitSnappedShape(snapped)
            return
        }
        append(event?.coalescedTouches(for: touch) ?? [touch])
        commitLiveStroke()
    }

    private var canDrawAndHold: Bool {
        liveTool.kind == .pen && liveTool.drawAndHold
    }

    private func scheduleHoldRecognitionIfNeeded() {
        holdTimer?.cancel()
        holdTimer = nil
        guard canDrawAndHold else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.attemptHoldShapeSnap()
        }
        holdTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40, execute: work)
    }

    private func attemptHoldShapeSnap() {
        holdTimer = nil
        guard snappedBaseShape == nil, livePoints.count >= 4 else { return }
        let pageIdx = activeDrawPageIndex
        let pts = livePoints.map(\.location)
        guard var shape = ShapeRecognizer.recognize(pts) else { return }

        refreshSnapPoints(forPage: pageIdx)
        let pageThreshold = 10 / viewScale(for: pageIdx)
        let transform = pageToViewTransform(for: pageIdx)
        switch shape {
        case let .line(start, end):
            let s = GeometrySnapEngine.nearestPoint(to: start, in: cachedPageSnapPoints, threshold: pageThreshold)?.point ?? start
            if let endSnap = GeometrySnapEngine.nearestPoint(to: end, in: cachedPageSnapPoints,
                                                             threshold: pageThreshold, excluding: s, excludeRadius: 8) {
                shape = .line(start: s, end: endSnap.point)
                updateSnapFeedback(SnapPoint(point: endSnap.point.applying(transform), kind: endSnap.kind))
            } else {
                shape = .line(start: s, end: end)
            }
        case let .arrow(start, end):
            let s = GeometrySnapEngine.nearestPoint(to: start, in: cachedPageSnapPoints, threshold: pageThreshold)?.point ?? start
            if let endSnap = GeometrySnapEngine.nearestPoint(to: end, in: cachedPageSnapPoints,
                                                             threshold: pageThreshold, excluding: s, excludeRadius: 8) {
                shape = .arrow(start: s, end: endSnap.point)
                updateSnapFeedback(SnapPoint(point: endSnap.point.applying(transform), kind: endSnap.kind))
            } else {
                shape = .arrow(start: s, end: end)
            }
        case let .circle(center, radius):
            if let centerSnap = GeometrySnapEngine.nearestPoint(to: center, in: cachedPageSnapPoints, threshold: pageThreshold) {
                shape = .circle(center: centerSnap.point, radius: radius)
                updateSnapFeedback(SnapPoint(point: centerSnap.point.applying(transform), kind: centerSnap.kind))
            }
        case let .parabola(vertex, axisAngle, halfWidth, height):
            if let vertexSnap = GeometrySnapEngine.nearestPoint(to: vertex, in: cachedPageSnapPoints, threshold: pageThreshold) {
                shape = .parabola(vertex: vertexSnap.point, axisAngle: axisAngle, halfWidth: halfWidth, height: height)
                updateSnapFeedback(SnapPoint(point: vertexSnap.point.applying(transform), kind: vertexSnap.kind))
            }
        case .rectangle, .polygon:
            break
        }
        snappedBaseShape = shape
        snappedCurrentShape = shape
        snapDragOriginPagePoint = livePoints.last?.location ?? .zero
        haptic.impactOccurred()
        renderSnappedLiveShape()
    }

    private func renderSnappedLiveShape() {
        guard let shape = snappedCurrentShape else { return }
        let stroke = makeGeometricStroke(shape.primitive)
        let transform = pageToViewTransform(for: activeDrawPageIndex)
        setLivePath(stroke.outlinePath(transform: transform, finished: true))
    }

    private func commitSnappedShape(_ shape: RecognizedShape) {
        let stroke = makeGeometricStroke(shape.primitive)
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        lastCommitted = nil
        setLivePath(nil)
        session.addStroke(stroke, page: activeDrawPageIndex)
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
        let p = pagePoint(touch, pageIndex: activeDrawPageIndex)
        let isStylus = touch.type == .pencil
        return InkPoint(x: Float(p.x), y: Float(p.y), force: forceValue(touch),
                        azimuth: isStylus ? Float(touch.azimuthAngle(in: view)) : 0,
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
        let transform = pageToViewTransform(for: activeDrawPageIndex)
        setLivePath(stroke.outlinePath(transform: transform, finished: false))
    }

    private func setLivePath(_ path: CGPath?, fillPath: CGPath? = nil, fillColor: CGColor? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = path
        liveFillLayer.path = fillPath
        liveFillLayer.fillColor = fillColor
        CATransaction.commit()
        pushPresentationOverlay()
    }

    private func commitLiveStroke() {
        defer { setLivePath(nil) }
        guard !livePoints.isEmpty else { return }
        let stroke = makeStroke(points: livePoints)
        let pageIdx = activeDrawPageIndex
        if stroke.points.count == livePoints.count {
            lastCommitted = (id: stroke.id, page: pageIdx, points: stroke.points)
        } else {
            lastCommitted = nil
        }
        livePoints.removeAll(keepingCapacity: true)
        session.addStroke(stroke, page: pageIdx)
    }

    // MARK: Laser Pointer (View Coordinates)

    private func laserBegan(_ touch: UITouch) {
        stopLaserLoop()
        laserEngine.begin(at: touch.preciseLocation(in: view), color: liveTool.laserColor, now: CACurrentMediaTime())
        updateLaserRender()
    }

    private func laserMoved(_ touch: UITouch, event: UIEvent?) {
        let now = CACurrentMediaTime()
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            laserEngine.move(to: sample.preciseLocation(in: view), now: now)
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
        let proxy = PDFDisplayLinkProxy { [weak self] in
            self?.updateLaserRender()
        }
        let link = CADisplayLink(target: proxy, selector: #selector(PDFDisplayLinkProxy.tick))
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
        let frame = laserEngine.frame(at: CACurrentMediaTime(), transform: .identity)
        laserFrame = frame
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame.isActive {
            laserGlowLayer.fillColor = frame.glowColor
            laserGlowLayer.shadowColor = frame.glowColor
            laserGlowLayer.opacity = frame.opacity
            laserGlowLayer.path = frame.glowPath
            laserGlowLayer.shadowPath = frame.glowPath
            laserCoreLayer.opacity = frame.opacity
            laserCoreLayer.path = frame.corePath
        } else {
            laserGlowLayer.path = nil
            laserGlowLayer.shadowPath = nil
            laserCoreLayer.path = nil
            stopLaserLoop()
        }
        CATransaction.commit()
        pushPresentationOverlay()
    }

    // MARK: Erasing

    private var eraserRadius: CGFloat { CGFloat(liveTool.eraserRadius) }

    private func eraseBegan(_ touch: UITouch) {
        guard let pageIdx = pageIndex(at: touch.location(in: view)) else { return }
        activeErasePageIndex = pageIdx
        let original = session.strokes(onPage: pageIdx)
        eraseOriginal = original
        eraseWorking = original
        let p = pagePoint(touch, pageIndex: pageIdx)
        lastErasePoint = p
        if applyEraseStep(from: p, to: p) {
            overlays[pageIdx]?.renderPreview(eraseWorking)
            PresentationCenter.shared.markContentActive()
        }
        setEraserCursor(p, pageIndex: pageIdx)
    }

    private func eraseMoved(_ touch: UITouch, event: UIEvent?) {
        guard eraseOriginal != nil else { return }
        let pageIdx = activeErasePageIndex
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        let minStepSq: CGFloat = liveTool.eraserMode == .pixel ? 1.44 : 0.25
        var anyChanged = false
        for (idx, sample) in samples.enumerated() {
            let p = pagePoint(sample, pageIndex: pageIdx)
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
        // Render & wake projection at most once per display frame instead of 4x per frame.
        if anyChanged {
            overlays[pageIdx]?.renderPreview(eraseWorking)
            PresentationCenter.shared.markContentActive()
        }
        setEraserCursor(lastErasePoint, pageIndex: pageIdx)
    }

    private func eraseEnded() {
        let pageIdx = activeErasePageIndex
        defer {
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
            geometryCache.prune(keeping: Set(eraseWorking.map(\.id)))
        }
        guard let original = eraseOriginal else { return }
        if eraseWorking != original {
            session.replaceStrokes(onPage: pageIdx, before: original, after: eraseWorking)
        } else {
            overlays[pageIdx]?.sync()
        }
        PresentationCenter.shared.requestFrameRefresh()
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

    private func setEraserCursor(_ pagePoint: CGPoint?, pageIndex: Int = 0) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let pagePoint {
            let transform = pageToViewTransform(for: pageIndex)
            let center = pagePoint.applying(transform)
            let r = eraserRadius * viewScale(for: pageIndex)
            eraserCursor.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r),
                                       transform: nil)
            eraserCursor.isHidden = false
        } else {
            eraserCursor.isHidden = true
        }
        CATransaction.commit()
        pushPresentationOverlay()
    }

    // MARK: Presentation Overlay & Viewport

    private func pushPresentationOverlay() {
        guard isTabActive, PresentationCenter.shared.isShowingContentOnly else { return }
        let captureRect = presentationViewport.captureRect.width > 0 ? presentationViewport.captureRect : view.bounds

        // Sticky note active live ink takes priority when open.
        if session.isScratchpadOpen {
            if let scratch = scratchpadLiveOverlay {
                let offset: CGPoint = (session.scratchpadSplitMode == .full)
                    ? .zero
                    : stickyCanvasFrameInView().origin
                let shifted = scratch.translated(by: offset)
                let state = LiveOverlayState(
                    sourceSize: captureRect.size,
                    captureOriginY: captureRect.minY,
                    strokePath: shifted.strokePath,
                    strokeColor: shifted.strokeColor,
                    strokeOpacity: shifted.strokeOpacity,
                    isHighlighter: false,
                    fillPath: shifted.fillPath,
                    fillColor: shifted.fillColor,
                    pendingStrokes: shifted.pendingStrokes,
                    cursorPath: shifted.cursorPath,
                    laserGlowPath: shifted.laserGlowPath,
                    laserCorePath: shifted.laserCorePath,
                    laserColor: shifted.laserColor,
                    laserOpacity: shifted.laserOpacity,
                    geometryAid: shifted.geometryAid
                )
                PresentationCenter.shared.updateLiveOverlay(state)
                return
            } else if session.scratchpadSplitMode == .full {
                PresentationCenter.shared.updateLiveOverlay(.empty)
                return
            }
        }

        var pendingOverlays: [PendingOverlayStroke] = []
        if !lassoPreviewEntries.isEmpty {
            var transform = lassoPreviewTransform
            for entry in lassoPreviewEntries {
                let path = entry.baseViewPath.copy(using: &transform) ?? entry.baseViewPath
                let fill = entry.baseFillPath?.copy(using: &transform) ?? entry.baseFillPath
                pendingOverlays.append(PendingOverlayStroke(
                    path: path,
                    color: entry.strokeColor,
                    opacity: entry.opacity,
                    isHighlighter: entry.isHighlighter,
                    fillPath: fill,
                    fillColor: entry.fillColor
                ))
            }
        }

        let projectedAid: ProjectedGeometryAid
        switch geometryOverlay.aid {
        case .none:
            projectedAid = .none
        case .compass:
            projectedAid = .compass(compassState, sweep: geometryOverlay.activeCompassSweep,
                                    strokeColor: geometryOverlay.activeStrokeColor.cgColor)
        case .protractor:
            projectedAid = .protractor(protractorState)
        }

        let state = LiveOverlayState(
            sourceSize: captureRect.size,
            captureOriginY: captureRect.minY,
            strokePath: liveLayer.path,
            strokeColor: liveLayer.fillColor,
            strokeOpacity: liveLayer.opacity,
            isHighlighter: false,
            fillPath: liveFillLayer.path,
            fillColor: liveFillLayer.fillColor,
            pendingStrokes: pendingOverlays,
            cursorPath: eraserCursor.isHidden ? nil : eraserCursor.path,
            laserGlowPath: laserFrame.glowPath,
            laserCorePath: laserFrame.corePath,
            laserColor: laserFrame.glowColor,
            laserOpacity: laserFrame.opacity,
            geometryAid: projectedAid
        )
        PresentationCenter.shared.updateLiveOverlay(state)
    }

    private func updatePresentationViewport(focusY: CGFloat?) {
        let visibleSize = view.bounds.size
        guard visibleSize.width > 0, visibleSize.height > 0 else { return }
        let center = PresentationCenter.shared
        let externalSize = center.isShowingContentOnly ? center.externalDisplaySize : nil
        let viewport = PresentationViewport.compute(
            visibleSize: visibleSize,
            externalSize: externalSize,
            fillMode: center.fillMode,
            focusY: focusY,
            currentOriginY: captureOriginY
        )
        let originChanged = abs(viewport.captureRect.minY - captureOriginY) > 0.5
        presentationViewport = viewport
        captureOriginY = viewport.captureRect.minY

        if let heightConstraint = pdfViewHeightConstraint,
           abs(heightConstraint.constant - viewport.extraBottomInset) > 0.5 {
            heightConstraint.constant = viewport.extraBottomInset
            if let scrollView = pdfView.firstDescendant(of: UIScrollView.self) {
                scrollView.contentInset.bottom = viewport.extraBottomInset
                scrollView.verticalScrollIndicatorInsets.bottom = viewport.extraBottomInset
            }
            view.setNeedsLayout()
        }
        if originChanged {
            pushPresentationOverlay()
            center.requestFrameRefresh()
        }
    }
}

extension EditorViewController: PresentationContentSource {
    var presentationView: UIView { view }

    func presentationViewportDidChange() {
        updatePresentationViewport(focusY: nil)
    }

    func capturePresentationFrame(completion: @escaping (UIImage?, CGSize) -> Void) {
        updatePresentationViewport(focusY: nil)
        let target = presentationViewport.captureRect
        let captureRect = (target.width > 0 && target.height > 0) ? target : view.bounds
        guard captureRect.width > 0, captureRect.height > 0 else {
            completion(nil, .zero)
            return
        }

        // 1. Full-screen sticky note whiteboard: pure Retina vector render, zero iPad UI chrome.
        if session.isScratchpadOpen && session.scratchpadSplitMode == .full {
            let fullHeight = max(captureRect.maxY, view.bounds.height)
            let fullCanvas = scratchpadPanel.canvas.renderCleanImage(size: CGSize(width: captureRect.width, height: fullHeight))
            if captureRect.minY <= 0.5 && abs(fullHeight - captureRect.height) <= 0.5 {
                completion(fullCanvas, captureRect.size)
            } else {
                let format = UIGraphicsImageRendererFormat()
                format.scale = min(max(UIScreen.main.scale, 1), 2)
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
                let sliced = renderer.image { _ in
                    fullCanvas.draw(in: CGRect(x: 0, y: -captureRect.minY, width: captureRect.width, height: fullHeight))
                }
                completion(sliced, captureRect.size)
            }
            return
        }

        let pdfBounds = pdfView.bounds
        guard pdfBounds.width > 0, pdfBounds.height > 0 else {
            completion(nil, .zero)
            return
        }
        let pdfCapture = captureRect.intersection(pdfBounds)
        guard pdfCapture.width > 0, pdfCapture.height > 0 else {
            completion(nil, .zero)
            return
        }

        let fullScale = PresentationCenter.shared.preferredPDFCaptureScale(
            forCaptureWidth: pdfCapture.width,
            screenScale: view.window?.screen.scale ?? 2
        )

        // 2. Fast async off-main-thread PDF projection (matches HTML WKWebView.takeSnapshot fluidity):
        // Collect lightweight geometry & strokes on main thread (<0.2ms), then composite cached page
        // bitmaps + crisp vector ink on a private serial queue so scrolling stays locked at 60/120fps.
        if let doc = pdfView.document, let pdfURL = doc.documentURL {
            let sv = pdfScrollView ?? pdfView.firstDescendant(of: UIScrollView.self)
            let isActivelyScrolling = (sv?.isTracking == true)
                || (sv?.isDragging == true)
                || (sv?.isDecelerating == true)
                || (sv?.isZooming == true)
                || (CFAbsoluteTimeGetCurrent() - lastScrollActivityAt) < 0.14
            let outputScale = isActivelyScrolling ? min(fullScale, 1.0) : fullScale
            if isActivelyScrolling {
                needsHighResSettleRefresh = true
                scheduleScrollSettleRefresh()
            } else {
                needsHighResSettleRefresh = false
            }

            let pages = buildProjectionPageSlices(doc: doc, pdfCapture: pdfCapture)
            let floatingCard: PDFProjectionFloatingCard?
            if session.isScratchpadOpen && session.scratchpadSplitMode == .floating {
                let canvasFrame = stickyCanvasFrameInView()
                let cardRect = canvasFrame.offsetBy(dx: -pdfCapture.minX, dy: -pdfCapture.minY)
                let stickyImage = scratchpadPanel.canvas.renderCleanImage(size: canvasFrame.size)
                if let cgCard = stickyImage.cgImage {
                    floatingCard = PDFProjectionFloatingCard(rect: cardRect, image: cgCard)
                } else {
                    floatingCard = nil
                }
            } else {
                floatingCard = nil
            }

            let bgColor = (pdfView.backgroundColor ?? .secondarySystemBackground)
                .resolvedColor(with: traitCollection)
                .cgColor

            let request = PDFProjectionFrameRequest(
                pdfURL: pdfURL,
                documentRevision: pdfDocumentRevision,
                displayBox: pdfView.displayBox,
                captureSize: pdfCapture.size,
                outputScale: outputScale,
                backgroundColor: bgColor,
                pages: pages,
                floatingScratchpad: floatingCard,
                isFastMotion: isActivelyScrolling
            )
            projectionRenderer.render(request) { image in
                completion(image, pdfCapture.size)
            }
            return
        }

        // Fallback for synthetic in-memory PDFs without a backing disk file.
        let format = UIGraphicsImageRendererFormat()
        format.scale = fullScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pdfCapture.size, format: format)

        if session.isScratchpadOpen && session.scratchpadSplitMode == .floating {
            let canvasFrame = stickyCanvasFrameInView()
            let cardRect = canvasFrame.offsetBy(dx: -pdfCapture.minX, dy: -pdfCapture.minY)
            let stickyImage = scratchpadPanel.canvas.renderCleanImage(size: canvasFrame.size)
            let image = renderer.image { rendererCtx in
                let ctx = rendererCtx.cgContext
                ctx.saveGState()
                ctx.translateBy(x: -pdfCapture.minX, y: -pdfCapture.minY)
                pdfView.drawHierarchy(in: pdfBounds, afterScreenUpdates: false)
                ctx.restoreGState()

                let rounded = UIBezierPath(roundedRect: cardRect, cornerRadius: 10)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 12,
                              color: UIColor.black.withAlphaComponent(0.18).cgColor)
                UIColor.white.setFill()
                rounded.fill()
                ctx.restoreGState()

                ctx.saveGState()
                rounded.addClip()
                stickyImage.draw(in: cardRect)
                ctx.restoreGState()

                UIColor(red: 0.78, green: 0.70, blue: 0.52, alpha: 0.75).setStroke()
                rounded.lineWidth = 1.0
                rounded.stroke()
            }
            completion(image, pdfCapture.size)
            return
        }

        let image = renderer.image { ctx in
            ctx.cgContext.translateBy(x: -pdfCapture.minX, y: -pdfCapture.minY)
            pdfView.drawHierarchy(in: pdfBounds, afterScreenUpdates: false)
        }
        completion(image, pdfCapture.size)
    }

    private func buildProjectionPageSlices(doc: PDFDocument, pdfCapture: CGRect) -> [PDFProjectionPageSlice] {
        var candidateIndices = Set<Int>()
        for page in pdfView.visiblePages {
            let idx = doc.index(for: page)
            if idx != NSNotFound, idx >= 0, idx < doc.pageCount {
                candidateIndices.insert(idx)
            }
        }
        if candidateIndices.isEmpty, let current = pdfView.currentPage {
            let idx = doc.index(for: current)
            if idx != NSNotFound, idx >= 0, idx < doc.pageCount {
                candidateIndices.insert(idx)
            }
        }
        // Also inspect immediate neighbors so pages just entering `pdfCapture` during fast flicks never clip out.
        if let minIdx = candidateIndices.min(), minIdx > 0 {
            candidateIndices.insert(minIdx - 1)
        }
        if let maxIdx = candidateIndices.max(), maxIdx + 1 < doc.pageCount {
            candidateIndices.insert(maxIdx + 1)
        }

        let captureInView = view.convert(pdfCapture, from: pdfView)
        let captureShift = CGAffineTransform(translationX: -captureInView.minX, y: -captureInView.minY)
        let visibilityBounds = CGRect(origin: .zero, size: pdfCapture.size).insetBy(dx: -2, dy: -2)
        let displayBox = pdfView.displayBox

        var slices: [PDFProjectionPageSlice] = []
        slices.reserveCapacity(candidateIndices.count)

        for pageIndex in candidateIndices.sorted() {
            guard let page = doc.page(at: pageIndex) else { continue }
            let pageBox = page.bounds(for: displayBox)
            let rectInPDF = pdfView.convert(pageBox, from: page).standardized
            let frameInCapture = rectInPDF.offsetBy(dx: -pdfCapture.minX, dy: -pdfCapture.minY)
            guard frameInCapture.width > 0.5,
                  frameInCapture.height > 0.5,
                  frameInCapture.intersects(visibilityBounds) else {
                continue
            }

            let rawStrokes: [InkStroke]
            if eraseOriginal != nil && activeErasePageIndex == pageIndex {
                rawStrokes = eraseWorking
            } else {
                rawStrokes = session.strokes(onPage: pageIndex)
            }
            let visibleStrokes: [InkStroke]
            if let hidden = overlays[pageIndex]?.hiddenStrokeIDs, !hidden.isEmpty {
                visibleStrokes = rawStrokes.filter { !hidden.contains($0.id) }
            } else {
                visibleStrokes = rawStrokes
            }

            let inkTransform = pageToViewTransform(for: pageIndex).concatenating(captureShift)
            slices.append(PDFProjectionPageSlice(
                pageIndex: pageIndex,
                frameInCapture: frameInCapture,
                inkToCaptureTransform: inkTransform,
                strokes: visibleStrokes
            ))
        }
        return slices
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

private final class PDFDisplayLinkProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func tick() { handler() }
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
