import CoreData
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

public enum ItemImportService {
    public static func createLinkItem(
        url: URL,
        source: ItemSource,
        tagsText: String? = nil,
        tags: [String]? = nil,
        textContent: String? = nil,
        in context: NSManagedObjectContext
    ) -> UUID? {
        let item = Item.create(in: context, type: .link)
        item.linkURL = url.absoluteString
        item.linkTitle = url.host ?? url.absoluteString
        item.title = item.linkTitle
        item.source = source.rawValue
        let resolvedTags: [String]
        if let tags {
            resolvedTags = tags
        } else {
            resolvedTags = TagParser.parse(tagsText)
        }
        if !resolvedTags.isEmpty {
            item.setTagList(resolvedTags)
        }
        if let textContent {
            let trimmed = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                item.textContent = trimmed
            }
        }
        return item.id
    }

    public static func createSnippetItem(
        text: String,
        source: ItemSource = .manual,
        in context: NSManagedObjectContext
    ) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = Item.create(in: context, type: .snippet)
        item.textContent = trimmed
        item.title = SnippetTitleBuilder.title(from: trimmed)
        item.source = source.rawValue
        return item.id
    }

    public static func importDocument(
        fileURL: URL,
        source: ItemSource = .import,
        tags: [String]? = nil,
        textContent: String? = nil,
        in context: NSManagedObjectContext
    ) throws -> UUID? {
        let fileName = fileURL.lastPathComponent
        let item = Item.create(in: context, type: .document)
        item.title = fileName.isEmpty ? "Document" : fileName
        guard let itemID = item.id else { return nil }
        let storedName = item.title ?? "Document"
        item.documentRelativePath = try DocumentStorage.copyDocument(from: fileURL, itemID: itemID, fileName: storedName)
        item.source = source.rawValue
        if let tags, !tags.isEmpty {
            item.setTagList(tags)
        }
        if let textContent {
            let trimmed = textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                item.textContent = trimmed
            }
        }
        return itemID
    }

    public static func attachDocument(
        fileURL: URL,
        to item: Item,
        in context: NSManagedObjectContext
    ) throws {
        let fileName = fileURL.lastPathComponent
        let storedName = fileName.isEmpty ? "Document" : fileName
        if let existing = item.documentRelativePath, !existing.isEmpty {
            let existingURL = DocumentStorage.url(forRelativePath: existing)
            try? FileManager.default.removeItem(at: existingURL.deletingLastPathComponent())
        }
        guard let itemID = item.id else { return }
        item.documentRelativePath = try DocumentStorage.copyDocument(from: fileURL, itemID: itemID, fileName: storedName)
        if item.title == nil || item.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            item.title = storedName
        }
        item.updatedAt = Date()
    }
}

private enum SnippetTitleBuilder {
    static func title(from text: String) -> String {
        let firstLine = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first ?? Substring(text)
        let maxLength = 80
        if firstLine.count > maxLength {
            return String(firstLine.prefix(maxLength)) + "..."
        }
        return String(firstLine)
    }
}

public struct ShareComment: Equatable {
    public let tags: [String]
    public let snippet: String?

    public init(tags: [String], snippet: String?) {
        self.tags = tags
        self.snippet = snippet
    }
}

public enum ShareCommentParser {
    public static func parse(_ text: String?) -> ShareComment {
        guard let text else { return ShareComment(tags: [], snippet: nil) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ShareComment(tags: [], snippet: nil) }

        var tagsBuffer = ""
        var snippets: [String] = []
        var currentSnippet = ""
        var activeQuote: QuoteKind?
        let characters = Array(trimmed)

        for (index, character) in characters.enumerated() {
            let prev = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil

            if let quote = activeQuote {
                switch quote {
                case .double:
                    if isDoubleQuoteClose(character) {
                        appendSnippet(from: &currentSnippet, into: &snippets)
                        activeQuote = nil
                        continue
                    }
                case .single:
                    if isSingleQuoteClose(character, prev: prev, next: next) {
                        appendSnippet(from: &currentSnippet, into: &snippets)
                        activeQuote = nil
                        continue
                    }
                }
                currentSnippet.append(character)
                continue
            }

            if isDoubleQuoteOpen(character) {
                activeQuote = .double
                continue
            }
            if isSingleQuoteOpen(character, prev: prev, next: next) {
                activeQuote = .single
                continue
            }
            tagsBuffer.append(character)
        }

        if activeQuote != nil {
            appendSnippet(from: &currentSnippet, into: &snippets)
        }

        let snippet = snippets.isEmpty ? nil : snippets.joined(separator: "\n")
        let tags = TagParser.parse(tagsBuffer)
        return ShareComment(tags: tags, snippet: snippet)
    }

    private enum QuoteKind {
        case double
        case single
    }

    private static func isDoubleQuoteOpen(_ character: Character) -> Bool {
        character == "\"" || character == "“"
    }

    private static func isDoubleQuoteClose(_ character: Character) -> Bool {
        character == "\"" || character == "”"
    }

    private static func isSingleQuoteOpen(_ character: Character, prev: Character?, next: Character?) -> Bool {
        guard character == "'" || character == "‘" else { return false }
        return !isWordCharacter(prev) && isWordCharacter(next)
    }

    private static func isSingleQuoteClose(_ character: Character, prev: Character?, next: Character?) -> Bool {
        guard character == "'" || character == "’" else { return false }
        return !isWordCharacter(next)
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    private static func appendSnippet(from buffer: inout String, into snippets: inout [String]) {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            snippets.append(trimmed)
        }
        buffer = ""
    }

    
}

private enum TagParser {
    static func parse(_ text: String?) -> [String] {
        guard let text else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let parts = trimmed.split { $0 == "," || $0.isWhitespace || $0.isNewline }
        return parts.compactMap { substring in
            var tag = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if tag.hasPrefix("#") {
                tag.removeFirst()
            }
            return tag.isEmpty ? nil : tag
        }
    }
}
