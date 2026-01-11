import CryptoKit
import Foundation

enum AssetKind {
    case stylesheet
    case image
    case icon
    case other
}

struct AssetDescriptor: Hashable {
    let url: URL
    let kind: AssetKind
}

struct AssetFile {
    let fileName: String

    var htmlPath: String {
        "assets/\(fileName)"
    }

    var cssPath: String {
        fileName
    }
}

enum AssetNamer {
    static func fileName(for url: URL, kind: AssetKind) -> String {
        let hash = hashString(url.absoluteString)
        let ext = fileExtension(for: url, kind: kind)
        guard !ext.isEmpty else { return hash }
        return "\(hash).\(ext)"
    }

    private static func fileExtension(for url: URL, kind: AssetKind) -> String {
        let pathExtension = url.pathExtension
        if !pathExtension.isEmpty {
            return pathExtension
        }
        switch kind {
        case .stylesheet:
            return "css"
        case .icon:
            return "ico"
        case .image:
            return "img"
        case .other:
            return "bin"
        }
    }

    private static func hashString(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum AssetURLResolver {
    static func resolve(_ rawValue: String, baseURL: URL) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("data:") || trimmed.hasPrefix("about:") || trimmed.hasPrefix("javascript:") {
            return nil
        }
        if trimmed.hasPrefix("#") {
            return nil
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    static func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.fragment = nil
        return components.url ?? url
    }

    static func shouldDownload(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

enum HTMLAssetRewriter {
    static func rewrite(html: String, baseURL: URL, assetMap: [URL: AssetFile]) -> String {
        var result = html
        result = rewriteAttributes(in: result, baseURL: baseURL, assetMap: assetMap)
        result = rewriteSrcset(in: result, baseURL: baseURL, assetMap: assetMap)
        return result
    }

    private static func rewriteAttributes(in html: String, baseURL: URL, assetMap: [URL: AssetFile]) -> String {
        let pattern = "\\b(src|href)=([\"'])(.*?)\\2"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return html }
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges > 3,
                  let valueRange = Range(match.range(at: 3), in: result) else { continue }
            let value = String(result[valueRange])
            guard let resolved = AssetURLResolver.resolve(value, baseURL: baseURL) else { continue }
            let normalized = AssetURLResolver.normalized(resolved)
            guard let asset = assetMap[normalized] else { continue }
            result.replaceSubrange(valueRange, with: asset.htmlPath)
        }
        return result
    }

    private static func rewriteSrcset(in html: String, baseURL: URL, assetMap: [URL: AssetFile]) -> String {
        let pattern = "\\bsrcset=([\"'])(.*?)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return html }
        var result = html
        for match in matches.reversed() {
            guard match.numberOfRanges > 2,
                  let valueRange = Range(match.range(at: 2), in: result) else { continue }
            let value = String(result[valueRange])
            let parts = value.split(separator: ",")
            let rewritten = parts.map { part -> String in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                let components = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard let urlPart = components.first else { return trimmed }
                let descriptor = components.dropFirst().joined(separator: " ")
                guard let resolved = AssetURLResolver.resolve(String(urlPart), baseURL: baseURL) else {
                    return trimmed
                }
                let normalized = AssetURLResolver.normalized(resolved)
                guard let asset = assetMap[normalized] else { return trimmed }
                if descriptor.isEmpty {
                    return asset.htmlPath
                }
                return "\(asset.htmlPath) \(descriptor)"
            }
            result.replaceSubrange(valueRange, with: rewritten.joined(separator: ", "))
        }
        return result
    }
}

enum CSSAssetExtractor {
    static func assetURLs(in css: String, baseURL: URL) -> [URL] {
        extractURLs(in: css, pattern: "url\\(\\s*(['\"]?)([^'\"\\)]+)\\1\\s*\\)", baseURL: baseURL)
    }

    static func importURLs(in css: String, baseURL: URL) -> [URL] {
        extractURLs(in: css, pattern: "@import\\s+(?:url\\(\\s*)?(['\"]?)([^'\"\\)\\s]+)\\1", baseURL: baseURL)
    }

    private static func extractURLs(in css: String, pattern: String, baseURL: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let nsString = css as NSString
        let matches = regex.matches(in: css, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return [] }
        var urls: [URL] = []
        for match in matches {
            guard match.numberOfRanges > 2 else { continue }
            let rawValue = nsString.substring(with: match.range(at: 2))
            guard let resolved = AssetURLResolver.resolve(rawValue, baseURL: baseURL) else { continue }
            urls.append(resolved)
        }
        return urls
    }
}

enum CSSAssetRewriter {
    static func rewrite(_ css: String, baseURL: URL, assetMap: [URL: AssetFile]) -> String {
        var result = css
        result = replaceURLs(in: result, pattern: "url\\(\\s*(['\"]?)([^'\"\\)]+)\\1\\s*\\)", baseURL: baseURL, assetMap: assetMap)
        result = replaceURLs(in: result, pattern: "@import\\s+(?:url\\(\\s*)?(['\"]?)([^'\"\\)\\s]+)\\1", baseURL: baseURL, assetMap: assetMap)
        return result
    }

    private static func replaceURLs(
        in css: String,
        pattern: String,
        baseURL: URL,
        assetMap: [URL: AssetFile]
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return css
        }
        let range = NSRange(css.startIndex..., in: css)
        let matches = regex.matches(in: css, options: [], range: range)
        guard !matches.isEmpty else { return css }
        var result = css
        for match in matches.reversed() {
            guard match.numberOfRanges > 2,
                  let valueRange = Range(match.range(at: 2), in: result) else { continue }
            let rawValue = String(result[valueRange])
            guard let resolved = AssetURLResolver.resolve(rawValue, baseURL: baseURL) else { continue }
            let normalized = AssetURLResolver.normalized(resolved)
            guard let asset = assetMap[normalized] else { continue }
            result.replaceSubrange(valueRange, with: asset.cssPath)
        }
        return result
    }
}
