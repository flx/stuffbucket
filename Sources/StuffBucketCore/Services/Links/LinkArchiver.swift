import Foundation
import CoreData

public final class LinkArchiver {
    public static let shared = LinkArchiver()
    private let session: URLSession
    private var inFlight: Set<UUID> = []
    private let inFlightLock = NSLock()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func archive(itemID: UUID, context: NSManagedObjectContext) {
        // Dispatch immediately to background to avoid any main thread blocking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard self.beginArchive(itemID) else { return }
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
    }

    public func archivePendingLinks(context: NSManagedObjectContext, limit: Int = 25) {
        context.perform {
            let request = NSFetchRequest<Item>(entityName: "Item")
            request.fetchLimit = limit
            request.predicate = NSPredicate(
                format: "linkURL != nil AND linkURL != '' AND (htmlRelativePath == nil OR htmlRelativePath == '') AND (archiveStatus == nil OR archiveStatus == '')"
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
            let outcome = try await buildArchive(from: capture, originalURL: url, itemID: itemID, session: session)
            await updateItem(itemID: itemID, outcome: outcome, context: context)
        } catch {
            await archiveFallback(url: url, itemID: itemID, context: context)
        }
    }

    public func archiveCapturedPayload(
        _ payload: String,
        originalURL: URL,
        itemID: UUID,
        context: NSManagedObjectContext,
        cookies: [HTTPCookie] = []
    ) async -> Bool {
        guard beginArchive(itemID) else { return false }
        defer { endArchive(itemID) }
        do {
            let capture = try RenderedPageCapture.decodePayload(payload, originalURL: originalURL)
            let session = sessionForCookies(cookies, originalURL: originalURL) ?? self.session
            let outcome = try await buildArchive(from: capture, originalURL: originalURL, itemID: itemID, session: session)
            await updateItem(itemID: itemID, outcome: outcome, context: context)
            return true
        } catch {
            await markFailed(itemID: itemID, context: context)
            return false
        }
    }

    private func buildArchive(
        from capture: RenderedPageCaptureResult,
        originalURL: URL,
        itemID: UUID,
        session: URLSession
    ) async throws -> ArchiveOutcome {
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
        let readerHTML = capture.readerHTML.trimmingCharacters(in: .whitespacesAndNewlines)
        if !readerHTML.isEmpty {
            let rewrittenReader = HTMLAssetRewriter.rewrite(html: readerHTML, baseURL: baseURL, assetMap: assetMap)
            let readerData = Data(rewrittenReader.utf8)
            _ = try? LinkStorage.writeReaderHTML(data: readerData, itemID: itemID)
        }
        let metadata = LinkMetadataParser.parse(html: rewrittenHTML, fallbackURL: originalURL)
        let archiveStatus: ArchiveStatus
        if relativePath == nil {
            archiveStatus = .failed
        } else if assetFailures > 0 {
            archiveStatus = .partial
        } else {
            archiveStatus = .full
        }
        let assetFileNames = assetMap.values.map { $0.fileName }

        // Create bundle for CloudKit sync (only if archive succeeded)
        var bundleData: Data?
        if relativePath != nil {
            let archiveDir = LinkStorage.archiveDirectoryURL(for: itemID)
            bundleData = ArchiveBundle.create(from: archiveDir)
        }

        return ArchiveOutcome(metadata: metadata, htmlRelativePath: relativePath, archiveStatus: archiveStatus, assetFileNames: assetFileNames, bundleData: bundleData)
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

            // Create bundle for CloudKit sync (even for fallback)
            var bundleData: Data?
            if relativePath != nil {
                let archiveDir = LinkStorage.archiveDirectoryURL(for: itemID)
                bundleData = ArchiveBundle.create(from: archiveDir)
            }

            let outcome = ArchiveOutcome(metadata: metadata, htmlRelativePath: relativePath, archiveStatus: archiveStatus, assetFileNames: [], bundleData: bundleData)
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
            if !outcome.assetFileNames.isEmpty,
               let jsonData = try? JSONEncoder().encode(outcome.assetFileNames) {
                item.assetManifestJSON = String(data: jsonData, encoding: .utf8)
            }
            // Save bundle for CloudKit sync
            item.archiveZipData = outcome.bundleData
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

    private func sessionForCookies(_ cookies: [HTTPCookie], originalURL: URL) -> URLSession? {
        guard !cookies.isEmpty else { return nil }
        let host = originalURL.host?.lowercased()
        let filtered = cookies.filter { cookie in
            guard let host else { return true }
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            return host == domain || host.hasSuffix("." + domain)
        }
        let storage = HTTPCookieStorage()
        for cookie in filtered {
            storage.setCookie(cookie)
        }
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = storage
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }

    private func beginArchive(_ itemID: UUID) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        if inFlight.contains(itemID) {
            return false
        }
        inFlight.insert(itemID)
        return true
    }

    private func endArchive(_ itemID: UUID) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        _ = inFlight.remove(itemID)
    }
}

private struct ArchiveOutcome {
    let metadata: LinkMetadata
    let htmlRelativePath: String?
    let archiveStatus: ArchiveStatus
    let assetFileNames: [String]
    let bundleData: Data?
}

private enum ArchiveError: Error {
    case emptyResponse
}
