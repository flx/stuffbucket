import Foundation
import CoreData

public final class LinkArchiver {
    public static let shared = LinkArchiver()
    private let session: URLSession
    private var inFlight: Set<UUID> = []
    private let inFlightQueue = DispatchQueue(label: "com.digitalhandstand.stuffbucket.linkarchiver.inflight")

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func archive(itemID: UUID, context: NSManagedObjectContext) {
        guard beginArchive(itemID) else { return }
        context.perform {
            guard let urlString = self.fetchLinkURL(itemID: itemID, context: context),
                  let url = URL(string: urlString) else {
                self.endArchive(itemID)
                return
            }
            Task {
                await self.archiveRendered(url: url, itemID: itemID, context: context)
            }
        }
    }

    public func archivePendingLinks(context: NSManagedObjectContext, limit: Int = 25) {
        context.perform {
            let request = NSFetchRequest<Item>(entityName: "Item")
            request.fetchLimit = limit
            request.predicate = NSPredicate(
                format: "type == %@ AND (htmlRelativePath == nil OR htmlRelativePath == '') AND (archiveStatus == nil OR archiveStatus == '')",
                ItemType.link.rawValue
            )
            let items = (try? context.fetch(request)) ?? []
            for item in items {
                if let itemID = item.id {
                    self.archive(itemID: itemID, context: context)
                }
            }
        }
    }

    private func fetchLinkURL(itemID: UUID, context: NSManagedObjectContext) -> String? {
        let request = NSFetchRequest<Item>(entityName: "Item")
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
        guard let item = try? context.fetch(request).first else {
            return nil
        }
        return item.linkURL
    }

    private func buildRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) StuffBucket/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        return request
    }

    private func archiveRendered(url: URL, itemID: UUID, context: NSManagedObjectContext) async {
        defer { endArchive(itemID) }
        do {
            let capture = try await RenderedPageCapture().capture(url: url)
            let outcome = try await buildArchive(from: capture, originalURL: url, itemID: itemID)
            await updateItem(itemID: itemID, outcome: outcome, context: context)
        } catch {
            await archiveFallback(url: url, itemID: itemID, context: context)
        }
    }

    private func buildArchive(from capture: RenderedPageCaptureResult, originalURL: URL, itemID: UUID) async throws -> ArchiveOutcome {
        let baseURL = capture.baseURL
        var assetMap: [URL: AssetFile] = [:]
        var queue: [AssetDescriptor] = []
        var queued: Set<URL> = []
        var processed: Set<URL> = []
        var assetFailures = 0

        func enqueue(_ url: URL, kind: AssetKind) {
            let normalized = AssetURLResolver.normalized(url)
            if assetMap[normalized] == nil {
                let fileName = AssetNamer.fileName(for: normalized, kind: kind)
                assetMap[normalized] = AssetFile(fileName: fileName)
            }
            guard !queued.contains(normalized), !processed.contains(normalized) else { return }
            queued.insert(normalized)
            queue.append(AssetDescriptor(url: normalized, kind: kind))
        }

        for raw in capture.images {
            if let url = AssetURLResolver.resolve(raw, baseURL: baseURL) {
                enqueue(url, kind: .image)
            }
        }
        for raw in capture.imageSrcsets {
            if let url = AssetURLResolver.resolve(raw, baseURL: baseURL) {
                enqueue(url, kind: .image)
            }
        }
        for raw in capture.sources {
            if let url = AssetURLResolver.resolve(raw, baseURL: baseURL) {
                enqueue(url, kind: .image)
            }
        }
        for raw in capture.stylesheets {
            if let url = AssetURLResolver.resolve(raw, baseURL: baseURL) {
                enqueue(url, kind: .stylesheet)
            }
        }
        for raw in capture.icons {
            if let url = AssetURLResolver.resolve(raw, baseURL: baseURL) {
                enqueue(url, kind: .icon)
            }
        }

        while !queue.isEmpty {
            let descriptor = queue.removeFirst()
            queued.remove(descriptor.url)
            processed.insert(descriptor.url)
            guard AssetURLResolver.shouldDownload(descriptor.url) else { continue }
            do {
                let (data, _) = try await session.data(from: descriptor.url)
                guard !data.isEmpty else {
                    assetFailures += 1
                    continue
                }
                var dataToWrite = data
                if descriptor.kind == .stylesheet {
                    let cssString = String(decoding: data, as: UTF8.self)
                    let importURLs = CSSAssetExtractor.importURLs(in: cssString, baseURL: descriptor.url)
                    for url in importURLs {
                        enqueue(url, kind: .stylesheet)
                    }
                    let assetURLs = CSSAssetExtractor.assetURLs(in: cssString, baseURL: descriptor.url)
                    for url in assetURLs {
                        enqueue(url, kind: .other)
                    }
                    let rewrittenCSS = CSSAssetRewriter.rewrite(cssString, baseURL: descriptor.url, assetMap: assetMap)
                    dataToWrite = Data(rewrittenCSS.utf8)
                }
                let fileName = assetMap[descriptor.url]?.fileName
                    ?? AssetNamer.fileName(for: descriptor.url, kind: descriptor.kind)
                _ = try LinkStorage.writeAsset(data: dataToWrite, itemID: itemID, fileName: fileName)
            } catch {
                assetFailures += 1
            }
        }

        let rewrittenHTML = HTMLAssetRewriter.rewrite(html: capture.html, baseURL: baseURL, assetMap: assetMap)
        let htmlData = Data(rewrittenHTML.utf8)
        let relativePath = try? LinkStorage.writeHTML(data: htmlData, itemID: itemID)
        let metadata = LinkMetadataParser.parse(html: rewrittenHTML, fallbackURL: originalURL)
        let archiveStatus: ArchiveStatus
        if relativePath == nil {
            archiveStatus = .failed
        } else if assetFailures > 0 {
            archiveStatus = .partial
        } else {
            archiveStatus = .full
        }
        return ArchiveOutcome(metadata: metadata, htmlRelativePath: relativePath, archiveStatus: archiveStatus)
    }

    private func archiveFallback(url: URL, itemID: UUID, context: NSManagedObjectContext) async {
        do {
            let request = buildRequest(url: url)
            let (data, _) = try await session.data(for: request)
            guard !data.isEmpty else { throw ArchiveError.emptyResponse }
            let htmlString = String(decoding: data, as: UTF8.self)
            let metadata = LinkMetadataParser.parse(html: htmlString, fallbackURL: url)
            let relativePath = try? LinkStorage.writeHTML(data: data, itemID: itemID)
            let archiveStatus: ArchiveStatus = relativePath == nil ? .failed : .partial
            let outcome = ArchiveOutcome(metadata: metadata, htmlRelativePath: relativePath, archiveStatus: archiveStatus)
            await updateItem(itemID: itemID, outcome: outcome, context: context)
        } catch {
            await markFailed(itemID: itemID, context: context)
        }
    }

    private func updateItem(itemID: UUID, outcome: ArchiveOutcome, context: NSManagedObjectContext) async {
        await performContextUpdate(in: context) {
            let request = NSFetchRequest<Item>(entityName: "Item")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            guard let item = try? context.fetch(request).first else { return }
            if let title = outcome.metadata.title {
                item.linkTitle = title
                item.title = title
            }
            item.linkAuthor = outcome.metadata.author
            item.linkPublishedDate = outcome.metadata.publishedDate
            item.htmlRelativePath = outcome.htmlRelativePath
            item.archiveStatus = outcome.archiveStatus.rawValue
            item.updatedAt = Date()
            if context.hasChanges {
                try? context.save()
            }
        }
    }

    private func markFailed(itemID: UUID, context: NSManagedObjectContext) async {
        await performContextUpdate(in: context) {
            let request = NSFetchRequest<Item>(entityName: "Item")
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", itemID as CVarArg)
            guard let item = try? context.fetch(request).first else { return }
            item.archiveStatus = ArchiveStatus.failed.rawValue
            item.updatedAt = Date()
            if context.hasChanges {
                try? context.save()
            }
        }
    }

    private func performContextUpdate(in context: NSManagedObjectContext, updates: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in
            context.perform {
                updates()
                continuation.resume()
            }
        }
    }

    private func beginArchive(_ itemID: UUID) -> Bool {
        inFlightQueue.sync {
            if inFlight.contains(itemID) {
                return false
            }
            inFlight.insert(itemID)
            return true
        }
    }

    private func endArchive(_ itemID: UUID) {
        inFlightQueue.sync {
            _ = inFlight.remove(itemID)
        }
    }
}

private struct ArchiveOutcome {
    let metadata: LinkMetadata
    let htmlRelativePath: String?
    let archiveStatus: ArchiveStatus
}

private enum ArchiveError: Error {
    case emptyResponse
}
