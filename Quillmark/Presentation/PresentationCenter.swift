import Combine
import UIKit

/// Presentation ("投屏") mode, like Goodnotes: while the iPad mirrors to an AirPlay receiver or
/// a cable display, the external screen shows only the document content (everything below the
/// toolbar). The toolbar stays on the iPad.
///
/// The content is mirrored with `snapshotView(afterScreenUpdates:)` on a display link, which
/// also captures the live web page (rendered by another process) and the ink being drawn.
final class PresentationCenter: ObservableObject {
    static let shared = PresentationCenter()

    @Published private(set) var isExternalDisplayConnected = false
    /// On: external screen shows only the document content. Off: it shows the whole iPad screen.
    @Published var contentOnly: Bool {
        didSet {
            defaults.set(contentOnly, forKey: Self.contentOnlyKey)
            refresh()
        }
    }

    static let framesPerSecond: Float = 30
    private static let contentOnlyKey = "presentation.contentOnly"

    private let defaults: UserDefaults
    private weak var presenter: PresentationViewController?
    private weak var contentSource: UIView?
    private var displayLink: CADisplayLink?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        contentOnly = defaults.object(forKey: Self.contentOnlyKey) as? Bool ?? true
    }

    // MARK: External display

    func attach(_ presenter: PresentationViewController) {
        self.presenter = presenter
        isExternalDisplayConnected = true
        refresh()
    }

    func detach() {
        stop()
        presenter = nil
        isExternalDisplayConnected = false
    }

    // MARK: Content source (the open editor)

    func setContentSource(_ view: UIView) {
        contentSource = view
        refresh()
    }

    func clearContentSource(_ view: UIView) {
        guard contentSource === view else { return }
        contentSource = nil
        refresh()
    }

    /// Whether the external screen currently shows document content only.
    var isShowingContentOnly: Bool {
        isExternalDisplayConnected && contentOnly && contentSource?.window != nil
    }

    // MARK: Mirroring

    private func refresh() {
        if presenter != nil {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: Self.framesPerSecond,
                                                        preferred: Self.framesPerSecond)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick() {
        guard let presenter, let source = currentSource(),
              source.bounds.width > 0, source.bounds.height > 0,
              let snapshot = source.snapshotView(afterScreenUpdates: false) else { return }
        presenter.show(snapshot, sourceSize: source.bounds.size)
    }

    /// The editor content in content-only mode, otherwise the iPad's whole window.
    private func currentSource() -> UIView? {
        if contentOnly, let content = contentSource, content.window != nil {
            return content
        }
        return Self.mainWindow()
    }

    private static func mainWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }
}

enum PresentationLayout {
    /// Largest rect with the aspect ratio of `size` centered in `bounds`.
    static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

/// Root view controller of the external screen.
final class PresentationViewController: UIViewController {
    private var current: UIView?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    func show(_ snapshot: UIView, sourceSize: CGSize) {
        let rect = PresentationLayout.aspectFit(sourceSize, in: view.bounds)
        guard rect.width > 0 else { return }
        let scale = rect.width / sourceSize.width
        snapshot.bounds = CGRect(origin: .zero, size: sourceSize)
        snapshot.center = CGPoint(x: rect.midX, y: rect.midY)
        snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
        view.addSubview(snapshot)
        current?.removeFromSuperview()
        current = snapshot
    }
}

/// Scene for the external (AirPlay / cable) display.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let presenter = PresentationViewController()
        window.rootViewController = presenter
        window.isHidden = false
        self.window = window
        PresentationCenter.shared.attach(presenter)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        PresentationCenter.shared.detach()
        window = nil
    }
}

/// Routes the external display to `ExternalDisplaySceneDelegate`; the iPad's own window stays
/// with SwiftUI.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let configuration = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
            return configuration
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}
