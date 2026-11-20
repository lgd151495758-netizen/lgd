import Combine
import UIKit

/// Provides frames of the active document area (strictly below the toolbar) for projection.
protocol PresentationContentSource: AnyObject {
    var presentationView: UIView { get }
    /// Captures the visible document content asynchronously on the main thread.
    func capturePresentationFrame(completion: @escaping (UIImage?, CGSize) -> Void)
}

/// Real-time vector ink state mirrored directly onto the external display at 60 fps while drawing
/// or erasing, so strokes appear immediately on the external screen without waiting for a snapshot.
struct LiveOverlayState {
    var sourceSize: CGSize = .zero
    var strokePath: CGPath?
    var strokeColor: CGColor?
    var strokeOpacity: Float = 1
    var isHighlighter: Bool = false
    var pendingPath: CGPath?
    var pendingColor: CGColor?
    var pendingOpacity: Float = 1
    var pendingIsHighlighter: Bool = false
    var cursorPath: CGPath?

    static let empty = LiveOverlayState()
}

enum PresentationFillMode: String, Codable, CaseIterable, Identifiable {
    /// Fits the entire content area inside the external display without cropping.
    case aspectFit
    /// Fills the full width of the external display (larger text on 16:9 projectors/monitors).
    case fillWidth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aspectFit: return "适应屏幕"
        case .fillWidth: return "填满宽度"
        }
    }
}

enum PresentationLayout {
    /// Target frame in `bounds` for a content view of `size`.
    static func frame(for size: CGSize, in bounds: CGRect, mode: PresentationFillMode) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        switch mode {
        case .aspectFit:
            return aspectFit(size, in: bounds)
        case .fillWidth:
            let scale = bounds.width / size.width
            let height = size.height * scale
            let y = height <= bounds.height ? bounds.midY - height / 2 : bounds.minY
            return CGRect(x: bounds.minX, y: y, width: bounds.width, height: height)
        }
    }

    /// Largest rect with the aspect ratio of `size` centered in `bounds`.
    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

/// Bridges UIKit's iPadOS 27+ `UISceneAccessory` API dynamically via Objective-C runtime so the app
/// compiles cleanly on Xcode 26 SDK while still registering external display accessories on iPadOS 27+.
enum SceneAccessoryBridge {
    private static let accessoryClassName = "UISceneAccessory"
    private static let makeWithUserInfoSelector = NSSelectorFromString("externalNonInteractiveSceneAccessoryWithConfiguration:userInfo:")
    private static let makeSelector = NSSelectorFromString("externalNonInteractiveSceneAccessoryWithConfiguration:")
    private static let registerSelector = NSSelectorFromString("registerSceneAccessory:")
    private static let unregisterSelector = NSSelectorFromString("unregisterSceneAccessory:")

    static var isSupportedByOS: Bool {
        NSClassFromString(accessoryClassName) != nil
    }

    static func registerExternalDisplay(on viewController: UIViewController) -> AnyObject? {
        guard let accessoryClass: AnyClass = NSClassFromString(accessoryClassName) else { return nil }
        guard viewController.responds(to: registerSelector) else { return nil }

        let config = UISceneConfiguration(name: "External Display", sessionRole: .windowExternalDisplayNonInteractive)
        config.delegateClass = ExternalDisplaySceneDelegate.self

        let clsObject = accessoryClass as AnyObject
        let accessory: AnyObject?
        if clsObject.responds(to: makeWithUserInfoSelector) {
            accessory = clsObject.perform(makeWithUserInfoSelector, with: config, with: nil)?.takeUnretainedValue()
        } else if clsObject.responds(to: makeSelector) {
            accessory = clsObject.perform(makeSelector, with: config)?.takeUnretainedValue()
        } else {
            return nil
        }
        guard let accessory else { return nil }
        return viewController.perform(registerSelector, with: accessory)?.takeUnretainedValue()
    }

    static func unregister(_ token: AnyObject?, from viewController: UIViewController?) {
        guard let token, let viewController, viewController.responds(to: unregisterSelector) else { return }
        _ = viewController.perform(unregisterSelector, with: token)
    }
}

/// Manages AirPlay / cable external display presentation ("投屏仅显示内容").
/// Supports:
/// 1. Standard iPadOS 16+ `UIWindowSceneSessionRoleExternalDisplayNonInteractive` scene lifecycle.
/// 2. iPadOS 27+ `UISceneAccessory` runtime registration.
/// 3. Connected-scene / `UIScreen.screens` fallback scanning when AirPlay connects before launch.
final class PresentationCenter: ObservableObject {
    static let shared = PresentationCenter()

    enum AttachmentKind: String {
        case none = "未连接"
        case sceneDelegate = "SceneDelegate"
        case connectedScene = "ConnectedScene"
        case screenFallback = "ScreenFallback"
    }

    @Published private(set) var isExternalDisplayConnected = false
    @Published private(set) var connectionSummary = "未检测到外接屏幕"

    /// On: external screen shows only the document content (below the toolbar).
    /// Off: external screen shows the entire iPad window.
    @Published var contentOnly: Bool {
        didSet {
            defaults.set(contentOnly, forKey: Self.contentOnlyKey)
            updateOverlayVisibility()
            requestFrameRefresh()
        }
    }

    @Published var fillMode: PresentationFillMode {
        didSet {
            defaults.set(fillMode.rawValue, forKey: Self.fillModeKey)
            presenter?.fillMode = fillMode
            requestFrameRefresh()
        }
    }

    static let framesPerSecond: Float = 24
    private static let contentOnlyKey = "presentation.contentOnly"
    private static let fillModeKey = "presentation.fillMode"

    private let defaults: UserDefaults
    private var externalWindow: UIWindow?
    private weak var externalScene: UIWindowScene?
    private weak var externalScreen: UIScreen?
    private weak var presenter: PresentationViewController?
    private var attachmentKind: AttachmentKind = .none

    private weak var contentSource: PresentationContentSource?
    private var lastContentImage: UIImage?
    private var lastContentSize: CGSize = .zero
    private var liveOverlay: LiveOverlayState = .empty

    private var accessoryTokens: [ObjectIdentifier: (host: WeakViewController, token: AnyObject)] = [:]
    private var displayLink: CADisplayLink?
    private var displayLinkProxy: DisplayLinkProxy?
    private var isCapturingFrame = false
    private var captureStartedAt: CFAbsoluteTime = 0
    private var observers: [NSObjectProtocol] = []
    private var isObserving = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        contentOnly = defaults.object(forKey: Self.contentOnlyKey) as? Bool ?? true
        if let raw = defaults.string(forKey: Self.fillModeKey), let saved = PresentationFillMode(rawValue: raw) {
            fillMode = saved
        } else {
            fillMode = .aspectFit
        }
    }

    deinit {
        stop()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Whether the external screen currently shows document content only.
    var isShowingContentOnly: Bool {
        isExternalDisplayConnected && contentOnly && contentSource?.presentationView.window != nil
    }

    // MARK: Observation & Discovery

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIScene.willConnectNotification,
            UIScene.didDisconnectNotification,
            UIScreen.didConnectNotification,
            UIScreen.didDisconnectNotification,
            UIScreen.capturedDidChangeNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        for name in names {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scanDisplays()
            }
            observers.append(token)
        }
        scanDisplays()
    }

    func registerSceneAccessory(on viewController: UIViewController) {
        let key = ObjectIdentifier(viewController)
        guard accessoryTokens[key] == nil else { return }
        if let token = SceneAccessoryBridge.registerExternalDisplay(on: viewController) {
            accessoryTokens[key] = (WeakViewController(viewController), token)
            updateSummary()
        }
    }

    func unregisterSceneAccessory(from viewController: UIViewController) {
        let key = ObjectIdentifier(viewController)
        guard let entry = accessoryTokens.removeValue(forKey: key) else { return }
        SceneAccessoryBridge.unregister(entry.token, from: entry.host.value ?? viewController)
        updateSummary()
    }

    /// Scans connected `UIWindowScene`s and `UIScreen`s to attach or detach automatically.
    func scanDisplays() {
        let connectedScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let externalWindowScene = connectedScenes.first { scene in
            scene.session.role == .windowExternalDisplayNonInteractive || scene.screen !== UIScreen.main
        }

        if let externalWindowScene {
            if externalScene !== externalWindowScene {
                attach(windowScene: externalWindowScene, kind: .connectedScene)
            }
            updateSummary()
            return
        }

        if let secondaryScreen = UIScreen.screens.first(where: { $0 !== UIScreen.main }) {
            if externalScreen !== secondaryScreen || externalWindow == nil {
                attachFallback(screen: secondaryScreen)
            }
            updateSummary()
            return
        }

        if externalWindow != nil || isExternalDisplayConnected {
            detach()
        } else {
            updateSummary()
        }
    }

    // MARK: External Display Lifecycle

    @discardableResult
    func attach(windowScene: UIWindowScene, kind: AttachmentKind) -> UIWindow {
        if let existing = externalWindow, externalScene === windowScene {
            return existing
        }
        detach()
        let presenter = PresentationViewController()
        presenter.fillMode = fillMode
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        self.externalWindow = window
        self.externalScene = windowScene
        self.externalScreen = windowScene.screen
        self.presenter = presenter
        self.attachmentKind = kind
        isExternalDisplayConnected = true
        updateSummary()
        updateOverlayVisibility()
        start()
        requestFrameRefresh()
        return window
    }

    private func attachFallback(screen: UIScreen) {
        detach()
        let presenter = PresentationViewController()
        presenter.fillMode = fillMode
        let window = UIWindow(frame: screen.bounds)
        let setScreenSelector = NSSelectorFromString("setScreen:")
        if window.responds(to: setScreenSelector) {
            window.perform(setScreenSelector, with: screen)
        }
        window.rootViewController = presenter
        window.isHidden = false
        self.externalWindow = window
        self.externalScene = nil
        self.externalScreen = screen
        self.presenter = presenter
        self.attachmentKind = .screenFallback
        isExternalDisplayConnected = true
        updateSummary()
        updateOverlayVisibility()
        start()
        requestFrameRefresh()
    }

    func detach(scene: UIWindowScene? = nil) {
        if let scene, externalScene != nil, externalScene !== scene {
            return
        }
        stop()
        externalWindow?.isHidden = true
        externalWindow = nil
        externalScene = nil
        externalScreen = nil
        presenter = nil
        attachmentKind = .none
        isCapturingFrame = false
        isExternalDisplayConnected = false
        updateSummary()
    }

    // MARK: Content Source & Live Ink

    func setContentSource(_ source: PresentationContentSource) {
        contentSource = source
        lastContentImage = nil
        lastContentSize = .zero
        updateOverlayVisibility()
        scanDisplays()
        requestFrameRefresh()
    }

    func clearContentSource(_ source: PresentationContentSource) {
        guard contentSource === source else { return }
        contentSource = nil
        lastContentImage = nil
        lastContentSize = .zero
        liveOverlay = .empty
        presenter?.updateLiveOverlay(.empty)
        requestFrameRefresh()
    }

    func updateLiveOverlay(_ state: LiveOverlayState) {
        liveOverlay = state
        guard isShowingContentOnly else { return }
        presenter?.updateLiveOverlay(state)
    }

    func requestFrameRefresh() {
        guard presenter != nil else { return }
        captureNextFrame()
    }

    private func updateOverlayVisibility() {
        presenter?.updateLiveOverlay(isShowingContentOnly ? liveOverlay : .empty)
    }

    private func updateSummary() {
        let screens = UIScreen.screens
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let captured = UIScreen.main.isCaptured
        let accessoryNote: String
        if SceneAccessoryBridge.isSupportedByOS {
            accessoryNote = accessoryTokens.isEmpty ? " · Accessory:未注册" : " · Accessory:已注册"
        } else {
            accessoryNote = ""
        }

        if isExternalDisplayConnected, let screen = externalScreen {
            let w = Int(screen.bounds.width * screen.scale)
            let h = Int(screen.bounds.height * screen.scale)
            connectionSummary = "已连接外接屏 \(w)×\(h)（\(attachmentKind.rawValue)\(accessoryNote)）"
        } else {
            let mirrorText = captured ? "镜像中" : "未镜像"
            connectionSummary = "未检测到独立外接屏（屏幕 \(screens.count) · 场景 \(scenes.count) · \(mirrorText)\(accessoryNote)）"
        }
    }

    // MARK: Frame Loop

    private func start() {
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] in
            self?.captureNextFrame()
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: Self.framesPerSecond,
                                                        preferred: Self.framesPerSecond)
        link.add(to: .main, forMode: .common)
        displayLinkProxy = proxy
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkProxy = nil
    }

    private func captureNextFrame() {
        guard let presenter else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if isCapturingFrame {
            // Guard against a dropped async snapshot callback during reload.
            if now - captureStartedAt < 2.0 { return }
            isCapturingFrame = false
        }

        if contentOnly, let source = contentSource, source.presentationView.window != nil {
            isCapturingFrame = true
            captureStartedAt = now
            source.capturePresentationFrame { [weak self] image, size in
                guard let self else { return }
                self.isCapturingFrame = false
                guard let image, size.width > 0, size.height > 0 else { return }
                self.lastContentImage = image
                self.lastContentSize = size
                guard self.isShowingContentOnly else { return }
                self.presenter?.show(image: image, sourceSize: size)
            }
            return
        }

        // Full-mirror fallback (when contentOnly is off or back in the Library).
        guard let mainWindow = Self.mainWindow(),
              mainWindow.bounds.width > 0, mainWindow.bounds.height > 0 else { return }
        if let source = contentSource, source.presentationView.window === mainWindow {
            isCapturingFrame = true
            captureStartedAt = now
            let contentFrame = source.presentationView.convert(source.presentationView.bounds, to: mainWindow)
            source.capturePresentationFrame { [weak self] contentImage, _ in
                guard let self else { return }
                self.isCapturingFrame = false
                let composite = Self.renderWindow(mainWindow, replacing: contentFrame, with: contentImage)
                self.presenter?.show(image: composite, sourceSize: mainWindow.bounds.size)
            }
        } else {
            let image = Self.renderWindow(mainWindow, replacing: .zero, with: nil)
            presenter.show(image: image, sourceSize: mainWindow.bounds.size)
        }
    }

    private static func renderWindow(_ window: UIWindow, replacing rect: CGRect, with contentImage: UIImage?) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(window.screen.scale, 1.5)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: window.bounds.size, format: format)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            if let contentImage, rect.width > 0, rect.height > 0 {
                contentImage.draw(in: rect)
            }
        }
    }

    private static func mainWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

private final class WeakViewController {
    weak var value: UIViewController?
    init(_ value: UIViewController) { self.value = value }
}

private final class DisplayLinkProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func tick() { handler() }
}

/// Root view controller of the external display window.
final class PresentationViewController: UIViewController {
    var fillMode: PresentationFillMode = .aspectFit {
        didSet { updateContentGeometry() }
    }

    private let imageView = UIImageView()
    private let overlayContainer = CALayer()
    private let pendingLayer = CAShapeLayer()
    private let liveStrokeLayer = CAShapeLayer()
    private let eraserCursorLayer = CAShapeLayer()

    private var sourceSize: CGSize = .zero
    private var lastOverlay: LiveOverlayState = .empty

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        imageView.contentMode = .scaleToFill
        imageView.backgroundColor = .white
        imageView.isHidden = true
        view.addSubview(imageView)

        overlayContainer.masksToBounds = true
        view.layer.addSublayer(overlayContainer)

        pendingLayer.fillRule = .nonZero
        liveStrokeLayer.fillRule = .nonZero
        eraserCursorLayer.fillColor = UIColor.systemGray.withAlphaComponent(0.18).cgColor
        eraserCursorLayer.strokeColor = UIColor.systemGray.cgColor
        eraserCursorLayer.lineWidth = 1.5

        overlayContainer.addSublayer(pendingLayer)
        overlayContainer.addSublayer(liveStrokeLayer)
        overlayContainer.addSublayer(eraserCursorLayer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateContentGeometry()
    }

    func show(image: UIImage, sourceSize: CGSize) {
        self.sourceSize = sourceSize
        imageView.image = image
        imageView.isHidden = false
        updateContentGeometry()
    }

    func updateLiveOverlay(_ state: LiveOverlayState) {
        lastOverlay = state
        applyOverlay()
    }

    private func updateContentGeometry() {
        let target = PresentationLayout.frame(for: sourceSize, in: view.bounds, mode: fillMode)
        guard target.width > 0, target.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = target
        overlayContainer.frame = target
        pendingLayer.frame = overlayContainer.bounds
        liveStrokeLayer.frame = overlayContainer.bounds
        eraserCursorLayer.frame = overlayContainer.bounds
        CATransaction.commit()
        applyOverlay()
    }

    private func applyOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let refSize = lastOverlay.sourceSize.width > 0 ? lastOverlay.sourceSize : sourceSize
        guard refSize.width > 0, overlayContainer.bounds.width > 0 else {
            liveStrokeLayer.path = nil
            pendingLayer.path = nil
            eraserCursorLayer.path = nil
            CATransaction.commit()
            return
        }
        let scale = overlayContainer.bounds.width / refSize.width
        var transform = CGAffineTransform(scaleX: scale, y: scale)

        applyShape(layer: pendingLayer, path: lastOverlay.pendingPath, color: lastOverlay.pendingColor,
                   opacity: lastOverlay.pendingOpacity, isHighlighter: lastOverlay.pendingIsHighlighter,
                   transform: &transform)
        applyShape(layer: liveStrokeLayer, path: lastOverlay.strokePath, color: lastOverlay.strokeColor,
                   opacity: lastOverlay.strokeOpacity, isHighlighter: lastOverlay.isHighlighter,
                   transform: &transform)
        if let cursorPath = lastOverlay.cursorPath {
            eraserCursorLayer.path = cursorPath.copy(using: &transform)
            eraserCursorLayer.isHidden = false
        } else {
            eraserCursorLayer.path = nil
            eraserCursorLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private func applyShape(layer: CAShapeLayer, path: CGPath?, color: CGColor?, opacity: Float,
                            isHighlighter: Bool, transform: inout CGAffineTransform) {
        guard let path else {
            layer.path = nil
            return
        }
        layer.fillColor = color
        layer.opacity = opacity
        layer.compositingFilter = isHighlighter ? "multiplyBlendMode" : nil
        layer.path = path.copy(using: &transform)
    }
}

/// Scene delegate declared in `Info.plist` for `UIWindowSceneSessionRoleExternalDisplayNonInteractive`.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        window = PresentationCenter.shared.attach(windowScene: windowScene, kind: .sceneDelegate)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        PresentationCenter.shared.detach(scene: scene as? UIWindowScene)
        window = nil
    }
}
