import Foundation
import CoreData

/// Resolves archive file locations, falling back to CloudKit bundle extraction when iCloud Drive files aren't available.
public enum ArchiveResolver {

    /// Result of resolving an archive location
    public struct ResolvedArchive {
        /// URL to the page.html file (either iCloud Drive or local cache)
        public let pageURL: URL
        /// URL to the reader.html file (either iCloud Drive or local cache), if available
        public let readerURL: URL?
        /// URL to the assets folder
        public let assetsFolder: URL
        /// Whether the files came from the local cache (extracted from bundle)
        public let isFromCache: Bool
        /// List of all files that need to be downloaded from iCloud (empty if from cache)
        public let filesToDownload: [URL]
    }

    /// Resolves the best available archive location for an item.
    /// If iCloud Drive files aren't available but a bundle exists, extracts to local cache.
    /// - Parameters:
    ///   - item: The Item with archive data
    ///   - forceExtract: If true, always extract from bundle even if iCloud files exist
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

            return ResolvedArchive(
                pageURL: pageURL,
                readerURL: localReaderURL,
                assetsFolder: assetsFolder,
                isFromCache: false,
                filesToDownload: []
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
                isFromCache: true,
                filesToDownload: [] // Cache files are already local
            )
        }

        // No archive available
        return nil
    }

    /// No-op in CloudKit-only mode.
    public static func startDownloading(_ urls: [URL]) {
        _ = urls
    }

    /// Checks if a file exists locally.
    public static func isFileReady(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Checks if all expected local archive files exist for an item.
    public static func isICloudArchiveFullySynced(item: Item) -> Bool {
        guard let pageURL = item.archivedPageURL else { return false }

        let archiveFolder = pageURL.deletingLastPathComponent()
        let assetsFolder = archiveFolder.appendingPathComponent("assets", isDirectory: true)

        let filesToCheck = buildFilesToDownload(
            pageURL: pageURL,
            assetsFolder: assetsFolder,
            assetManifestJSON: item.assetManifestJSON
        )

        return filesToCheck.allSatisfy { isFileReady($0) }
    }

    /// Cleans up the bundle data from an item after iCloud Drive has fully synced.
    /// Call this from a managed object context.
    public static func cleanupBundleIfSynced(item: Item, context: NSManagedObjectContext) {
        guard isICloudArchiveFullySynced(item: item) else { return }

        // Also clean up local cache if it exists
        if let itemID = item.id {
            let cacheDir = LinkStorage.localCacheDirectoryURL(for: itemID)
            try? FileManager.default.removeItem(at: cacheDir)
        }
        _ = context
    }

    // MARK: - Private Helpers

    private static func buildFilesToDownload(pageURL: URL, assetsFolder: URL, assetManifestJSON: String?) -> [URL] {
        var files: [URL] = [pageURL]
        let fileManager = FileManager.default

        // Use manifest if available
        if let manifestJSON = assetManifestJSON,
           let manifestData = manifestJSON.data(using: .utf8),
           let assetFileNames = try? JSONDecoder().decode([String].self, from: manifestData) {
            for fileName in assetFileNames {
                files.append(assetsFolder.appendingPathComponent(fileName))
            }
            return files
        }

        // Fallback to enumeration
        guard fileManager.fileExists(atPath: assetsFolder.path) else { return files }

        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        if let enumerator = fileManager.enumerator(
            at: assetsFolder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let isDirectory = (try? fileURL.resourceValues(forKeys: keys))?.isDirectory ?? false
                if !isDirectory {
                    files.append(fileURL)
                }
            }
        }

        return files
    }
}
