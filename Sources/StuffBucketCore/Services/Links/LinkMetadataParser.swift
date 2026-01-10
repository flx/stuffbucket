import Foundation

struct LinkMetadata {
    let title: String?
    let author: String?
    let publishedDate: Date?
}

enum LinkMetadataParser {
    static func parse(html: String, fallbackURL: URL) -> LinkMetadata {
        let title = extractTitle(html: html) ?? fallbackURL.host
        let author = extractMetaContent(html: html, keys: ["author", "article:author", "twitter:creator"])
        let published = extractDate(html: html)
        return LinkMetadata(title: title, author: author, publishedDate: published)
    }

    private static func extractTitle(html: String) -> String? {
        if let ogTitle = extractMetaContent(html: html, keys: ["og:title", "twitter:title"]) {
            return decodeHTML(ogTitle)
        }
        let pattern = "(?is)<title[^>]*>(.*?)</title>"
        if let match = regexMatch(html: html, pattern: pattern, group: 1) {
            return decodeHTML(match)
        }
        return nil
    }

    private static func extractDate(html: String) -> Date? {
        let candidates = [
            "article:published_time",
            "og:published_time",
            "pubdate",
            "publish-date",
            "date"
        ]
        if let dateString = extractMetaContent(html: html, keys: candidates) {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: dateString) {
                return date
            }
        }
        return nil
    }

    private static func extractMetaContent(html: String, keys: [String]) -> String? {
        for key in keys {
            let pattern = "(?is)<meta[^>]+(?:name|property)=[\"']\(NSRegularExpression.escapedPattern(for: key))[\"'][^>]*content=[\"'](.*?)[\"']"
            if let match = regexMatch(html: html, pattern: pattern, group: 1) {
                return decodeHTML(match)
            }
        }
        return nil
    }

    private static func regexMatch(html: String, pattern: String, group: Int) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range) else {
            return nil
        }
        guard let groupRange = Range(match.range(at: group), in: html) else {
            return nil
        }
        return String(html[groupRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTML(_ string: String) -> String {
        var result = string
        let replacements: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " "
        ]
        for (entity, value) in replacements {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        result = replaceNumericEntities(result, pattern: "&#(\\d+);", radix: 10)
        result = replaceNumericEntities(result, pattern: "&#x([0-9A-Fa-f]+);", radix: 16)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceNumericEntities(_ string: String, pattern: String, radix: Int) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return string
        }
        let nsString = string as NSString
        let matches = regex.matches(
            in: string,
            options: [],
            range: NSRange(location: 0, length: nsString.length)
        )
        guard !matches.isEmpty else { return string }
        var result = string
        for match in matches.reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let codeString = nsString.substring(with: match.range(at: 1))
            guard let code = UInt32(codeString, radix: radix), let scalar = UnicodeScalar(code) else {
                continue
            }
            guard let range = Range(match.range(at: 0), in: result) else { continue }
            result.replaceSubrange(range, with: String(scalar))
        }
        return result
    }
}
