import Combine
import UIKit
import WebKit

/// Annotates a live web page. Fingers use the page normally (tap buttons, expand sections,
/// scroll, zoom, tap cover tapes to reveal/hide); Apple Pencil writes, highlights, places cover
/// tapes, uses the laser pointer, or erases. Strokes are anchored to page elements by `WebInkBridge`.
final class WebEditorViewController: UIViewController, InkInputDelegate, WKNavigationDelegate,
    UIScribbleInteractionDelegate, UIGestureRecognizerDelegate {
    let session: DocumentSession
    private let library: LibraryStore
    private let bridge = WebInkBridge()
    private var webView: WKWebView { bridge.webView }

    private let inkRecognizer = InkGestureRecognizer(target: nil, action: nil)
    private let pendingContainer = CALayer()
    private let liveLayer = CAShapeLayer()
    private let eraserCursor = CAShapeLayer()
    private let laserGlowLayer = CAShapeLayer()
    private let laserCoreLayer = CAShapeLayer()
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
        let isHighlighter: Bool
    }

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

        view.layer.addSublayer(pendingContainer)

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

        inkRecognizer.inkDelegate = self
        inkRecognizer.delegate = self
        // Pencil touches must never reach the page (no accidental clicks, Scribble, or text selection).
        inkRecognizer.cancelsTouchesInView = true
        view.addGestureRecognizer(inkRecognizer)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)

        bridge.onReady = { [weak self] in
            self?.applyGestureRules()
            self?.pushStrokes()
        }
        bridge.onToggleTape = { [weak self] id in
            guard let self else { return }
            self.session.toggleTape(id: id, page: Self.page)
            PresentationCenter.shared.requestFrameRefresh()
        }
        session.pageDidChange = { [weak self] _ in
            self?.pushStrokes()
        }
        session.$tool
            .map(\.fingerDrawing)
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyGestureRules() }
            }
            .store(in: &cancellables)

        loadDocument()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pendingContainer.frame = view.bounds
        liveLayer.frame = view.bounds
        eraserCursor.frame = view.bounds
        laserGlowLayer.frame = view.bounds
        laserCoreLayer.frame = view.bounds
        CATransaction.commit()
        updatePresentationViewport(focusY: nil)
        applyGestureRules()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PresentationCenter.shared.registerSceneAccessory(on: self)
        PresentationCenter.shared.setContentSource(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopLaserLoop()
        holdTimer?.cancel()
        PresentationCenter.shared.clearContentSource(self)
        PresentationCenter.shared.unregisterSceneAccessory(from: self)
        saveThumbnail()
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

    /// Pencil never drives the page or iPadOS Scribble. With finger drawing on, the page only
    /// scrolls/zooms with two fingers and ignores one-finger taps.
    private func applyGestureRules() {
        let fingerDrawing = session.tool.fingerDrawing
        inkRecognizer.allowsFingerDrawing = fingerDrawing
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        let scrollView = webView.scrollView
        for recognizer in Self.allGestureRecognizers(in: webView) where recognizer !== inkRecognizer {
            if recognizer === scrollView.panGestureRecognizer || recognizer === scrollView.pinchGestureRecognizer {
                recognizer.allowedTouchTypes = [direct, pointer]
            } else {
                recognizer.allowedTouchTypes = fingerDrawing ? [pointer] : [direct, pointer]
            }
        }
        scrollView.panGestureRecognizer.minimumNumberOfTouches = fingerDrawing ? 2 : 1
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

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === inkRecognizer else { return false }
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
        updatePresentationViewport(focusY: touch.location(in: view).y)
        switch liveTool.kind {
        case .eraser:
            eraseBegan(touch)
        case .laser:
            laserBegan(touch)
        case .pen, .highlighter, .tape:
            drawBegan(touch, event: event)
        }
    }

    func inkMoved(_ touch: UITouch, event: UIEvent?) {
        updatePresentationViewport(focusY: touch.location(in: view).y)
        switch liveTool.kind {
        case .eraser:
            eraseMoved(touch, event: event)
        case .laser:
            laserMoved(touch, event: event)
        case .pen, .highlighter, .tape:
            drawMoved(touch, event: event)
        }
    }

    func inkEnded(_ touch: UITouch, event: UIEvent?) {
        switch liveTool.kind {
        case .eraser:
            eraseMoved(touch, event: event)
            eraseEnded()
        case .laser:
            laserMoved(touch, event: event)
            laserEnded(touch)
        case .pen, .highlighter, .tape:
            drawEnded(touch, event: event)
        }
    }

    func inkCancelled() {
        holdTimer?.cancel()
        holdTimer = nil
        snappedBaseShape = nil
        snappedCurrentShape = nil
        switch liveTool.kind {
        case .eraser:
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
            pushStrokes()
        case .laser:
            laserEngine.cancel()
            updateLaserRender()
        case .pen, .highlighter, .tape:
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

    // MARK: Drawing (Pen, Highlighter, Tape & Draw-and-Hold)

    private func drawBegan(_ touch: UITouch, event: UIEvent?) {
        holdTimer?.cancel()
        holdTimer = nil
        snappedBaseShape = nil
        snappedCurrentShape = nil
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        liveStartTime = touch.timestamp

        let highlighter = liveTool.kind == .highlighter
        let tape = liveTool.kind == .tape
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if highlighter {
            liveLayer.fillColor = liveTool.highlighterColor.cgColor
            liveLayer.opacity = PageInkView.highlighterOpacity
            liveLayer.compositingFilter = "multiplyBlendMode"
            liveLayer.strokeColor = nil
            liveLayer.lineDashPattern = nil
        } else if tape {
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

        holdAnchorViewPoint = touch.location(in: view)
        append(event?.coalescedTouches(for: touch) ?? [touch])
        updateLiveStroke(predicted: [])
        scheduleHoldRecognitionIfNeeded()
    }

    private func drawMoved(_ touch: UITouch, event: UIEvent?) {
        if let baseShape = snappedBaseShape {
            let currentDoc = documentPoint(touch)
            snappedCurrentShape = baseShape.adjusted(to: currentDoc, initialAnchor: snapDragOriginDocPoint)
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
        switch liveTool.kind {
        case .pen: return liveTool.drawAndHold
        case .highlighter: return !liveTool.highlighterStraight
        default: return false
        }
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
        guard let shape = ShapeRecognizer.recognize(pts) else { return }
        // Highlighter only snaps to straight lines (clean text underlining/highlighting).
        if liveTool.kind == .highlighter {
            guard case .line = shape else { return }
        }
        snappedBaseShape = shape
        snappedCurrentShape = shape
        snapDragOriginDocPoint = livePoints.last?.location ?? .zero
        haptic.impactOccurred()
        renderSnappedLiveShape()
    }

    private func snappedStroke(for shape: RecognizedShape) -> InkStroke {
        if liveTool.kind == .highlighter {
            let samples = shape.samples(radius: CGFloat(liveTool.highlighterWidth) / 2)
            return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.highlighterColor,
                             width: liveTool.highlighterWidth, smoothing: 0, points: [],
                             tool: .highlighter, baked: samples, lineStyle: .solid)
        }
        let samples = shape.samples(radius: CGFloat(liveTool.width) / 2)
        return InkStroke(id: UUID(), pen: liveTool.pen, color: liveTool.color,
                         width: liveTool.width, smoothing: 0, points: [],
                         tool: .pen, baked: samples, lineStyle: liveTool.lineStyle)
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
        if liveTool.kind == .highlighter {
            let shaped = liveTool.highlighterStraight ? StrokeProcessor.straightened(points) : points
            return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.highlighterColor,
                             width: liveTool.highlighterWidth, smoothing: 0.7, points: shaped,
                             tool: .highlighter, lineStyle: .solid)
        }
        if liveTool.kind == .tape {
            let shaped = liveTool.tapeStraight ? StrokeProcessor.straightened(points, snapAngleDegrees: 8) : points
            return InkStroke(id: UUID(), pen: .ballpoint, color: liveTool.tapeColor,
                             width: liveTool.tapeWidth, smoothing: 0.7, points: shaped,
                             tool: .tape, lineStyle: .solid, revealed: false)
        }
        return InkStroke(id: UUID(), pen: liveTool.pen, color: liveTool.color, width: liveTool.width,
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

    private func setLivePath(_ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.path = path
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

    private func commitPreparedStroke(_ stroke: InkStroke) {
        let finalViewPath = stroke.outlinePath(transform: viewTransform(), finished: true)
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

        let item = PendingItem(id: stroke.id, layer: pending, isHighlighter: stroke.isHighlighter)
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
            // Safety cleanup if the page reloaded before sync completed.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.removePendingItems(matching: [stroke.id])
        }
    }

    // MARK: Laser Pointer

    private func laserBegan(_ touch: UITouch) {
        laserEngine.begin(at: documentPoint(touch), mode: liveTool.laserMode,
                          color: liveTool.laserColor, now: CACurrentMediaTime())
        startLaserLoop()
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
            laserCoreLayer.opacity = frame.opacity
            laserCoreLayer.path = frame.corePath
        } else {
            laserGlowLayer.path = nil
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
        var anyChanged = false
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let p = documentPoint(sample)
            if applyEraseStep(from: lastErasePoint ?? p, to: p) {
                anyChanged = true
            }
            lastErasePoint = p
        }
        if anyChanged {
            bridge.sync(eraseWorking)
        }
        setEraserCursor(lastErasePoint)
    }

    private func eraseEnded() {
        defer {
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
        }
        guard let original = eraseOriginal else { return }
        if eraseWorking != original {
            session.replaceStrokes(onPage: Self.page, before: original, after: eraseWorking)
        } else {
            pushStrokes()
        }
    }

    private func applyEraseStep(from a: CGPoint, to b: CGPoint) -> Bool {
        let result = LiveEraser.erase(eraseWorking, origins: eraseOrigins, from: a, to: b, radius: eraserRadius,
                                      mode: liveTool.eraserMode, highlighterOnly: liveTool.eraseHighlighterOnly,
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
        guard PresentationCenter.shared.isShowingContentOnly else { return }
        let captureRect = presentationViewport.captureRect.width > 0 ? presentationViewport.captureRect : view.bounds
        let pendingOverlays: [PendingOverlayStroke] = pendingItems.compactMap { item in
            guard let path = item.layer.path else { return nil }
            return PendingOverlayStroke(path: path, color: item.layer.fillColor,
                                        opacity: item.layer.opacity, isHighlighter: item.isHighlighter)
        }
        let state = LiveOverlayState(
            sourceSize: captureRect.size,
            captureOriginY: captureRect.minY,
            strokePath: liveLayer.path,
            strokeColor: liveLayer.fillColor,
            strokeOpacity: liveLayer.opacity,
            isHighlighter: liveTool.kind == .highlighter,
            pendingStrokes: pendingOverlays,
            cursorPath: eraserCursor.isHidden ? nil : eraserCursor.path,
            laserGlowPath: laserFrame.glowPath,
            laserCorePath: laserFrame.corePath,
            laserColor: laserFrame.glowColor,
            laserOpacity: laserFrame.opacity
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

    func presentationViewportDidChange() {
        updatePresentationViewport(focusY: nil)
    }

    func capturePresentationFrame(completion: @escaping (UIImage?, CGSize) -> Void) {
        updatePresentationViewport(focusY: nil)
        let bounds = webView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            completion(nil, .zero)
            return
        }
        let target = presentationViewport.captureRect
        let captureRect: CGRect
        if target.width > 0, target.height > 0 {
            captureRect = target.intersection(bounds)
        } else {
            captureRect = bounds
        }
        guard captureRect.width > 0, captureRect.height > 0 else {
            completion(nil, .zero)
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = captureRect
        let maxWidth = PresentationCenter.shared.preferredSnapshotMaxWidthPoints
        configuration.snapshotWidth = NSNumber(value: min(Double(captureRect.width), maxWidth))
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { image, _ in
            completion(image, captureRect.size)
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
