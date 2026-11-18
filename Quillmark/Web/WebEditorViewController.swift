import Combine
import UIKit
import WebKit

/// Annotates a live web page. Fingers use the page normally (tap buttons, expand sections,
/// scroll, zoom); Apple Pencil writes. Strokes are anchored to page elements by `WebInkBridge`.
final class WebEditorViewController: UIViewController, InkInputDelegate, WKNavigationDelegate,
    UIScribbleInteractionDelegate {
    let session: DocumentSession
    private let library: LibraryStore
    private let bridge = WebInkBridge()
    private var webView: WKWebView { bridge.webView }

    private let inkRecognizer = InkGestureRecognizer(target: nil, action: nil)
    private let liveLayer = CAShapeLayer()
    private let eraserCursor = CAShapeLayer()
    private let geometryCache = StrokeGeometryCache()
    private var cancellables = Set<AnyCancellable>()
    private var documentURL: URL?

    static let page = 0

    // Drawing state (document coordinates, CSS px)
    private var liveTool = ToolSettings()
    private var livePoints: [InkPoint] = []
    private var liveStartTime: TimeInterval = 0
    private var pendingEstimates: [NSNumber: Int] = [:]

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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        webView.navigationDelegate = self
        webView.addInteraction(UIScribbleInteraction(delegate: self))

        liveLayer.fillRule = .nonZero
        view.layer.addSublayer(liveLayer)
        eraserCursor.fillColor = UIColor.systemGray.withAlphaComponent(0.15).cgColor
        eraserCursor.strokeColor = UIColor.systemGray.cgColor
        eraserCursor.lineWidth = 1
        eraserCursor.isHidden = true
        view.layer.addSublayer(eraserCursor)

        inkRecognizer.inkDelegate = self
        // Pencil touches must never reach the page (no accidental clicks or text selection).
        inkRecognizer.cancelsTouchesInView = true
        webView.addGestureRecognizer(inkRecognizer)

        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = self
        view.addInteraction(pencilInteraction)

        bridge.onReady = { [weak self] in
            self?.applyGestureRules()
            self?.pushStrokes()
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
        liveLayer.frame = view.bounds
        eraserCursor.frame = view.bounds
        applyGestureRules()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PresentationCenter.shared.setContentSource(view)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        PresentationCenter.shared.clearContentSource(view)
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
        bridge.sync(session.strokes(onPage: Self.page))
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

    // MARK: Gestures

    /// Pencil never drives the page. With finger drawing on, the page only scrolls/zooms with
    /// two fingers and ignores one-finger taps.
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

    // MARK: Input routing

    func inkBegan(_ touch: UITouch, event: UIEvent?) {
        liveTool = session.tool
        if liveTool.kind == .eraser {
            eraseBegan(touch)
        } else {
            drawBegan(touch, event: event)
        }
    }

    func inkMoved(_ touch: UITouch, event: UIEvent?) {
        if liveTool.kind == .eraser {
            eraseMoved(touch, event: event)
        } else {
            append(event?.coalescedTouches(for: touch) ?? [touch])
            let predicted = liveTool.prediction ? (event?.predictedTouches(for: touch) ?? []) : []
            updateLiveStroke(predicted: predicted)
        }
    }

    func inkEnded(_ touch: UITouch, event: UIEvent?) {
        if liveTool.kind == .eraser {
            eraseMoved(touch, event: event)
            eraseEnded()
        } else {
            append(event?.coalescedTouches(for: touch) ?? [touch])
            commitLiveStroke()
        }
    }

    func inkCancelled() {
        if liveTool.kind == .eraser {
            eraseOriginal = nil
            lastErasePoint = nil
            setEraserCursor(nil)
            pushStrokes()
            return
        }
        livePoints.removeAll()
        pendingEstimates.removeAll()
        setLivePath(nil)
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

    // MARK: Drawing

    private func drawBegan(_ touch: UITouch, event: UIEvent?) {
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()
        liveStartTime = touch.timestamp
        let highlighter = liveTool.kind == .highlighter
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveLayer.fillColor = (highlighter ? liveTool.highlighterColor : liveTool.color).cgColor
        liveLayer.opacity = highlighter ? PageInkView.highlighterOpacity : 1
        liveLayer.compositingFilter = highlighter ? "multiplyBlendMode" : nil
        CATransaction.commit()
        append(event?.coalescedTouches(for: touch) ?? [touch])
        updateLiveStroke(predicted: [])
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
                             width: liveTool.highlighterWidth, smoothing: 0.7, points: shaped, tool: .highlighter)
        }
        return InkStroke(id: UUID(), pen: liveTool.pen, color: liveTool.color, width: liveTool.width,
                         smoothing: liveTool.smoothing, points: points, tool: .pen)
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
    }

    private func commitLiveStroke() {
        guard !livePoints.isEmpty else {
            setLivePath(nil)
            return
        }
        let stroke = makeStroke(points: livePoints)
        livePoints.removeAll(keepingCapacity: true)
        pendingEstimates.removeAll()

        // Keep showing the stroke on a temporary layer until the page has drawn it.
        let pending = CAShapeLayer()
        pending.frame = view.bounds
        pending.path = liveLayer.path
        pending.fillColor = liveLayer.fillColor
        pending.opacity = liveLayer.opacity
        pending.compositingFilter = liveLayer.compositingFilter
        view.layer.insertSublayer(pending, below: liveLayer)
        setLivePath(nil)

        let box = stroke.outlinePath().boundingBox
        let center = CGPoint(x: box.midX, y: box.midY)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let pick = await self.bridge.pickAnchor(at: center)
            var anchored = stroke.translated(by: CGPoint(x: -(pick?.origin.x ?? 0), y: -(pick?.origin.y ?? 0)))
            anchored.anchor = pick?.anchor ?? .body
            self.session.addStroke(anchored, page: Self.page)
            try? await Task.sleep(nanoseconds: 80_000_000)
            pending.removeFromSuperlayer()
        }
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
        applyErase(from: p, to: p)
        setEraserCursor(p)
    }

    private func eraseMoved(_ touch: UITouch, event: UIEvent?) {
        guard eraseOriginal != nil else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let p = documentPoint(sample)
            applyErase(from: lastErasePoint ?? p, to: p)
            lastErasePoint = p
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

    private func applyErase(from a: CGPoint, to b: CGPoint) {
        let result = LiveEraser.erase(eraseWorking, origins: eraseOrigins, from: a, to: b, radius: eraserRadius,
                                      mode: liveTool.eraserMode, highlighterOnly: liveTool.eraseHighlighterOnly,
                                      cache: geometryCache)
        guard result.changed else { return }
        eraseWorking = result.strokes
        eraseOrigins.merge(result.newOrigins) { _, new in new }
        bridge.sync(eraseWorking)
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
