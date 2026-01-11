import Foundation
import WebKit

public enum LinkArchiveScript {
    public static let capturePayload = """
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
        const pickReadableNode = () => {
            const candidates = Array.from(document.querySelectorAll('article, main, [role="main"], section, div'));
            if (candidates.length === 0) { return document.body; }
            let best = null;
            let bestScore = 0;
            for (const el of candidates) {
                const text = (el.innerText || '').trim();
                const textLength = text.length;
                if (textLength < 200) { continue; }
                const linkText = Array.from(el.querySelectorAll('a')).map(a => (a.innerText || '')).join('');
                const linkLength = linkText.length;
                const linkDensity = linkLength / Math.max(textLength, 1);
                const paragraphCount = el.querySelectorAll('p').length;
                const score = (textLength * (1 - Math.min(linkDensity, 0.9))) + (paragraphCount * 100);
                if (score > bestScore) {
                    bestScore = score;
                    best = el;
                }
            }
            return best || document.body;
        };
        const titleText = (document.querySelector('h1') && document.querySelector('h1').innerText) || document.title || '';
        const readableNode = pickReadableNode();
        const readerHTML = `<!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <base href="${document.baseURI}">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>${titleText}</title>
        <style>
          :root { color-scheme: light; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; margin: 0; padding: 0; background: #f6f4f0; color: #1b1b1b; }
          main { max-width: 720px; margin: 0 auto; padding: 32px 20px 64px; line-height: 1.65; font-size: 17px; }
          h1 { font-size: 28px; margin: 0 0 16px; }
          img { max-width: 100%; height: auto; }
          pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace; }
          blockquote { border-left: 3px solid #c7c2ba; margin: 16px 0; padding-left: 12px; color: #4a4a4a; }
        </style>
        </head>
        <body>
        <main>
          ${titleText ? '<h1>' + titleText + '</h1>' : ''}
          ${readableNode ? readableNode.innerHTML : ''}
        </main>
        </body>
        </html>`;
        const payload = {
            html: document.documentElement.outerHTML,
            readerHTML: readerHTML,
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
}

struct RenderedPageCaptureResult {
    let html: String
    let readerHTML: String
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

    nonisolated static func decodePayload(_ jsonString: String, originalURL: URL?) throws -> RenderedPageCaptureResult {
        guard let data = jsonString.data(using: .utf8) else {
            throw RenderedPageCaptureError.invalidPayload
        }
        let payload = try JSONDecoder().decode(RenderedPageCapturePayload.self, from: data)
        let baseURL = URL(string: payload.baseURI) ?? originalURL
        guard let resolvedBaseURL = baseURL else {
            throw RenderedPageCaptureError.invalidPayload
        }
        return RenderedPageCaptureResult(
            html: payload.html,
            readerHTML: payload.readerHTML,
            baseURL: resolvedBaseURL,
            images: payload.images,
            imageSrcsets: payload.imageSrcsets,
            sources: payload.sources,
            stylesheets: payload.stylesheets,
            icons: payload.icons
        )
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
        webView.evaluateJavaScript(LinkArchiveScript.capturePayload) { [weak self] result, error in
            if let error {
                self?.finish(.failure(error))
                return
            }
            guard let jsonString = result as? String else {
                self?.finish(.failure(RenderedPageCaptureError.invalidPayload))
                return
            }
            do {
                let result = try RenderedPageCapture.decodePayload(jsonString, originalURL: self?.originalURL)
                self?.finish(.success(result))
            } catch {
                self?.finish(.failure(error))
            }
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
    let readerHTML: String
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
