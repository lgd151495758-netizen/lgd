import PDFKit
import UIKit
import WebKit

/// Renders HTML into PDF with an off-screen WKWebView.
/// - `.pagedA4`: print layout (reflowed into A4 pages, selectable text kept).
/// - `.longPage`: one tall page that keeps the on-screen look of the site.
@MainActor
final class HTMLPDFConverter: NSObject, WKNavigationDelegate {
    enum Load {
        case file(URL, readAccess: URL)
        case web(URL)
        case html(String, baseURL: URL?)
    }

    struct Output {
        let pdfData: Data
        let title: String?
        let html: String?
    }

    enum ConvertError: LocalizedError {
        case loadFailed(String)
        case timeout
        case empty

        var errorDescription: String? {
            switch self {
            case .loadFailed(let reason): return "网页加载失败：\(reason)"
            case .timeout: return "网页加载超时（45 秒）"
            case .empty: return "网页转换后没有内容"
            }
        }
    }

    static let a4 = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
    static let printMargin: CGFloat = 36
    static let longPageWidth: CGFloat = 820

    private var webView: WKWebView?
    private var navigationContinuation: CheckedContinuation<Void, Error>?

    static func convert(_ load: Load, layout: PageLayoutMode) async throws -> Output {
        let converter = HTMLPDFConverter()
        return try await converter.run(load, layout: layout)
    }

    private func run(_ load: Load, layout: PageLayoutMode) async throws -> Output {
        let configuration = WKWebViewConfiguration()
        let width: CGFloat = layout == .pagedA4 ? 794 : Self.longPageWidth
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1200), configuration: configuration)
        webView.navigationDelegate = self
        webView.overrideUserInterfaceStyle = .light
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        self.webView = webView
        // WebKit lays out and paints reliably only when the view is in a window.
        Self.hostView()?.insertSubview(webView, at: 0)
        defer {
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            self.webView = nil
        }

        try await startLoading(load, in: webView)
        _ = try? await webView.callAsyncJavaScript(Self.prepareScript, arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(nanoseconds: 300_000_000)

        let title = webView.title
        var html: String?
        if case .web = load {
            html = try? await webView.callAsyncJavaScript("return document.documentElement.outerHTML;",
                                                          arguments: [:], in: nil, contentWorld: .page) as? String
        }

        let data: Data
        switch layout {
        case .pagedA4:
            data = Self.paginatedPDF(from: webView)
        case .longPage:
            data = try await Self.longPDF(from: webView)
        }
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ConvertError.empty
        }
        return Output(pdfData: data, title: title, html: html)
    }

    private func startLoading(_ load: Load, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationContinuation = continuation
            switch load {
            case let .file(url, readAccess):
                webView.loadFileURL(url, allowingReadAccessTo: readAccess)
            case let .web(url):
                webView.load(URLRequest(url: url, timeoutInterval: 30))
            case let .html(string, baseURL):
                webView.loadHTMLString(string, baseURL: baseURL)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                self?.finishNavigation(.failure(ConvertError.timeout))
            }
        }
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        guard let continuation = navigationContinuation else { return }
        navigationContinuation = nil
        continuation.resume(with: result)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(ConvertError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(ConvertError.loadFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(ConvertError.loadFailed("网页进程意外退出")))
    }

    // MARK: Rendering

    /// Loads lazy images, waits for images and fonts, keeps backgrounds when printing.
    private static let prepareScript = """
    const style = document.createElement('style');
    style.textContent = '*{-webkit-print-color-adjust:exact !important;print-color-adjust:exact !important;}';
    (document.head || document.documentElement).appendChild(style);
    document.querySelectorAll('img').forEach(function (img) { img.loading = 'eager'; });
    const pending = Array.from(document.images).filter(function (img) { return !img.complete; });
    await Promise.race([
      Promise.all(pending.map(function (img) {
        return new Promise(function (resolve) {
          img.addEventListener('load', resolve, { once: true });
          img.addEventListener('error', resolve, { once: true });
        });
      })),
      new Promise(function (resolve) { setTimeout(resolve, 5000); })
    ]);
    if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
    return Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0);
    """

    private final class A4PageRenderer: UIPrintPageRenderer {
        override var paperRect: CGRect { HTMLPDFConverter.a4 }
        override var printableRect: CGRect {
            HTMLPDFConverter.a4.insetBy(dx: HTMLPDFConverter.printMargin, dy: HTMLPDFConverter.printMargin)
        }
    }

    private static func paginatedPDF(from webView: WKWebView) -> Data {
        let renderer = A4PageRenderer()
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let pageCount = renderer.numberOfPages
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, a4, nil)
        if pageCount > 0 {
            renderer.prepare(forDrawingPages: NSRange(location: 0, length: pageCount))
            let bounds = UIGraphicsGetPDFContextBounds()
            for index in 0..<pageCount {
                UIGraphicsBeginPDFPage()
                renderer.drawPage(at: index, in: bounds)
            }
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    private static func longPDF(from webView: WKWebView) async throws -> Data {
        let configuration = WKPDFConfiguration()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }
    }

    private static func hostView() -> UIView? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }
}
