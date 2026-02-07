import Foundation

/// Resolves archive file locations, falling back to CloudKit bundle extraction when local files are unavailable.
public enum ArchiveResolver {

    /// Result of resolving an archive location
    public struct ResolvedArchive {
        /// URL to the page.html file (either local storage or local cache)
        public let pageURL: URL
        /// URL to the reader.html file (either local storage or local cache), if available
        public let readerURL: URL?
        /// URL to the assets folder
        public let assetsFolder: URL
        /// Whether the files came from the local cache (extracted from bundle)
        public let isFromCache: Bool
    }

    /// Resolves the best available archive location for an item.
    /// If local files aren't available but a bundle exists, extracts to local cache.
    /// - Parameters:
    ///   - item: The Item with archive data
    ///   - forceExtract: If true, always extract from bundle even if local files exist
    /// - Returns: ResolvedArchive with file locations, or nil if no archive available
    public static func resolve(item: Item, forceExtract: Bool = false) -> ResolvedArchive? {
        guard let itemID = item.id else { return nil }
        guard item.htmlRelativePath != nil else { return nil }

        let localPageURL = item.archivedPageURL
        let localReaderURL = item.archivedReaderURL
        let fileManager = FileManager.default

        // In CloudKit-only mode, prefer existing local archive files.
        let localAvailable = !forceExtract && localPageURL != nil && fileManager.fileExists(atPath: localPageURL!.path)

        if localAvailable, let pageURL = localPageURL {
            let archiveFolder = pageURL.deletingLastPathComponent()
            let assetsFolder = archiveFolder.appendingPathComponent("assets", isDirectory: true)
            let availableReaderURL = localReaderURL.flatMap { reader in
                fileManager.fileExists(atPath: reader.path) ? reader : nil
            }

            return ResolvedArchive(
                pageURL: pageURL,
                readerURL: availableReaderURL,
                assetsFolder: assetsFolder,
                isFromCache: false
            )
        }

        // Try to extract from bundle
        if let bundleData = item.archiveZipData {
            let cacheDir = LinkStorage.localCacheDirectoryURL(for: itemID)

            // Check if already extracted
            let cachePageURL = LinkStorage.localCachePageURL(for: itemID)
            if !fileManager.fileExists(atPath: cachePageURL.path) {
                // Extract bundle to cache
                if !ArchiveBundle.extract(bundleData, to: cacheDir) {
                    return nil
                }
            }

            let cacheReaderURL = LinkStorage.localCacheReaderURL(for: itemID)
            let readerExists = fileManager.fileExists(atPath: cacheReaderURL.path)

            return ResolvedArchive(
                pageURL: cachePageURL,
                readerURL: readerExists ? cacheReaderURL : nil,
                assetsFolder: cacheDir.appendingPathComponent("assets", isDirectory: true),
                isFromCache: true
            )
        }

        // No archive available
        return nil
    }

    /// Checks if a file exists locally.
    public static func isFileReady(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Checks if the primary local archive files exist for an item.
    public static func hasLocalArchiveCopy(item: Item) -> Bool {
        guard let pageURL = item.archivedPageURL else { return false }
        guard isFileReady(pageURL) else { return false }
        if let readerURL = item.archivedReaderURL {
            return isFileReady(readerURL)
        }
        return true
    }

    /// Cleans up local extracted cache files after the primary local archive copy exists.
    public static func cleanupCacheIfLocalCopyExists(item: Item) {
        guard hasLocalArchiveCopy(item: item) else { return }

        // Also clean up local cache if it exists
        if let itemID = item.id {
            let cacheDir = LinkStorage.localCacheDirectoryURL(for: itemID)
            try? FileManager.default.removeItem(at: cacheDir)
        }
    }
}
