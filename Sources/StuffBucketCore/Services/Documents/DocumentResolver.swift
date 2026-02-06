import Foundation
import CoreData

/// Resolves document file locations, falling back to CloudKit bundle extraction when iCloud Drive files aren't available.
public enum DocumentResolver {

    /// Result of resolving a document location
    public struct ResolvedDocument {
        /// URL to the document file (either iCloud Drive or local cache)
        public let documentURL: URL
        /// Whether the file came from the local cache (extracted from bundle)
        public let isFromCache: Bool
        /// Whether the file needs to be downloaded from iCloud
        public let needsDownload: Bool
    }

    /// Resolves the best available document location for an item.
    /// If iCloud Drive file isn't available but a bundle exists, extracts to local cache.
    /// - Parameters:
    ///   - item: The Item with document data
    ///   - forceExtract: If true, always extract from bundle even if iCloud file exists
    /// - Returns: ResolvedDocument with file location, or nil if no document available
    public static func resolve(item: Item, forceExtract: Bool = false) -> ResolvedDocument? {
        guard let itemID = item.id else { return nil }
        guard let relativePath = item.documentRelativePath, !relativePath.isEmpty else { return nil }

        let fileManager = FileManager.default
        let localURL = DocumentStorage.url(forRelativePath: relativePath)

        // In CloudKit-only mode, check for an existing local file copy first.
        let localAvailable = !forceExtract && fileManager.fileExists(atPath: localURL.path)

        if localAvailable {
            return ResolvedDocument(
                documentURL: localURL,
                isFromCache: false,
                needsDownload: false
            )
        }

        // Try to extract from bundle
        if let bundleData = item.documentZipData {
            let cacheDir = localCacheDirectoryURL(for: itemID)
            let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
            let cacheFileURL = cacheDir.appendingPathComponent(fileName)

            // Extract if not already cached
            if !fileManager.fileExists(atPath: cacheFileURL.path) {
                if !ArchiveBundle.extract(bundleData, to: cacheDir) {
                    do {
                        // New CloudKit document payload format: raw file bytes.
                        try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                        try bundleData.write(to: cacheFileURL, options: .atomic)
                    } catch {
                        return nil
                    }
                }
            }

            if fileManager.fileExists(atPath: cacheFileURL.path) {
                return ResolvedDocument(
                    documentURL: cacheFileURL,
                    isFromCache: true,
                    needsDownload: false
                )
            }
        }

        // No bundle available, return the local path (file may not exist yet on this device).
        return ResolvedDocument(
            documentURL: localURL,
            isFromCache: false,
            needsDownload: false
        )
    }

    /// No-op in CloudKit-only mode.
    public static func startDownloading(_ url: URL) {
        _ = url
    }

    /// Checks if a file is ready locally.
    public static func isFileReady(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Checks if the local document exists on this device.
    public static func isICloudDocumentFullySynced(item: Item) -> Bool {
        guard let relativePath = item.documentRelativePath, !relativePath.isEmpty else { return false }
        let localURL = DocumentStorage.url(forRelativePath: relativePath)
        return isFileReady(localURL)
    }

    /// Cleans up extracted cache files when a local primary copy exists.
    /// Bundle data is intentionally retained for CloudKit-authoritative sync.
    /// Call this from a managed object context.
    public static func cleanupBundleIfSynced(item: Item, context: NSManagedObjectContext) {
        guard isICloudDocumentFullySynced(item: item) else { return }

        // Clean up local extraction cache when primary file is present.
        if let itemID = item.id {
            let cacheDir = localCacheDirectoryURL(for: itemID)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        _ = context
    }

    // MARK: - Cache Paths

    /// Returns the local cache directory URL for an extracted document bundle.
    public static func localCacheDirectoryURL(for itemID: UUID) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches
            .appendingPathComponent("ExtractedDocuments", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
    }
}
