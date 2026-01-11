import Foundation
import WebKit

struct RenderedPageCaptureResult {
    let html: String
    let baseURL: URL
    let images: [String]
    let imageSrcsets: [String]
    let sources: [String]
    let stylesheets: [String]
    let icons: [String]
}

@MainActor
final class RenderedPageCapture: NSObject {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<RenderedPageCaptureResult, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var originalURL: URL?

    func capture(url: URL) async throws -> RenderedPageCaptureResult {
        try await withCheckedThrowingContinuation { continuation in
            self.originalURL = url
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            let webView = WKWebView(frame: .zero, configuration: configuration)
            self.webView = webView
            webView.navigationDelegate = self
            webView.load(URLRequest(url: url))
            let workItem = DispatchWorkItem { [weak self] in
                self?.finish(.failure(RenderedPageCaptureError.timedOut))
            }
            self.timeoutWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: workItem)
        }
    }

    private func finish(_ result: Result<RenderedPageCaptureResult, Error>) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }
}

extension RenderedPageCapture: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = """
        (() => {
            const imageUrls = Array.from(document.images).map(img => img.currentSrc || img.src).filter(Boolean);
            const imageSrcsetUrls = Array.from(document.images).flatMap(img => {
                if (!img.srcset) { return []; }
                return img.srcset.split(',').map(part => part.trim().split(/\\s+/)[0]).filter(Boolean);
            });
            const sourceUrls = Array.from(document.querySelectorAll('source')).flatMap(source => {
                const urls = [];
                if (source.src) { urls.push(source.src); }
                if (source.srcset) {
                    source.srcset.split(',').forEach(part => {
                        const url = part.trim().split(/\\s+/)[0];
                        if (url) { urls.push(url); }
                    });
                }
                return urls;
            });
            const stylesheetUrls = Array.from(document.querySelectorAll('link[rel~="stylesheet"]'))
                .map(link => link.href).filter(Boolean);
            const iconUrls = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel~="apple-touch-icon"]'))
                .map(link => link.href).filter(Boolean);
            const payload = {
                html: document.documentElement.outerHTML,
                baseURI: document.baseURI,
                images: imageUrls,
                imageSrcsets: imageSrcsetUrls,
                sources: sourceUrls,
                stylesheets: stylesheetUrls,
                icons: iconUrls
            };
            return JSON.stringify(payload);
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let error {
                self?.finish(.failure(error))
                return
            }
            guard let jsonString = result as? String,
                  let data = jsonString.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(RenderedPageCapturePayload.self, from: data) else {
                self?.finish(.failure(RenderedPageCaptureError.invalidPayload))
                return
            }
            let baseURL = URL(string: payload.baseURI) ?? self?.originalURL
            guard let resolvedBaseURL = baseURL else {
                self?.finish(.failure(RenderedPageCaptureError.invalidPayload))
                return
            }
            let result = RenderedPageCaptureResult(
                html: payload.html,
                baseURL: resolvedBaseURL,
                images: payload.images,
                imageSrcsets: payload.imageSrcsets,
                sources: payload.sources,
                stylesheets: payload.stylesheets,
                icons: payload.icons
            )
            self?.finish(.success(result))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
}

private struct RenderedPageCapturePayload: Decodable {
    let html: String
    let baseURI: String
    let images: [String]
    let imageSrcsets: [String]
    let sources: [String]
    let stylesheets: [String]
    let icons: [String]
}

private enum RenderedPageCaptureError: Error {
    case invalidPayload
    case timedOut
}
