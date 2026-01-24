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
        let iCloudURL = DocumentStorage.url(forRelativePath: relativePath)

        // Check if iCloud Drive file is available locally
        let iCloudAvailable = !forceExtract && fileManager.fileExists(atPath: iCloudURL.path)

        if iCloudAvailable {
            // Check if file needs downloading
            let needsDownload = !isFileReady(iCloudURL)
            return ResolvedDocument(
                documentURL: iCloudURL,
                isFromCache: false,
                needsDownload: needsDownload
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
                    return nil
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

        // No bundle available, return iCloud URL (may need download)
        return ResolvedDocument(
            documentURL: iCloudURL,
            isFromCache: false,
            needsDownload: true
        )
    }

    /// Starts downloading an iCloud document if needed
    public static func startDownloading(_ url: URL) {
        let fileManager = FileManager.default
        if fileManager.isUbiquitousItem(at: url) {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
        }
    }

    /// Checks if a file is ready (downloaded from iCloud)
    public static func isFileReady(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return false }

        if fileManager.isUbiquitousItem(at: url) {
            let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey]
            if let values = try? url.resourceValues(forKeys: keys),
               let status = values.ubiquitousItemDownloadingStatus {
                return status == .current || status == .downloaded
            }
        }
        return true
    }

    /// Checks if the iCloud Drive document is fully synced
    public static func isICloudDocumentFullySynced(item: Item) -> Bool {
        guard let relativePath = item.documentRelativePath, !relativePath.isEmpty else { return false }
        let iCloudURL = DocumentStorage.url(forRelativePath: relativePath)
        return isFileReady(iCloudURL)
    }

    /// Cleans up the bundle data from an item after iCloud Drive has fully synced.
    /// Call this from a managed object context.
    public static func cleanupBundleIfSynced(item: Item, context: NSManagedObjectContext) {
        guard item.documentZipData != nil else { return }
        guard isICloudDocumentFullySynced(item: item) else { return }

        // iCloud Drive is fully synced, remove the bundle
        item.documentZipData = nil
        item.updatedAt = Date()

        // Also clean up local cache if it exists
        if let itemID = item.id {
            let cacheDir = localCacheDirectoryURL(for: itemID)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        if context.hasChanges {
            try? context.save()
        }
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
