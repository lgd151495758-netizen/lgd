import UIKit
import WebKit

/// Owns the WKWebView of a live document and talks to the injected ink runtime (`qm-runtime.js`).
final class WebInkBridge: NSObject, WKScriptMessageHandler {
    struct Placement: Equatable {
        /// Document position (CSS px) of the stroke's anchor element.
        var origin: CGPoint
        var visible: Bool
    }

    struct AnchorPick: Equatable {
        var anchor: WebAnchor
        /// Document position (CSS px) of the anchor element's top-left corner.
        var origin: CGPoint
    }

    let webView: WKWebView
    private(set) var isReady = false
    private(set) var placements: [UUID: Placement] = [:]
    var onReady: (() -> Void)?
    var onPlacementsChanged: (() -> Void)?

    /// What the page currently shows, to send only differences.
    private var rendered: [UUID: InkStroke] = [:]
    private var renderedOrder: [UUID] = []

    static let runtimeSource: String = {
        guard let url = Bundle.main.url(forResource: "qm-runtime", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("qm-runtime.js missing from the app bundle")
            return ""
        }
        return source
    }()

    /// The page always lays out at the iPad's width (requested by the user), whatever it declares.
    static let viewportSource = """
    (function () {
      var meta = document.querySelector('meta[name="viewport"]');
      if (!meta) {
        meta = document.createElement('meta');
        meta.name = 'viewport';
        (document.head || document.documentElement).appendChild(meta);
      }
      meta.setAttribute('content', 'width=device-width, initial-scale=1');
    })();
    """

    init(frame: CGRect = .zero) {
        let configuration = WKWebViewConfiguration()
        configuration.ignoresViewportScaleLimits = true
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = true
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.overrideUserInterfaceStyle = .light
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        super.init()
        controller.add(WeakScriptMessageHandler(self), name: "qm")
        controller.addUserScript(WKUserScript(source: Self.viewportSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: Self.runtimeSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "qm")
    }

    /// Call before loading a new page.
    func resetForNavigation() {
        isReady = false
        rendered.removeAll()
        renderedOrder.removeAll()
        placements.removeAll()
    }

    // MARK: Coordinates

    /// WKWebView point → document CSS px.
    func documentPoint(fromView point: CGPoint) -> CGPoint {
        let scrollView = webView.scrollView
        let zoom = max(scrollView.zoomScale, 0.0001)
        return CGPoint(x: (point.x + scrollView.contentOffset.x) / zoom,
                       y: (point.y + scrollView.contentOffset.y) / zoom)
    }

    /// Document CSS px → WKWebView coordinates.
    var documentToView: CGAffineTransform {
        let scrollView = webView.scrollView
        let zoom = scrollView.zoomScale
        return CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom,
                                 tx: -scrollView.contentOffset.x, ty: -scrollView.contentOffset.y)
    }

    // MARK: Runtime calls

    func pickAnchor(at documentPoint: CGPoint) async -> AnchorPick? {
        guard isReady else { return nil }
        let script = "return window.__qm ? window.__qm.pickAnchor(x, y) : null;"
        guard let value = try? await webView.callAsyncJavaScript(script,
                                                                 arguments: ["x": Double(documentPoint.x), "y": Double(documentPoint.y)],
                                                                 in: nil, contentWorld: .page),
              let dictionary = value as? [String: Any],
              let selector = dictionary["selector"] as? String else {
            return nil
        }
        let anchor = WebAnchor(selector: selector,
                               fingerprint: dictionary["fingerprint"] as? String ?? "",
                               tag: dictionary["tag"] as? String ?? "")
        let x = (dictionary["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (dictionary["y"] as? NSNumber)?.doubleValue ?? 0
        return AnchorPick(anchor: anchor, origin: CGPoint(x: x, y: y))
    }

    /// Makes the page show exactly `strokes` (in this z-order).
    func sync(_ strokes: [InkStroke]) {
        guard isReady else { return }
        var add: [[String: Any]] = []
        var seen = Set<UUID>()
        for stroke in strokes {
            seen.insert(stroke.id)
            if rendered[stroke.id] != stroke {
                add.append(Self.payload(for: stroke))
                rendered[stroke.id] = stroke
            }
        }
        let remove = rendered.keys.filter { !seen.contains($0) }
        for id in remove {
            rendered[id] = nil
            placements[id] = nil
        }
        let order = strokes.map(\.id)
        let orderChanged = order != renderedOrder
        renderedOrder = order
        guard !add.isEmpty || !remove.isEmpty || orderChanged else { return }

        var ops: [String: Any] = ["add": add, "remove": remove.map(\.uuidString)]
        if orderChanged {
            ops["order"] = order.map(\.uuidString)
        }
        webView.callAsyncJavaScript("return window.__qm ? window.__qm.apply(ops) : -1;", arguments: ["ops": ops],
                                    in: nil, in: .page) { _ in }
    }

    static func payload(for stroke: InkStroke) -> [String: Any] {
        let anchor = stroke.anchor ?? .body
        return [
            "id": stroke.id.uuidString,
            "d": SVGPath.string(from: stroke.outlinePath()),
            "color": stroke.color.cssString,
            "hl": stroke.isHighlighter,
            "anchor": ["selector": anchor.selector, "fingerprint": anchor.fingerprint, "tag": anchor.tag],
        ]
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            isReady = true
            rendered.removeAll()
            renderedOrder.removeAll()
            placements.removeAll()
            onReady?()
        case "layout":
            guard let strokes = body["strokes"] as? [String: Any] else { return }
            var updated: [UUID: Placement] = [:]
            for (key, value) in strokes {
                guard let id = UUID(uuidString: key), let numbers = value as? [NSNumber], numbers.count >= 3 else { continue }
                updated[id] = Placement(origin: CGPoint(x: numbers[0].doubleValue, y: numbers[1].doubleValue),
                                        visible: numbers[2].intValue != 0)
            }
            placements = updated
            onPlacementsChanged?()
        default:
            break
        }
    }
}

/// Breaks the retain cycle WKUserContentController → handler → web view.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
