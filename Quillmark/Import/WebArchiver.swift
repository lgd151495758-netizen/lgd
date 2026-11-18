import UIKit
import WebKit

/// Saves a web page (with its images, styles and scripts) as a `.webarchive`, so a live
/// document keeps working offline and its layout — and therefore its ink anchors — stay stable.
@MainActor
final class WebArchiver: NSObject, WKNavigationDelegate {
    struct Output {
        let archive: Data
        let title: String?
    }

    enum ArchiveError: LocalizedError {
        case loadFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .loadFailed(let reason): return "网页加载失败：\(reason)"
            case .timeout: return "网页加载超时（45 秒）"
            }
        }
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?

    static func archive(_ url: URL) async throws -> Output {
        try await WebArchiver().run(url)
    }

    private func run(_ url: URL) async throws -> Output {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 820, height: 1180))
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.alpha = 0.01
        self.webView = webView
        // WebKit only lays out (and loads lazy content) reliably inside a window.
        Self.hostView()?.insertSubview(webView, at: 0)
        defer {
            webView.navigationDelegate = nil
            webView.removeFromSuperview()
            self.webView = nil
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            webView.load(URLRequest(url: url, timeoutInterval: 30))
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                self?.finish(.failure(ArchiveError.timeout))
            }
        }
        _ = try? await webView.callAsyncJavaScript(Self.loadLazyContent, arguments: [:], in: nil, contentWorld: .page)
        try await Task.sleep(nanoseconds: 300_000_000)

        let data: Data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            webView.createWebArchiveData { result in
                continuation.resume(with: result)
            }
        }
        return Output(archive: data, title: webView.title)
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ArchiveError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(ArchiveError.loadFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(ArchiveError.loadFailed("网页进程意外退出")))
    }

    /// Turns lazy images eager and waits (max 5 s) for images and fonts, so they are archived.
    private static let loadLazyContent = """
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
    return true;
    """

    private static func hostView() -> UIView? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first
    }
}
