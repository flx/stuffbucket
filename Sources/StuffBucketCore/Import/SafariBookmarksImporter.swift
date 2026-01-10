import Foundation

public enum SafariBookmarksImporterError: Error {
    case invalidFormat
}

public struct SafariBookmark: Hashable, Codable {
    public let title: String
    public let url: URL
    public let folderPath: String
    public let externalID: String?

    public init(title: String, url: URL, folderPath: String, externalID: String?) {
        self.title = title
        self.url = url
        self.folderPath = folderPath
        self.externalID = externalID
    }
}

public final class SafariBookmarksImporter {
    public init() {}

    #if os(macOS)
    public func importBookmarks(from url: URL) throws -> [SafariBookmark] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = plist as? [String: Any] else {
            throw SafariBookmarksImporterError.invalidFormat
        }

        var results: [SafariBookmark] = []
        walk(node: root, path: [], results: &results)
        return results
    }

    private func walk(node: [String: Any], path: [String], results: inout [SafariBookmark]) {
        let title = (node["Title"] as? String) ?? (node["URIDictionary"] as? [String: Any])?["title"] as? String
        let bookmarkUUID = node["WebBookmarkUUID"] as? String ?? node["UUID"] as? String

        if let urlString = node["URLString"] as? String,
           let url = URL(string: urlString) {
            let folderPath = path.joined(separator: "/")
            let resolvedTitle = title ?? url.host ?? url.absoluteString
            results.append(SafariBookmark(title: resolvedTitle, url: url, folderPath: folderPath, externalID: bookmarkUUID))
        }

        if let children = node["Children"] as? [[String: Any]] {
            let nextPath = title.map { path + [$0] } ?? path
            for child in children {
                walk(node: child, path: nextPath, results: &results)
            }
        }
    }
    #else
    public func importBookmarks(from url: URL) throws -> [SafariBookmark] {
        throw SafariBookmarksImporterError.invalidFormat
    }
    #endif
}
