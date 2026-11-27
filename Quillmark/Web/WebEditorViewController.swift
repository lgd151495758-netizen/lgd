import Combine
import UIKit
import WebKit

/// Annotates a live web page. Fingers use the page normally (tap buttons, expand sections,
/// scroll, zoom, tap cover tapes to reveal/hide); Apple Pencil writes, highlights, places cover
/// tapes, uses the laser pointer, or erases. Strokes are anchored to page elements by `WebInkBridge`.
final class WebEditorViewController: UIViewController, DocumentTabViewController, InkInputDelegate, WKNavigationDelegate,
    UIScribbleInteractionDelegate, UIGestureRecognizerDelegate {
    let session: DocumentSession
    var isManagedByTabDeck: Bool = false
    private var isTabActive: Bool = true
    private var hasRestoredViewport: Bool = false
    private var isRestoringViewport: Bool = false
    private let pencilInteraction = UIPencilInteraction()
    private let library: LibraryStore
    private let bridge = WebInkBridge()
    private var webView: WKWebView { bridge.webView }
    /// Exposed for `DocumentExportService` to capture live DOM + SVG ink without reloading.
    var exportBridge: WebInkBridge { bridge }

    private let inkRecognizer = InkGestureRecognizer(target: nil, action: nil)
    private let pendingFillContainer = CALayer()
    private let pendingContainer = CALayer()
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
    private var cancellables = Set<AnyCancellable>()
    private var documentURL: URL?
    private var webViewHeightConstraint: NSLayoutConstraint?
    private var presentationViewport = PresentationViewport(contentHeight: 0, extraBottomInset: 0, captureRect: .zero)
    private var captureOriginY: CGFloat = 0

    static let page = 0

    private struct PendingItem {
        let id: UUID
        let layer: CAShapeLayer
        let fillLayer: CAShapeLayer?
        let isHighlighter: Bool
    }

    private struct LassoPreviewEntry {
        let baseViewPath: CGPath
        let baseFillPath: CGPath?
        let strokeColor: CGColor
        let fillColor: CGColor?
        let opacity: Float
        let isHighlighter: Bool
    }

    private struct LassoTransformContext {
        let originalStrokes: [InkStroke]
        let selectedIDs: Set<UUID>
        let docStrokesByID: [UUID: InkStroke]
        let baseDocBox: CGRect
        let baseViewTransform: CGAffineTransform
        var currentScale: CGFloat = 1
        var pivotDoc: CGPoint = .zero
        var currentTranslation: CGPoint = .zero
    }

    private struct ShapeEditContext {
        let strokeID: UUID
        let originalStrokes: [InkStroke]
        let originalStroke: InkStroke
        let anchorOrigin: CGPoint
        let baseDocPrimitive: GeometricPrimitive
        var currentDocPrimitive: GeometricPrimitive
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
        case shapeCreate(preset: ShapePreset, startDoc: CGPoint, rawStartView: CGPoint, currentPrimitive: GeometricPrimitive?)
        case selectedHandle(index: Int, context: ShapeEditContext)
        case selectedBody(startDoc: CGPoint, context: ShapeEditContext)
        case selectedAction(SelectedShapeOverlay.ActionButton, startPoint: CGPoint)
        case lassoDraw(docPoints: [CGPoint], rawStartView: CGPoint)
        case lassoMove(startDoc: CGPoint, context: LassoTransformContext)
        case lassoScale(corner: LassoSelectionOverlay.ScaleCorner, startCornerDoc: CGPoint, context: LassoTransformContext)
        case lassoAction(LassoSelectionOverlay.ActionButton, startPoint: CGPoint)
    }

    // Virtual Compass, Smart Protractor, Selected Shape, Lasso & Snap Points (iPad-only UI; never projected to external display)
    private var compassState = CompassState()
    private var protractorState = ProtractorState()
    private var protractorDetectGeneration: UInt64 = 0
    private var selectedStrokeID: UUID?
    private var selectedAnchorFallbackOrigin: CGPoint = .zero
    private var lassoSelectedIDs: [UUID] = []
    private var lassoFallbackOrigins: [UUID: CGPoint] = [:]
    private var lassoPreviewEntries: [LassoPreviewEntry] = []
    private var lassoPreviewTransform: CGAffineTransform = .identity
    private var activeInteraction: ActiveInteraction = .none
    private var fingerControlInteraction: ActiveInteraction = .none
    private var cachedDocSnapPoints: [SnapPoint] = []
    private var cachedViewSnapPoints: [SnapPoint] = []
    private var lastSnapHapticPoint: CGPoint?

    // Drawing state (document coordinates, CSS px)
    private var liveTool = ToolSettings()
    private var livePoints: [InkPoint] = []
    private var liveStartTime: TimeInterval = 0
    private var pendingEstimates: [NSNumber: Int] = [:]
    private var pendingItems: [PendingItem] = []

    // Draw-and-hold shape snapping
    private var holdTimer: DispatchWorkItem?
    private var holdAnchorViewPoint: CGPoint = .zero
    private var snappedBaseShape: RecognizedShape?
    private var snappedCurrentShape: RecognizedShape?
    private var snapDragOriginDocPoint: CGPoint = .zero
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    // Laser pointer
    private let laserEngine = LaserPointerEngine()
    private var laserDisplayLink: CADisplayLink?
    private var laserDisplayLinkProxy: LaserDisplayLinkProxy?
    private var laserFrame: LaserRenderFrame = .empty

    // Erasing state
    private var eraseOriginal: [InkStroke]?
    private var eraseWorking: [InkStroke] = []
    private var eraseOrigins: [UUID: CGPoint] = [:]
    private var lastErasePoint: CGPoint?

    init(session: DocumentSession, library: LibraryStore) {
        self.session = session
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stopLaserLoop()
        holdTimer?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        let heightConstraint = webView.heightAnchor.constraint(equalTo: view.heightAnchor, constant: 0)
        webViewHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            heightConstraint,
        ])
        webView.navigationDelegate = self

        // Block Apple Pencil Scribble on the container, webView, and its internal subviews.
        view.addInteraction(UIScribbleInteraction(delegate: self))
        webView.addInteraction(UIScribbleInteraction(delegate: self))

        view.layer.addSublayer(pendingFillContainer)
        view.layer.addSublayer(pendingContainer)
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

        // iPad-only Ruler / Compass overlay (sibling above webView & liveLayer; never projected).
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
        // Pencil touches must never reach the page (no accidental clicks, Scribble, or text selection).
        inkRecognizer.cancelsTouchesInView = true
        view.addGestureRecognizer(inkRecognizer)

        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)

        bridge.onReady = { [weak self] in
            self?.applyGestureRules()
            self?.pushStrokes()
            self?.restoreSavedViewportIfNeeded()
        }
        bridge.onPlacementsChanged = { [weak self] in
            self?.refreshSelectedShapeOverlay()
            self?.refreshLassoSelectionOverlay()
            PresentationCenter.shared.markContentActive()
        }
        bridge.onToggleTape = { [weak self] id in
            guard let self else { return }
            self.session.toggleTape(id: id, page: Self.page)
            PresentationCenter.shared.requestFrameRefresh()
        }
        bridge.onUserActivity = {
            PresentationCenter.shared.markContentActive()
        }
        session.pageDidChange = { [weak self] changedPage in
            guard let self else { return }
            if changedPage < 0 {
                self.scratchpadPanel.canvas.syncCommittedStrokes()
                PresentationCenter.shared.requestFrameRefresh()
            } else {
                self.pushStrokes()
                self.refreshSelectedShapeOverlay()
                self.refreshLassoSelectionOverlay()
            }
        }
        session.allPagesDidChange = { [weak self] in
            guard let self else { return }
            self.clearSelectedShape()
            self.clearLassoSelection()
            self.pushStrokes()
            self.scratchpadPanel.canvas.syncCommittedStrokes()
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
        webView.scrollView.publisher(for: \.contentOffset)
            .sink { [weak self] _ in
                self?.refreshSelectedShapeOverlay()
                self?.refreshLassoSelectionOverlay()
                self?.recordCurrentViewport()
                PresentationCenter.shared.markContentActive()
            }
            .store(in: &cancellables)
        webView.scrollView.publisher(for: \.zoomScale)
            .sink { [weak self] _ in
                self?.refreshSelectedShapeOverlay()
                self?.refreshLassoSelectionOverlay()
                self?.recordCurrentViewport()
                PresentationCenter.shared.markContentActive()
            }
            .store(in: &cancellables)

        loadDocument()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pendingFillContainer.frame = view.bounds
        pendingContainer.frame = view.bounds
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
        updatePresentationViewport(focusY: nil)
        updateScratchpadLayout()
        clampGeometryAidsToBounds()
        refreshSelectedShapeOverlay()
        refreshLassoSelectionOverlay()
        applyGestureRules()
    }

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
        } else {
            inkRecognizer.cancelIfActive()
            stopLaserLoop()
            laserEngine.cancel()
            laserFrame = .empty
            holdTimer?.cancel()
            holdTimer = nil
            scratchpadPanel.canvas.deactivate()
            scratchpadLiveOverlay = nil
            if releasePresentation {
                PresentationCenter.shared.clearContentSource(self)
            }
        }
    }

    func saveStateNow() {
        recordCurrentViewport()
        session.saveNow()
        if isTabActive, !view.isHidden, webView.bounds.width > 0 {
            saveThumbnail()
        }
    }

    private func recordCurrentViewport() {
        guard hasRestoredViewport, !isRestoringViewport,
              webView.bounds.width > 0, webView.scrollView.contentSize.height > 0 else { return }
        let sv = webView.scrollView
        session.updateViewport(ViewportState(
            offsetX: sv.contentOffset.x,
            offsetY: sv.contentOffset.y,
            zoomScale: sv.zoomScale,
            pageIndex: nil
        ))
    }

    private func restoreSavedViewportIfNeeded() {
        guard !hasRestoredViewport, !isRestoringViewport else { return }
        guard let saved = session.savedViewport, saved.isValid else {
            hasRestoredViewport = true
            return
        }
        isRestoringViewport = true
        applySavedViewport(saved, allowRetry: true)
    }

    private func applySavedViewport(_ saved: ViewportState, allowRetry: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (allowRetry ? 0.12 : 0.30)) { [weak self] in
            guard let self else { return }
            let sv = self.webView.scrollView
            if saved.zoomScale > 0, sv.maximumZoomScale >= sv.minimumZoomScale {
                let clampedZoom = min(max(saved.zoomScale, sv.minimumZoomScale), sv.maximumZoomScale)
                if abs(sv.zoomScale - clampedZoom) > 0.01 {
                    sv.setZoomScale(clampedZoom, animated: false)
                }
            }
            let clamped = ViewportState.clampedOffset(
                CGPoint(x: saved.offsetX, y: saved.offsetY),
                contentSize: sv.contentSize,
                boundsSize: sv.bounds.size
            )
            sv.setContentOffset(clamped, animated: false)
            let maxY = max(0, sv.contentSize.height - sv.bounds.height)
            if allowRetry, saved.offsetY > 12, maxY < saved.offsetY * 0.85 {
                self.applySavedViewport(saved, allowRetry: false)
            } else {
                self.isRestoringViewport = false
                self.hasRestoredViewport = true
            }
        }
    }

    // MARK: Loading

    private func loadDocument() {
        let meta = session.meta
        let folder = library.sourceFolder(for: meta.id)
        guard let entry = meta.sourceEntry else { return }
        let entryURL = folder.appendingPathComponent(entry)
        bridge.resetForNavigation()
        if entryURL.pathExtension.lowercased() == "webarchive" {
            guard let data = try? Data(contentsOf: entryURL) else { return }
            let base = meta.sourceURL.flatMap { URL(string: $0) } ?? URL(string: "about:blank")!
            documentURL = base
            webView.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: base)
        } else {
            documentURL = entryURL
            webView.loadFileURL(entryURL, allowingReadAccessTo: folder)
        }
    }

    private func pushStrokes() {
        let strokes = session.strokes(onPage: Self.page)
        let syncedIDs = Set(strokes.map(\.id))
        bridge.sync(strokes) { [weak self] in
            // Wait one display frame after WebKit finishes apply() so the SVG is painted before
            // removing the temporary native layer (zero flicker, zero disappearing fast strokes).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) { [weak self] in
                guard let self else { return }
                self.removePendingItems(matching: syncedIDs)
                PresentationCenter.shared.requestFrameRefresh()
            }
        }
    }

    private func removePendingItems(matching ids: Set<UUID>) {
        guard !pendingItems.isEmpty else { return }
        var removed = false
        pendingItems.removeAll { item in
            if ids.contains(item.id) {
                item.layer.removeFromSuperlayer()
                item.fillLayer?.removeFromSuperlayer()
                removed = true
                return true
            }
            return false
        }
        if removed {
            pushPresentationOverlay()
        }
    }

    private func saveThumbnail() {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 400
        let url = library.thumbnailURL(for: session.meta.id)
        webView.takeSnapshot(with: configuration) { image, _ in
            guard let data = image?.pngData() else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyGestureRules()
        restoreSavedViewportIfNeeded()
        PresentationCenter.shared.requestFrameRefresh()
    }

    /// Automatically recovers if iPadOS terminates the WebKit WebContent process under 4GB RAM pressure,
    /// preventing a blank white screen mid-lecture and restoring exact scroll/zoom and ink.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recordCurrentViewport()
        session.saveNow()
        hasRestoredViewport = false
        loadDocument()
    }

    /// The document stays on its page: links to other pages open in Safari, in-page anchors
    /// (`#section`) and the document's own load are allowed.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame ?? false, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if Self.isSameDocument(url, documentURL) || url.scheme == "about" || url.scheme == "data" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .other && webView.url == nil {
            decisionHandler(.allow) // initial load
            return
        }
        if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
            UIApplication.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    static func isSameDocument(_ a: URL, _ b: URL?) -> Bool {
        guard let b else { return false }
        func strip(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.string ?? url.absoluteString
        }
        return strip(a) == strip(b)
    }

    // MARK: Gestures & Scribble Suppression

    private static func setAllowedTouchTypesIfNeeded(_ types: [NSNumber], on recognizer: UIGestureRecognizer) {
        guard recognizer.state != .began && recognizer.state != .changed else { return }
        if recognizer.allowedTouchTypes != types {
            recognizer.allowedTouchTypes = types
        }
    }

    /// Pencil never drives the page or iPadOS Scribble. With finger drawing on, the page only
    /// scrolls/zooms with two fingers and ignores one-finger taps.
    private func applyGestureRules() {
        let fingerDrawing = session.tool.fingerDrawing
        inkRecognizer.allowsFingerDrawing = fingerDrawing
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        let scrollTypes = [direct, pointer]
        let otherTypes = fingerDrawing ? [pointer] : [direct, pointer]
        let scrollView = webView.scrollView
        for recognizer in Self.allGestureRecognizers(in: webView) where recognizer !== inkRecognizer {
            let isScrollOrZoom = (recognizer === scrollView.panGestureRecognizer
                || recognizer === scrollView.pinchGestureRecognizer
                || InkGestureRecognizer.isScrollOrZoomGesture(recognizer))
            Self.setAllowedTouchTypesIfNeeded(isScrollOrZoom ? scrollTypes : otherTypes, on: recognizer)
        }
        let targetMinTouches = fingerDrawing ? 2 : 1
        if scrollView.panGestureRecognizer.minimumNumberOfTouches != targetMinTouches {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = targetMinTouches
        }
        if let pinch = scrollView.pinchGestureRecognizer, !pinch.isEnabled {
            pinch.isEnabled = true
        }
        // When fingerDrawing is enabled, inkRecognizer handles single-finger touches directly;
        // otherwise geometryOverlay handles finger controls while passing everything else to webView.
        if geometryOverlay.isUserInteractionEnabled != !fingerDrawing {
            geometryOverlay.isUserInteractionEnabled = !fingerDrawing
        }
        suppressSystemScribble(in: webView)
    }

    /// Removes system-attached `UIScribbleInteraction` from `WKContentView` and internal WebKit
    /// subviews, and installs our blocking `UIScribbleInteraction` so fast Pencil writing and
    /// erasing never trigger system Scribble black strokes or touch cancellation.
    private func suppressSystemScribble(in root: UIView) {
        for subview in root.subviews {
            var hasOurBlocker = false
            for interaction in subview.interactions {
                if let scribble = interaction as? UIScribbleInteraction, scribble.delegate === self {
                    hasOurBlocker = true
                } else if String(describing: type(of: interaction)).contains("Scribble") {
                    subview.removeInteraction(interaction)
                }
            }
            if !hasOurBlocker, String(describing: type(of: subview)).contains("WKContentView") {
                subview.addInteraction(UIScribbleInteraction(delegate: self))
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
        if gestureRecognizer === inkRecognizer, session.isScratchpadOpen {
            let pt = touch.location(in: scratchpadPanel)
            if scratchpadPanel.bounds.contains(pt) {
                return false
            }
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
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
        // Only require failure of recognizers that actually listen to Apple Pencil (never block
        // finger scrolling, zooming, or tapping cover tapes on the web page).
        let pencilType = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        if otherGestureRecognizer.allowedTouchTypes.contains(pencilType),
           let otherView = otherGestureRecognizer.view, otherView.isDescendant(of: webView) {
            return true
        }
        return false
    }

    // MARK: Input routing

    func inkBegan(_ touch: UITouch, event: UIEvent?) {
        liveTool = session.tool
        let viewPoint = touch.location(in: view)
        updatePresentationViewport(focusY: viewPoint.y)

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
        // Touching outside the selected shape exits edit mode immediately with zero friction.
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
            activeInteraction = beginShapeCreation(at: viewPoint)
            return
        }

        // 5. Lasso tool: draw a freeform selection loop (or quick tap a stroke to select it).
        if liveTool.kind == .lasso {
            activeInteraction = beginLassoDraw(at: viewPoint)
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
            laserEnded(touch)
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
            pushStrokes()
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

    // MARK: Virtual Compass, Standard Shapes & Selected Shape Editing (One-Handed Apple Pencil)

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

    private func refreshViewSnapPoints(excludingStrokeID: UUID? = nil) {
        let origins = bridge.placements.compactMapValues { $0.visible ? $0.origin : nil }
        let docSnaps = GeometrySnapEngine.snapPoints(from: session.strokes(onPage: Self.page),
                                                     origins: origins,
                                                     excludingStrokeID: excludingStrokeID)
        let transform = viewTransform()
        cachedDocSnapPoints = docSnaps
        cachedViewSnapPoints = docSnaps.map { SnapPoint(point: $0.point.applying(transform), kind: $0.kind) }
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

    private func documentPoint(fromViewPoint p: CGPoint) -> CGPoint {
        bridge.documentPoint(fromView: CGPoint(x: p.x - webView.frame.minX, y: p.y - webView.frame.minY))
    }

    // MARK: Selected Shape State & Helpers

    private func selectStroke(_ id: UUID, fallbackOrigin: CGPoint = .zero) {
        selectedStrokeID = id
        selectedAnchorFallbackOrigin = fallbackOrigin
        refreshSelectedShapeOverlay()
    }

    private func clearSelectedShape() {
        guard selectedStrokeID != nil || geometryOverlay.selectedShape != nil else { return }
        selectedStrokeID = nil
        geometryOverlay.isEditingSelectedShape = false
        geometryOverlay.selectedShape = nil
    }

    private func anchorOrigin(for stroke: InkStroke) -> CGPoint {
        if let placement = bridge.placements[stroke.id] {
            return placement.origin
        }
        if stroke.id == selectedStrokeID {
            return selectedAnchorFallbackOrigin
        }
        return .zero
    }

    private func overlayModel(for stroke: InkStroke, docPrimitive: GeometricPrimitive) -> SelectedShapeOverlay {
        let transform = viewTransform()
        let handles = docPrimitive.controlHandles().map { $0.applying(transform) }
        let box = docPrimitive.boundingBox().applying(transform)
        return SelectedShapeOverlay(
            strokeID: stroke.id,
            handles: handles,
            boundingBox: box,
            lineStyle: stroke.resolvedLineStyle,
            supportsFill: docPrimitive.supportsFill,
            isFilled: stroke.fillColor != nil,
            isCircularWithCenterMark: docPrimitive.isCircularWithCenterMark,
            showsCenterMark: docPrimitive.showsCenterMark
        )
    }

    private func refreshSelectedShapeOverlay() {
        guard let id = selectedStrokeID else {
            if geometryOverlay.selectedShape != nil {
                geometryOverlay.selectedShape = nil
            }
            return
        }
        // While actively dragging a vertex or body, the drag handler drives the live overlay.
        switch activeInteraction {
        case .selectedHandle, .selectedBody:
            return
        default:
            break
        }
        guard let stroke = session.strokes(onPage: Self.page).first(where: { $0.id == id }),
              let geom = stroke.geometry else {
            clearSelectedShape()
            return
        }
        if let placement = bridge.placements[id], !placement.visible {
            clearSelectedShape()
            return
        }
        let origin = anchorOrigin(for: stroke)
        let docPrimitive = geom.translated(by: origin)
        geometryOverlay.selectedShape = overlayModel(for: stroke, docPrimitive: docPrimitive)
    }

    private func beginSelectedShapeInteraction(at viewPoint: CGPoint) -> ActiveInteraction? {
        guard let id = selectedStrokeID,
              let overlay = geometryOverlay.selectedShape,
              overlay.strokeID == id,
              let stroke = session.strokes(onPage: Self.page).first(where: { $0.id == id }),
              let geom = stroke.geometry else { return nil }

        let origin = anchorOrigin(for: stroke)
        let docPrimitive = geom.translated(by: origin)
        let docPoint = documentPoint(fromViewPoint: viewPoint)
        let docTol = 14 / max(webView.scrollView.zoomScale, 0.25)
        let bodyHit = docPrimitive.hitTestBody(docPoint, tolerance: docTol)
        let hit = overlay.hitTest(viewPoint, in: view.bounds, bodyHit: bodyHit)

        switch hit {
        case .none:
            return nil
        case let .action(button):
            return .selectedAction(button, startPoint: viewPoint)
        case let .handle(index):
            let context = startEditingSelectedStroke(stroke, origin: origin, docPrimitive: docPrimitive)
            return .selectedHandle(index: index, context: context)
        case .body:
            let context = startEditingSelectedStroke(stroke, origin: origin, docPrimitive: docPrimitive)
            return .selectedBody(startDoc: docPoint, context: context)
        }
    }

    private func startEditingSelectedStroke(_ stroke: InkStroke, origin: CGPoint,
                                            docPrimitive: GeometricPrimitive) -> ShapeEditContext {
        let originalStrokes = session.strokes(onPage: Self.page)
        refreshViewSnapPoints(excludingStrokeID: stroke.id)
        // Temporarily hide the original SVG in WebKit while dragging at 60fps in native live layers.
        bridge.sync(originalStrokes.filter { $0.id != stroke.id })
        geometryOverlay.isEditingSelectedShape = true
        configureLiveLayer(for: stroke)
        renderEditedShape(stroke: stroke, docPrimitive: docPrimitive)
        return ShapeEditContext(
            strokeID: stroke.id,
            originalStrokes: originalStrokes,
            originalStroke: stroke,
            anchorOrigin: origin,
            baseDocPrimitive: docPrimitive,
            currentDocPrimitive: docPrimitive
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

    private func renderEditedShape(stroke: InkStroke, docPrimitive: GeometricPrimitive) {
        var preview = stroke
        preview.geometry = docPrimitive
        preview.baked = nil
        preview.points = []
        let transform = viewTransform()
        let outline = preview.outlinePath(transform: transform, finished: true)
        let fill = preview.fillPath(transform: transform)
        setLivePath(outline, fillPath: fill, fillColor: preview.fillColor?.cgColor)
        geometryOverlay.selectedShape = overlayModel(for: stroke, docPrimitive: docPrimitive)
    }

    private func commitEditedShape(_ context: ShapeEditContext) {
        let updatedLocal = context.currentDocPrimitive.translated(by: CGPoint(x: -context.anchorOrigin.x,
                                                                              y: -context.anchorOrigin.y))
        var updated = context.originalStroke
        updated.geometry = updatedLocal
        updated.baked = nil
        updated.points = []

        if updated == context.originalStroke {
            setLivePath(nil)
            pushStrokes()
            refreshSelectedShapeOverlay()
            return
        }

        // Keep a pending native layer across the WebKit sync so there is zero flash.
        var docPreview = updated
        docPreview.geometry = context.currentDocPrimitive
        let transform = viewTransform()
        let pending = CAShapeLayer()
        pending.frame = pendingContainer.bounds
        pending.fillRule = .nonZero
        pending.path = docPreview.outlinePath(transform: transform, finished: true)
        pending.fillColor = liveLayer.fillColor
        pending.opacity = liveLayer.opacity
        pending.compositingFilter = liveLayer.compositingFilter
        pendingContainer.addSublayer(pending)

        var pendingFill: CAShapeLayer?
        if let fillColor = docPreview.fillColor, let fillPath = docPreview.fillPath(transform: transform) {
            let fl = CAShapeLayer()
            fl.frame = pendingFillContainer.bounds
            fl.fillRule = .nonZero
            fl.opacity = 0.18
            fl.fillColor = fillColor.cgColor
            fl.path = fillPath
            pendingFillContainer.addSublayer(fl)
            pendingFill = fl
        }
        pendingItems.append(PendingItem(id: updated.id, layer: pending, fillLayer: pendingFill,
                                        isHighlighter: updated.isHighlighter))
        setLivePath(nil)

        let after = context.originalStrokes.map { $0.id == updated.id ? updated : $0 }
        session.replaceStrokes(onPage: Self.page, before: context.originalStrokes, after: after)
        refreshSelectedShapeOverlay()
    }

    private func executeSelectedShapeAction(_ action: SelectedShapeOverlay.ActionButton) {
        guard let id = selectedStrokeID else { return }
        let before = session.strokes(onPage: Self.page)
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
            session.replaceStrokes(onPage: Self.page, before: before, after: after)
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
            session.replaceStrokes(onPage: Self.page, before: before, after: after)
            haptic.impactOccurred()

        case .duplicate:
            var copy = stroke.translated(by: CGPoint(x: 24, y: 24))
            copy.id = UUID()
            let fallbackOrigin = anchorOrigin(for: stroke)
            session.addStroke(copy, page: Self.page)
            selectStroke(copy.id, fallbackOrigin: fallbackOrigin)
            haptic.impactOccurred()

        case .delete:
            var after = before
            after.remove(at: idx)
            clearSelectedShape()
            session.replaceStrokes(onPage: Self.page, before: before, after: after)
            haptic.impactOccurred()
        }
    }

    private func hitTestExistingGeometricStroke(atDoc docPoint: CGPoint) -> InkStroke? {
        let tolerance = 14 / max(webView.scrollView.zoomScale, 0.25)
        let strokes = session.strokes(onPage: Self.page)
        for stroke in strokes.reversed() {
            guard let geom = stroke.geometry else { continue }
            if let placement = bridge.placements[stroke.id], !placement.visible { continue }
            let origin = bridge.placements[stroke.id]?.origin ?? .zero
            if geom.translated(by: origin).hitTestBody(docPoint, tolerance: tolerance) {
                return stroke
            }
        }
        return nil
    }

    private func beginShapeCreation(at viewPoint: CGPoint) -> ActiveInteraction {
        refreshViewSnapPoints()
        let rawDoc = documentPoint(fromViewPoint: viewPoint)
        let docThreshold = 10 / max(webView.scrollView.zoomScale, 0.25)
        let startSnap = GeometrySnapEngine.nearestPoint(to: rawDoc, in: cachedDocSnapPoints, threshold: docThreshold)
        let startDoc = startSnap?.point ?? rawDoc
        if let startSnap {
            updateSnapFeedback(SnapPoint(point: startSnap.point.applying(viewTransform()), kind: startSnap.kind))
        }
        configureLiveLayerForCurrentTool()
        return .shapeCreate(preset: liveTool.shapePreset, startDoc: startDoc, rawStartView: viewPoint, currentPrimitive: nil)
    }

    private func renderShapeCreationPreview(_ primitive: GeometricPrimitive) {
        let stroke = makeGeometricStroke(primitive, allowFill: liveTool.shapeFilled)
        let transform = viewTransform()
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
                protractorDetectGeneration &+= 1
                refreshViewSnapPoints()
                let offset = CGPoint(x: protractorState.center.x - viewPoint.x, y: protractorState.center.y - viewPoint.y)
                return .protractorCenter(grabOffset: offset)
            case .ray1Handle:
                protractorDetectGeneration &+= 1
                refreshViewSnapPoints()
                return .protractorRay1
            case .ray2Handle:
                protractorDetectGeneration &+= 1
                refreshViewSnapPoints()
                return .protractorRay2
            case .ringRotate:
                protractorDetectGeneration &+= 1
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
            refreshViewSnapPoints()
            let offset = CGPoint(x: compassState.center.x - viewPoint.x, y: compassState.center.y - viewPoint.y)
            return .compassNeedle(grabOffset: offset)
        case .resizeHandle:
            refreshViewSnapPoints()
            geometryOverlay.isResizingCompass = true
            return .compassResize
        case .drawCircle:
            guard allowDrawing else { return nil }
            let startAngle = atan2(viewPoint.y - compassState.center.y, viewPoint.x - compassState.center.x)
            compassState.armAngle = startAngle
            geometryOverlay.compass = compassState
            configureLiveLayerForCurrentTool()
            let sweep = CompassSweep(startAngle: startAngle)
            geometryOverlay.activeCompassSweep = sweep
            renderCompassLiveSweep(sweep)
            return .compassDraw(sweep: sweep, crossedCloseHaptic: false)
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

        case .compassButton, .protractorButton, .selectedAction:
            return true

        case var .compassDraw(sweep, crossedCloseHaptic):
            sweep.advance(to: viewPoint, center: compassState.center)
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

        case let .shapeCreate(preset, startDoc, rawStartView, _):
            let currentDoc = documentPoint(fromViewPoint: viewPoint)
            let docThreshold = 10 / max(webView.scrollView.zoomScale, 0.25)
            let built = ShapeBuilder.build(preset: preset, from: startDoc, to: currentDoc,
                                           snapPoints: cachedDocSnapPoints, snapThreshold: docThreshold)
            if let snap = built.snapped {
                updateSnapFeedback(SnapPoint(point: snap.point.applying(viewTransform()), kind: snap.kind))
            } else {
                updateSnapFeedback(nil)
            }
            activeInteraction = .shapeCreate(preset: preset, startDoc: startDoc,
                                             rawStartView: rawStartView, currentPrimitive: built.primitive)
            renderShapeCreationPreview(built.primitive)
            return true

        case var .selectedHandle(index, context):
            let currentDoc = documentPoint(fromViewPoint: viewPoint)
            let docThreshold = 10 / max(webView.scrollView.zoomScale, 0.25)
            let moved = context.baseDocPrimitive.movingHandle(at: index, to: currentDoc,
                                                              snapPoints: cachedDocSnapPoints,
                                                              snapThreshold: docThreshold)
            context.currentDocPrimitive = moved.primitive
            if let snap = moved.snapped {
                updateSnapFeedback(SnapPoint(point: snap.point.applying(viewTransform()), kind: snap.kind))
            } else {
                updateSnapFeedback(nil)
            }
            activeInteraction = .selectedHandle(index: index, context: context)
            renderEditedShape(stroke: context.originalStroke, docPrimitive: context.currentDocPrimitive)
            return true

        case var .selectedBody(startDoc, context):
            let currentDoc = documentPoint(fromViewPoint: viewPoint)
            let delta = CGPoint(x: currentDoc.x - startDoc.x, y: currentDoc.y - startDoc.y)
            context.currentDocPrimitive = context.baseDocPrimitive.translated(by: delta)
            activeInteraction = .selectedBody(startDoc: startDoc, context: context)
            renderEditedShape(stroke: context.originalStroke, docPrimitive: context.currentDocPrimitive)
            return true

        case var .lassoDraw(docPoints, rawStartView):
            let currentDoc = documentPoint(fromViewPoint: viewPoint)
            if let last = docPoints.last, hypot(currentDoc.x - last.x, currentDoc.y - last.y) >= 2.5 {
                docPoints.append(currentDoc)
            }
            activeInteraction = .lassoDraw(docPoints: docPoints, rawStartView: rawStartView)
            let transform = viewTransform()
            geometryOverlay.activeLassoPath = docPoints.map { $0.applying(transform) }
            return true

        case var .lassoMove(startDoc, context):
            let currentDoc = documentPoint(fromViewPoint: viewPoint)
            let delta = CGPoint(x: currentDoc.x - startDoc.x, y: currentDoc.y - startDoc.y)
            context.currentTranslation = delta
            activeInteraction = .lassoMove(startDoc: startDoc, context: context)
            applyLassoLivePreviewTransform(context: context)
            return true

        case var .lassoScale(corner, startCornerDoc, context):
            let currentDoc = documentPoint(fromViewPoint: viewPoint)
            let pivotDoc = context.pivotDoc
            let v0x = startCornerDoc.x - pivotDoc.x
            let v0y = startCornerDoc.y - pivotDoc.y
            let d0 = max(16, hypot(v0x, v0y))
            let ux = v0x / d0
            let uy = v0y / d0
            let proj = (currentDoc.x - pivotDoc.x) * ux + (currentDoc.y - pivotDoc.y) * uy
            context.currentScale = max(0.25, min(4.0, proj / d0))
            activeInteraction = .lassoScale(corner: corner, startCornerDoc: startCornerDoc, context: context)
            applyLassoLivePreviewTransform(context: context)
            return true

        case .lassoAction:
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

        case let .lassoDraw(docPoints, rawStartView):
            finishGeometryAidInteraction()
            geometryOverlay.activeLassoPath = []
            let dragDist = hypot(viewPoint.x - rawStartView.x, viewPoint.y - rawStartView.y)
            let origins = visibleDocumentOrigins()
            let strokes = session.strokes(onPage: Self.page)
            if dragDist < 8, docPoints.count <= 4 {
                let docPt = documentPoint(fromViewPoint: viewPoint)
                let docTol = 14 / max(webView.scrollView.zoomScale, 0.25)
                if let hitID = LassoEngine.hitTestSingleStroke(from: strokes, origins: origins,
                                                               at: docPt, tolerance: docTol, cache: geometryCache) {
                    selectLassoStrokes([hitID])
                    haptic.impactOccurred()
                }
            } else {
                let ids = LassoEngine.selectStrokeIDs(from: strokes, origins: origins,
                                                      polygon: docPoints, cache: geometryCache)
                if !ids.isEmpty {
                    selectLassoStrokes(ids)
                    haptic.impactOccurred()
                }
            }
            return true

        case let .lassoMove(_, context), let .lassoScale(_, _, context):
            finishGeometryAidInteraction()
            commitLassoTransform(context)
            return true

        case var .compassDraw(sweep, _):
            sweep.advance(to: viewPoint, center: compassState.center)
            finishGeometryAidInteraction()
            let centerDoc = documentPoint(fromViewPoint: compassState.center)
            let zoom = max(webView.scrollView.zoomScale, 0.0001)
            let radiusDoc = compassState.radius / zoom
            if let primitive = sweep.primitive(center: centerDoc, radius: radiusDoc,
                                               showCenterMark: compassState.showCenterMark) {
                let stroke = makeGeometricStroke(primitive)
                commitPreparedStroke(stroke)
            } else {
                setLivePath(nil)
            }
            return true

        case let .shapeCreate(preset, startDoc, rawStartView, _):
            finishGeometryAidInteraction()
            let dragDist = hypot(viewPoint.x - rawStartView.x, viewPoint.y - rawStartView.y)
            if dragDist < 8 {
                setLivePath(nil)
                let docPoint = documentPoint(fromViewPoint: viewPoint)
                if let hitStroke = hitTestExistingGeometricStroke(atDoc: docPoint) {
                    selectStroke(hitStroke.id, fallbackOrigin: bridge.placements[hitStroke.id]?.origin ?? .zero)
                    haptic.impactOccurred()
                }
                return true
            }
            let currentDoc = documentPoint(fromViewPoint: viewPoint)
            let docThreshold = 10 / max(webView.scrollView.zoomScale, 0.25)
            let built = ShapeBuilder.build(preset: preset, from: startDoc, to: currentDoc,
                                           snapPoints: cachedDocSnapPoints, snapThreshold: docThreshold)
            let stroke = makeGeometricStroke(built.primitive, allowFill: liveTool.shapeFilled)
            commitPreparedStroke(stroke, selectAfterCommit: true)
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
        case .selectedHandle, .selectedBody:
            setLivePath(nil)
            pushStrokes()
        case .lassoDraw:
            geometryOverlay.activeLassoPath = []
        case .lassoMove, .lassoScale:
            clearLassoPreviewLayers()
            pushStrokes()
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
            liveTool = session.tool
            configureLiveLayerForCurrentTool()
            let centerDoc = documentPoint(fromViewPoint: compassState.center)
            let zoom = max(webView.scrollView.zoomScale, 0.0001)
            let radiusDoc = compassState.radius / zoom
            let stroke = makeGeometricStroke(.circle(center: centerDoc, radius: radiusDoc,
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
            autoDetectProtractorAngle(allowImageFallback: true, triggerHaptic: true, announceFailure: true)
        case .cycleAngleButton:
            protractorDetectGeneration &+= 1
            protractorState.cycleAngle()
            geometryOverlay.protractor = protractorState
            pushPresentationOverlay()
            haptic.impactOccurred()
        case .stampAngleButton:
            liveTool = session.tool
            configureLiveLayerForCurrentTool()
            let centerDoc = documentPoint(fromViewPoint: protractorState.center)
            let zoom = max(webView.scrollView.zoomScale, 0.0001)
            let arcRadiusDoc = min(34, protractorState.radius * 0.28) / zoom
            if let primitive = protractorState.stampPrimitive(center: centerDoc, radius: arcRadiusDoc) {
                let stroke = makeGeometricStroke(primitive)
                commitPreparedStroke(stroke)
                haptic.impactOccurred()
                NotificationCenter.default.post(
                    name: .quillmarkUndoRedoFeedback,
                    object: nil,
                    userInfo: ["message": "已标注 \(protractorState.formattedDegrees)"]
                )
            }
        case .closeButton:
            protractorDetectGeneration &+= 1
            session.geometryAid = .none
            haptic.impactOccurred()
        default:
            break
        }
    }

    /// Automatically measures the angle at `protractorState.center`: first inspects exact vector strokes
    /// on the HTML page, then falls back to an asynchronous local WKWebView patch scan for printed/Canvas/SVG figures.
    private func autoDetectProtractorAngle(allowImageFallback: Bool, triggerHaptic: Bool, announceFailure: Bool = false) {
        guard session.geometryAid == .protractor else { return }
        protractorDetectGeneration &+= 1
        let generation = protractorDetectGeneration

        let origins = visibleDocumentOrigins()
        let centerDoc = documentPoint(fromViewPoint: protractorState.center)
        let docTol = 16 / max(webView.scrollView.zoomScale, 0.25)
        let vectorRays = ProtractorAngleDetector.detectVectorRays(
            at: centerDoc,
            from: session.strokes(onPage: Self.page),
            origins: origins,
            tolerance: docTol
        )
        if protractorState.applyDetectedRays(vectorRays, source: .vector) {
            geometryOverlay.protractor = protractorState
            pushPresentationOverlay()
            if triggerHaptic { haptic.impactOccurred(intensity: 0.7) }
            return
        }

        guard allowImageFallback, webView.bounds.width > 48, webView.bounds.height > 48 else {
            if announceFailure {
                NotificationCenter.default.post(
                    name: .quillmarkUndoRedoFeedback,
                    object: nil,
                    userInfo: ["message": "未检测到明显角边，请将圆心对准顶点或手动拖射线"]
                )
            }
            return
        }
        let half: CGFloat = 72
        let ptInWeb = view.convert(protractorState.center, to: webView)
        let cropRect = CGRect(x: ptInWeb.x - half, y: ptInWeb.y - half, width: half * 2, height: half * 2)
            .intersection(webView.bounds)
        guard cropRect.width >= 48, cropRect.height >= 48 else { return }

        let config = WKSnapshotConfiguration()
        config.rect = cropRect
        config.snapshotWidth = NSNumber(value: Double(cropRect.width))
        config.afterScreenUpdates = false
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self,
                  self.protractorDetectGeneration == generation,
                  self.session.geometryAid == .protractor,
                  let cgImage = image?.cgImage else { return }
            let scaleX = CGFloat(cgImage.width) / max(1, cropRect.width)
            let scaleY = CGFloat(cgImage.height) / max(1, cropRect.height)
            let centerInImage = CGPoint(
                x: (ptInWeb.x - cropRect.minX) * scaleX,
                y: (ptInWeb.y - cropRect.minY) * scaleY
            )
            guard let detected = ProtractorAngleDetector.detectImageRays(in: cgImage, center: centerInImage) else {
                if announceFailure {
                    NotificationCenter.default.post(
                        name: .quillmarkUndoRedoFeedback,
                        object: nil,
                        userInfo: ["message": "未检测到明显角边，请将圆心对准顶点或手动拖射线"]
                    )
                }
                return
            }
            self.protractorState.center.x += detected.vertexOffset.x / max(0.5, scaleX)
            self.protractorState.center.y += detected.vertexOffset.y / max(0.5, scaleY)
            if self.protractorState.applyDetectedRays(detected.rayAngles, source: .image) {
                self.geometryOverlay.protractor = self.protractorState
                self.pushPresentationOverlay()
                if triggerHaptic { self.haptic.impactOccurred(intensity: 0.7) }
            }
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

    // MARK: Lasso Selection, GPU Move/Scale Preview & Batch Actions (iPad-Only UI)

    private func visibleDocumentOrigins() -> [UUID: CGPoint] {
        var origins = bridge.placements.compactMapValues { $0.visible ? $0.origin : nil }
        for (id, fallback) in lassoFallbackOrigins where origins[id] == nil {
            origins[id] = fallback
        }
        return origins
    }

    private func lassoOrigin(for stroke: InkStroke) -> CGPoint {
        if let placement = bridge.placements[stroke.id] {
            return placement.origin
        }
        if let fallback = lassoFallbackOrigins[stroke.id] {
            return fallback
        }
        return .zero
    }

    private func selectLassoStrokes(_ ids: [UUID]) {
        lassoSelectedIDs = ids
        refreshLassoSelectionOverlay()
    }

    private func clearLassoSelection() {
        guard !lassoSelectedIDs.isEmpty || geometryOverlay.lassoSelection != nil || !geometryOverlay.activeLassoPath.isEmpty else {
            return
        }
        lassoSelectedIDs.removeAll()
        lassoFallbackOrigins.removeAll()
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
        let selected = session.strokes(onPage: Self.page).filter { idSet.contains($0.id) }
        guard !selected.isEmpty else {
            clearLassoSelection()
            return
        }
        let origins = visibleDocumentOrigins()
        let docBox = LassoEngine.documentBounds(of: selected, origins: origins, cache: geometryCache)
        guard !docBox.isNull, docBox.minX.isFinite, docBox.minY.isFinite else {
            clearLassoSelection()
            return
        }
        let viewBox = docBox.applying(viewTransform())
        let firstColor = selected.first?.color
        let sharedColor = selected.allSatisfy({ $0.color == firstColor }) ? firstColor : nil
        geometryOverlay.lassoSelection = LassoSelectionOverlay(
            strokeIDs: selected.map(\.id),
            boundingBox: viewBox,
            activeColor: sharedColor
        )
    }

    private func beginLassoDraw(at viewPoint: CGPoint) -> ActiveInteraction {
        let docPt = documentPoint(fromViewPoint: viewPoint)
        geometryOverlay.activeLassoPath = [viewPoint]
        return .lassoDraw(docPoints: [docPt], rawStartView: viewPoint)
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
            let startDoc = documentPoint(fromViewPoint: viewPoint)
            return .lassoMove(startDoc: startDoc, context: context)
        case let .handle(corner):
            guard var context = startLassoTransform() else { return nil }
            context.pivotDoc = overlay.oppositeCorner(of: corner, in: context.baseDocBox)
            let startCornerDoc = overlay.cornerPoint(of: corner, in: context.baseDocBox)
            return .lassoScale(corner: corner, startCornerDoc: startCornerDoc, context: context)
        }
    }

    private func startLassoTransform() -> LassoTransformContext? {
        let originalStrokes = session.strokes(onPage: Self.page)
        let selectedSet = Set(lassoSelectedIDs)
        let selectedStrokes = originalStrokes.filter { selectedSet.contains($0.id) }
        guard !selectedStrokes.isEmpty else { return nil }

        let origins = visibleDocumentOrigins()
        let baseDocBox = LassoEngine.documentBounds(of: selectedStrokes, origins: origins, cache: geometryCache)
        guard !baseDocBox.isNull else { return nil }

        let transform = viewTransform()
        var docStrokesByID: [UUID: InkStroke] = [:]
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
            let origin = lassoOrigin(for: stroke)
            let docStroke = stroke.translated(by: origin)
            docStrokesByID[stroke.id] = docStroke

            let viewPath = docStroke.outlinePath(transform: transform, finished: true)
            let fillPath = docStroke.fillPath(transform: transform)
            let fillColor = docStroke.fillColor?.cgColor

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
            if docStroke.isHighlighter {
                opacity = PageInkView.highlighterOpacity
                layer.compositingFilter = "multiplyBlendMode"
            } else if docStroke.isTape {
                opacity = docStroke.isRevealed ? 0.16 : 0.96
                layer.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
                layer.lineWidth = 1
                layer.lineDashPattern = [5, 3]
            } else {
                opacity = 1
            }
            layer.fillColor = docStroke.color.cgColor
            layer.opacity = opacity
            lassoPreviewContainer.addSublayer(layer)

            entries.append(LassoPreviewEntry(
                baseViewPath: viewPath,
                baseFillPath: fillPath,
                strokeColor: docStroke.color.cgColor,
                fillColor: fillColor,
                opacity: opacity,
                isHighlighter: docStroke.isHighlighter
            ))
        }
        lassoPreviewEntries = entries
        lassoPreviewTransform = .identity
        CATransaction.commit()

        // Temporarily hide original SVG strokes in WebKit while dragging at 120fps natively.
        bridge.sync(originalStrokes.filter { !selectedSet.contains($0.id) })
        geometryOverlay.isTransformingLasso = true
        pushPresentationOverlay()

        return LassoTransformContext(
            originalStrokes: originalStrokes,
            selectedIDs: selectedSet,
            docStrokesByID: docStrokesByID,
            baseDocBox: baseDocBox,
            baseViewTransform: transform
        )
    }

    private func applyLassoLivePreviewTransform(context: LassoTransformContext) {
        let baseT = context.baseViewTransform
        let previewT: CGAffineTransform
        if abs(context.currentScale - 1) > 1e-4 {
            let pivotView = context.pivotDoc.applying(baseT)
            let s = context.currentScale
            previewT = CGAffineTransform(translationX: pivotView.x, y: pivotView.y)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -pivotView.x, y: -pivotView.y)
        } else {
            let dxV = context.currentTranslation.x * baseT.a
            let dyV = context.currentTranslation.y * baseT.d
            previewT = CGAffineTransform(translationX: dxV, y: dyV)
        }

        lassoPreviewTransform = previewT
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewFillContainer.setAffineTransform(previewT)
        lassoPreviewContainer.setAffineTransform(previewT)
        CATransaction.commit()

        if var overlay = geometryOverlay.lassoSelection {
            let baseViewBox = context.baseDocBox.applying(baseT)
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
        if isUnchanged {
            clearLassoPreviewLayers()
            pushStrokes()
            refreshLassoSelectionOverlay()
            pushPresentationOverlay()
            return
        }

        // Compute exact transformed strokes in document space.
        var transformedDocByID: [UUID: InkStroke] = [:]
        var newDocBox = CGRect.null
        for (id, docStroke) in context.docStrokesByID {
            let updated = LassoEngine.transformStroke(docStroke,
                                                      scale: context.currentScale,
                                                      around: context.pivotDoc,
                                                      translation: context.currentTranslation)
            transformedDocByID[id] = updated
            let sb = geometryCache.bounds(for: updated)
            if !sb.isNull { newDocBox = newDocBox.union(sb) }
            if let gb = updated.geometry?.boundingBox(), !gb.isNull { newDocBox = newDocBox.union(gb) }
        }

        // Hand off transformed preview paths into `pendingItems` so there is zero blink across WebKit sync.
        let viewT = viewTransform()
        var pendingIDs: Set<UUID> = []
        for (id, docStroke) in transformedDocByID {
            let pending = CAShapeLayer()
            pending.frame = pendingContainer.bounds
            pending.fillRule = .nonZero
            pending.path = docStroke.outlinePath(transform: viewT, finished: true)
            pending.fillColor = docStroke.color.cgColor
            if docStroke.isHighlighter {
                pending.opacity = PageInkView.highlighterOpacity
                pending.compositingFilter = "multiplyBlendMode"
            } else if docStroke.isTape {
                pending.opacity = docStroke.isRevealed ? 0.16 : 0.96
                pending.strokeColor = UIColor.black.withAlphaComponent(0.25).cgColor
                pending.lineWidth = 1
                pending.lineDashPattern = [5, 3]
            } else {
                pending.opacity = 1
            }
            pendingContainer.addSublayer(pending)

            var pendingFill: CAShapeLayer?
            if let fillColor = docStroke.fillColor, let fillPath = docStroke.fillPath(transform: viewT) {
                let fl = CAShapeLayer()
                fl.frame = pendingFillContainer.bounds
                fl.fillRule = .nonZero
                fl.opacity = 0.18
                fl.fillColor = fillColor.cgColor
                fl.path = fillPath
                pendingFillContainer.addSublayer(fl)
                pendingFill = fl
            }
            pendingItems.append(PendingItem(id: id, layer: pending, fillLayer: pendingFill,
                                            isHighlighter: docStroke.isHighlighter))
            pendingIDs.insert(id)
        }
        clearLassoPreviewLayers()
        pushPresentationOverlay()

        let anchorPoint: CGPoint
        if newDocBox.isNull || !newDocBox.midX.isFinite || !newDocBox.midY.isFinite {
            anchorPoint = CGPoint(x: context.baseDocBox.midX + context.currentTranslation.x,
                                  y: context.baseDocBox.midY + context.currentTranslation.y)
        } else {
            anchorPoint = CGPoint(x: newDocBox.midX, y: newDocBox.midY)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let pick = await self.bridge.pickAnchor(at: anchorPoint)
            let newOrigin = pick?.origin ?? .zero
            let newAnchor = pick?.anchor ?? .body
            let inverseOffset = CGPoint(x: -newOrigin.x, y: -newOrigin.y)

            let after = context.originalStrokes.map { stroke -> InkStroke in
                guard let docStroke = transformedDocByID[stroke.id] else { return stroke }
                var reanchored = docStroke.translated(by: inverseOffset)
                reanchored.anchor = newAnchor
                self.lassoFallbackOrigins[stroke.id] = newOrigin
                return reanchored
            }
            self.session.replaceStrokes(onPage: Self.page, before: context.originalStrokes, after: after)
            self.refreshLassoSelectionOverlay()

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.removePendingItems(matching: pendingIDs)
        }
    }

    private func executeLassoAction(_ action: LassoSelectionOverlay.ActionButton) {
        guard !lassoSelectedIDs.isEmpty else { return }
        let before = session.strokes(onPage: Self.page)
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
            session.replaceStrokes(onPage: Self.page, before: before, after: after)
            refreshLassoSelectionOverlay()
            haptic.impactOccurred()

        case .duplicate:
            var newIDs: [UUID] = []
            var copies: [InkStroke] = []
            for stroke in before where selectedSet.contains(stroke.id) {
                var copy = stroke.translated(by: CGPoint(x: 24, y: 24))
                copy.id = UUID()
                lassoFallbackOrigins[copy.id] = lassoOrigin(for: stroke)
                newIDs.append(copy.id)
                copies.append(copy)
            }
            guard !copies.isEmpty else { return }
            let after = before + copies
            lassoSelectedIDs = newIDs
            session.replaceStrokes(onPage: Self.page, before: before, after: after)
            refreshLassoSelectionOverlay()
            haptic.impactOccurred()

        case .delete:
            let after = before.filter { !selectedSet.contains($0.id) }
            clearLassoSelection()
            session.replaceStrokes(onPage: Self.page, before: before, after: after)
            haptic.impactOccurred()
        }
    }

    private func renderCompassLiveSweep(_ sweep: CompassSweep) {
        let centerDoc = documentPoint(fromViewPoint: compassState.center)
        let zoom = max(webView.scrollView.zoomScale, 0.0001)
        let radiusDoc = compassState.radius / zoom
        guard let primitive = sweep.primitive(center: centerDoc, radius: radiusDoc,
                                              showCenterMark: compassState.showCenterMark) else {
            setLivePath(nil)
            return
        }
        let stroke = makeGeometricStroke(primitive)
        setLivePath(stroke.outlinePath(transform: viewTransform(), finished: true))
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
        holdTimer?.cancel()
        holdTimer = nil
        snappedBaseShape = nil
        snappedCurrentShape = nil
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        liveStartTime = touch.timestamp

        configureLiveLayerForCurrentTool()

        holdAnchorViewPoint = touch.location(in: view)
        append(event?.coalescedTouches(for: touch) ?? [touch])
        updateLiveStroke(predicted: [])
        scheduleHoldRecognitionIfNeeded()
    }

    private func drawMoved(_ touch: UITouch, event: UIEvent?) {
        if let baseShape = snappedBaseShape {
            let currentDoc = documentPoint(touch)
            let docThreshold = 10 / max(webView.scrollView.zoomScale, 0.25)
            switch baseShape {
            case let .line(start, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: currentDoc, in: cachedDocSnapPoints,
                                                              threshold: docThreshold, excluding: start, excludeRadius: 8) {
                    snappedCurrentShape = .line(start: start, end: snap.point)
                    updateSnapFeedback(SnapPoint(point: snap.point.applying(viewTransform()), kind: snap.kind))
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: currentDoc, initialAnchor: snapDragOriginDocPoint)
                    updateSnapFeedback(nil)
                }
            case let .arrow(start, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: currentDoc, in: cachedDocSnapPoints,
                                                              threshold: docThreshold, excluding: start, excludeRadius: 8) {
                    snappedCurrentShape = .arrow(start: start, end: snap.point)
                    updateSnapFeedback(SnapPoint(point: snap.point.applying(viewTransform()), kind: snap.kind))
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: currentDoc, initialAnchor: snapDragOriginDocPoint)
                    updateSnapFeedback(nil)
                }
            case let .circle(center, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: currentDoc, in: cachedDocSnapPoints,
                                                              threshold: docThreshold, excluding: center, excludeRadius: 12) {
                    let r = max(12, hypot(snap.point.x - center.x, snap.point.y - center.y))
                    snappedCurrentShape = .circle(center: center, radius: r)
                    updateSnapFeedback(SnapPoint(point: snap.point.applying(viewTransform()), kind: snap.kind))
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: currentDoc, initialAnchor: snapDragOriginDocPoint)
                    updateSnapFeedback(nil)
                }
            case let .parabola(vertex, _, _, _):
                if let snap = GeometrySnapEngine.nearestPoint(to: currentDoc, in: cachedDocSnapPoints,
                                                              threshold: docThreshold, excluding: vertex, excludeRadius: 12) {
                    snappedCurrentShape = baseShape.adjusted(to: snap.point, initialAnchor: snapDragOriginDocPoint)
                    updateSnapFeedback(SnapPoint(point: snap.point.applying(viewTransform()), kind: snap.kind))
                } else {
                    snappedCurrentShape = baseShape.adjusted(to: currentDoc, initialAnchor: snapDragOriginDocPoint)
                    updateSnapFeedback(nil)
                }
            case .rectangle, .polygon:
                snappedCurrentShape = baseShape.adjusted(to: currentDoc, initialAnchor: snapDragOriginDocPoint)
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
        let pts = livePoints.map(\.location)
        guard var shape = ShapeRecognizer.recognize(pts) else { return }
        // Snap line/arrow start & end onto existing geometric endpoints/intersections/centers.
        refreshViewSnapPoints()
        let docThreshold = 10 / max(webView.scrollView.zoomScale, 0.25)
        switch shape {
        case let .line(start, end):
            let s = GeometrySnapEngine.nearestPoint(to: start, in: cachedDocSnapPoints, threshold: docThreshold)?.point ?? start
            if let endSnap = GeometrySnapEngine.nearestPoint(to: end, in: cachedDocSnapPoints,
                                                             threshold: docThreshold, excluding: s, excludeRadius: 8) {
                shape = .line(start: s, end: endSnap.point)
                updateSnapFeedback(SnapPoint(point: endSnap.point.applying(viewTransform()), kind: endSnap.kind))
            } else {
                shape = .line(start: s, end: end)
            }
        case let .arrow(start, end):
            let s = GeometrySnapEngine.nearestPoint(to: start, in: cachedDocSnapPoints, threshold: docThreshold)?.point ?? start
            if let endSnap = GeometrySnapEngine.nearestPoint(to: end, in: cachedDocSnapPoints,
                                                             threshold: docThreshold, excluding: s, excludeRadius: 8) {
                shape = .arrow(start: s, end: endSnap.point)
                updateSnapFeedback(SnapPoint(point: endSnap.point.applying(viewTransform()), kind: endSnap.kind))
            } else {
                shape = .arrow(start: s, end: end)
            }
        case let .circle(center, radius):
            if let centerSnap = GeometrySnapEngine.nearestPoint(to: center, in: cachedDocSnapPoints, threshold: docThreshold) {
                shape = .circle(center: centerSnap.point, radius: radius)
                updateSnapFeedback(SnapPoint(point: centerSnap.point.applying(viewTransform()), kind: centerSnap.kind))
            }
        case let .parabola(vertex, axisAngle, halfWidth, height):
            if let vertexSnap = GeometrySnapEngine.nearestPoint(to: vertex, in: cachedDocSnapPoints, threshold: docThreshold) {
                shape = .parabola(vertex: vertexSnap.point, axisAngle: axisAngle, halfWidth: halfWidth, height: height)
                updateSnapFeedback(SnapPoint(point: vertexSnap.point.applying(viewTransform()), kind: vertexSnap.kind))
            }
        case .rectangle, .polygon:
            break
        }
        snappedBaseShape = shape
        snappedCurrentShape = shape
        snapDragOriginDocPoint = livePoints.last?.location ?? .zero
        haptic.impactOccurred()
        renderSnappedLiveShape()
    }

    private func snappedStroke(for shape: RecognizedShape) -> InkStroke {
        makeGeometricStroke(shape.primitive)
    }

    private func renderSnappedLiveShape() {
        guard let shape = snappedCurrentShape else { return }
        let stroke = snappedStroke(for: shape)
        setLivePath(stroke.outlinePath(transform: viewTransform(), finished: true))
    }

    private func commitSnappedShape(_ shape: RecognizedShape) {
        let stroke = snappedStroke(for: shape)
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        commitPreparedStroke(stroke)
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

    private func documentPoint(_ touch: UITouch) -> CGPoint {
        bridge.documentPoint(fromView: touch.preciseLocation(in: webView))
    }

    private func inkPoint(from touch: UITouch) -> InkPoint {
        let p = documentPoint(touch)
        let isStylus = touch.type == .pencil
        return InkPoint(x: Float(p.x), y: Float(p.y), force: forceValue(touch),
                        azimuth: isStylus ? Float(touch.azimuthAngle(in: webView)) : 0,
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

    private func viewTransform() -> CGAffineTransform {
        bridge.documentToView.concatenating(CGAffineTransform(translationX: webView.frame.minX, y: webView.frame.minY))
    }

    private func updateLiveStroke(predicted: [UITouch]) {
        guard !livePoints.isEmpty else { return }
        let stroke = makeStroke(points: livePoints + predicted.map { inkPoint(from: $0) })
        setLivePath(stroke.outlinePath(transform: viewTransform(), finished: false))
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
        guard !livePoints.isEmpty else {
            setLivePath(nil)
            return
        }
        let stroke = makeStroke(points: livePoints)
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        commitPreparedStroke(stroke)
    }

    private func commitPreparedStroke(_ stroke: InkStroke, selectAfterCommit: Bool = false) {
        let transform = viewTransform()
        let finalViewPath = stroke.outlinePath(transform: transform, finished: true)
        let pending = CAShapeLayer()
        pending.frame = pendingContainer.bounds
        pending.fillRule = .nonZero
        pending.path = finalViewPath
        pending.fillColor = liveLayer.fillColor
        pending.opacity = liveLayer.opacity
        pending.compositingFilter = liveLayer.compositingFilter
        pending.strokeColor = liveLayer.strokeColor
        pending.lineWidth = liveLayer.lineWidth
        pending.lineDashPattern = liveLayer.lineDashPattern
        pendingContainer.addSublayer(pending)

        var pendingFill: CAShapeLayer?
        if let fillColor = stroke.fillColor, let fillPath = stroke.fillPath(transform: transform) {
            let fl = CAShapeLayer()
            fl.frame = pendingFillContainer.bounds
            fl.fillRule = .nonZero
            fl.opacity = 0.18
            fl.fillColor = fillColor.cgColor
            fl.path = fillPath
            pendingFillContainer.addSublayer(fl)
            pendingFill = fl
        }

        let item = PendingItem(id: stroke.id, layer: pending, fillLayer: pendingFill, isHighlighter: stroke.isHighlighter)
        pendingItems.append(item)
        setLivePath(nil)

        let box = stroke.outlinePath().boundingBox
        let center: CGPoint
        if box.isNull || !box.midX.isFinite || !box.midY.isFinite {
            center = stroke.points.first?.location ?? stroke.baked?.first?.point ?? .zero
        } else {
            center = CGPoint(x: box.midX, y: box.midY)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let pick = await self.bridge.pickAnchor(at: center)
            var anchored = stroke.translated(by: CGPoint(x: -(pick?.origin.x ?? 0), y: -(pick?.origin.y ?? 0)))
            anchored.anchor = pick?.anchor ?? .body
            self.session.addStroke(anchored, page: Self.page)
            if selectAfterCommit {
                self.selectStroke(anchored.id, fallbackOrigin: pick?.origin ?? .zero)
            }
            // Safety cleanup if the page reloaded before sync completed.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.removePendingItems(matching: [stroke.id])
        }
    }

    // MARK: Laser Pointer

    private func laserBegan(_ touch: UITouch) {
        stopLaserLoop()
        laserEngine.begin(at: documentPoint(touch), color: liveTool.laserColor, now: CACurrentMediaTime())
        updateLaserRender()
    }

    private func laserMoved(_ touch: UITouch, event: UIEvent?) {
        let now = CACurrentMediaTime()
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            laserEngine.move(to: documentPoint(sample), now: now)
        }
        updateLaserRender()
    }

    private func laserEnded(_ touch: UITouch) {
        laserEngine.end(now: CACurrentMediaTime())
        startLaserLoop()
        updateLaserRender()
    }

    private func startLaserLoop() {
        guard laserDisplayLink == nil else { return }
        let proxy = LaserDisplayLinkProxy { [weak self] in
            self?.updateLaserRender()
        }
        let link = CADisplayLink(target: proxy, selector: #selector(LaserDisplayLinkProxy.tick))
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
        let frame = laserEngine.frame(at: CACurrentMediaTime(), transform: viewTransform())
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
        let original = session.strokes(onPage: Self.page)
        eraseOriginal = original
        eraseWorking = original
        eraseOrigins = bridge.placements.compactMapValues { $0.visible ? $0.origin : nil }
        let p = documentPoint(touch)
        lastErasePoint = p
        if applyEraseStep(from: p, to: p) {
            bridge.sync(eraseWorking)
        }
        setEraserCursor(p)
    }

    private func eraseMoved(_ touch: UITouch, event: UIEvent?) {
        guard eraseOriginal != nil else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        let minStepSq: CGFloat = liveTool.eraserMode == .pixel ? 1.44 : 0.25
        var anyChanged = false
        for (idx, sample) in samples.enumerated() {
            let p = documentPoint(sample)
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
            bridge.sync(eraseWorking)
            PresentationCenter.shared.markContentActive()
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
            session.replaceStrokes(onPage: Self.page, before: original, after: eraseWorking)
        } else {
            pushStrokes()
        }
        PresentationCenter.shared.requestFrameRefresh()
        session.didFinishEraseStroke()
    }

    private func applyEraseStep(from a: CGPoint, to b: CGPoint) -> Bool {
        let result = LiveEraser.erase(eraseWorking, origins: eraseOrigins, from: a, to: b, radius: eraserRadius,
                                      mode: liveTool.eraserMode, highlighterOnly: false,
                                      cache: geometryCache)
        guard result.changed else { return false }
        eraseWorking = result.strokes
        eraseOrigins.merge(result.newOrigins) { _, new in new }
        return true
    }

    private func setEraserCursor(_ documentPoint: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let documentPoint {
            let transform = viewTransform()
            let center = documentPoint.applying(transform)
            let r = eraserRadius * transform.a
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

        // When the sticky note is actively receiving live input (or open full-screen), project its live ink.
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

        var pendingOverlays: [PendingOverlayStroke] = pendingItems.compactMap { item in
            guard let path = item.layer.path else { return nil }
            return PendingOverlayStroke(path: path, color: item.layer.fillColor,
                                        opacity: item.layer.opacity, isHighlighter: item.isHighlighter,
                                        fillPath: item.fillLayer?.path, fillColor: item.fillLayer?.fillColor)
        }
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

        if let heightConstraint = webViewHeightConstraint,
           abs(heightConstraint.constant - viewport.extraBottomInset) > 0.5 {
            heightConstraint.constant = viewport.extraBottomInset
            webView.scrollView.contentInset.bottom = viewport.extraBottomInset
            webView.scrollView.verticalScrollIndicatorInsets.bottom = viewport.extraBottomInset
            view.setNeedsLayout()
        }
        if originChanged {
            pushPresentationOverlay()
            center.requestFrameRefresh()
        }
    }
}

extension WebEditorViewController: PresentationContentSource {
    var presentationView: UIView { view }
    var prefersContinuousProjectionRefresh: Bool { true }

    func presentationViewportDidChange() {
        updatePresentationViewport(focusY: nil)
    }

    func capturePresentationFrame(completion: @escaping (UIImage?, CGSize) -> Void) {
        updatePresentationViewport(focusY: nil)
        let target = presentationViewport.captureRect
        let captureRect: CGRect
        if target.width > 0, target.height > 0 {
            captureRect = target
        } else {
            captureRect = view.bounds
        }
        guard captureRect.width > 0, captureRect.height > 0 else {
            completion(nil, .zero)
            return
        }

        // 1. Full-screen math whiteboard: pure Retina vector render, zero iPad UI chrome.
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

        // 2. Floating sticky-note mode: live HTML page underneath + clean rounded sticky-note card at exact position.
        if session.isScratchpadOpen && session.scratchpadSplitMode == .floating {
            let canvasFrame = stickyCanvasFrameInView()
            let cardRect = canvasFrame.offsetBy(dx: 0, dy: -captureRect.minY)
            let stickyImage = scratchpadPanel.canvas.renderCleanImage(size: canvasFrame.size)

            let htmlBounds = webView.bounds
            let htmlCapture = captureRect.intersection(htmlBounds)
            guard htmlCapture.width > 0, htmlCapture.height > 0 else {
                completion(stickyImage, canvasFrame.size)
                return
            }
            let config = WKSnapshotConfiguration()
            config.rect = htmlCapture
            let maxWidth = PresentationCenter.shared.preferredSnapshotMaxWidthPoints
            config.snapshotWidth = NSNumber(value: min(Double(htmlCapture.width), maxWidth))
            config.afterScreenUpdates = false
            webView.takeSnapshot(with: config) { htmlImage, _ in
                let format = UIGraphicsImageRendererFormat()
                format.scale = min(max(UIScreen.main.scale, 1), 2)
                format.opaque = true
                let renderer = UIGraphicsImageRenderer(size: captureRect.size, format: format)
                let composite = renderer.image { rendererCtx in
                    let ctx = rendererCtx.cgContext
                    UIColor.white.setFill()
                    ctx.fill(CGRect(origin: .zero, size: captureRect.size))
                    if let htmlImage {
                        htmlImage.draw(in: CGRect(origin: .zero, size: htmlCapture.size))
                    }
                    // Soft card elevation shadow + rounded sticky paper card (no iPad header or corner grips).
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
                completion(composite, captureRect.size)
            }
            return
        }

        // 3. Normal live HTML document mode.
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            completion(nil, .zero)
            return
        }
        let htmlCapture = captureRect.intersection(bounds)
        guard htmlCapture.width > 0, htmlCapture.height > 0 else {
            completion(nil, .zero)
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = htmlCapture
        let maxWidth = PresentationCenter.shared.preferredSnapshotMaxWidthPoints
        configuration.snapshotWidth = NSNumber(value: min(Double(htmlCapture.width), maxWidth))
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { image, _ in
            completion(image, htmlCapture.size)
        }
    }
}

extension WebEditorViewController: UIPencilInteractionDelegate {
    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        session.handlePencilDoubleTap(UIPencilInteraction.preferredTapAction)
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        session.handlePencilDoubleTap(UIPencilInteraction.preferredTapAction)
    }
}

private final class LaserDisplayLinkProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func tick() { handler() }
}
