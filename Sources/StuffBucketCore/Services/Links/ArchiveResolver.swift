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

        let iCloudPageURL = item.archivedPageURL
        let iCloudReaderURL = item.archivedReaderURL
        let fileManager = FileManager.default

        // Check if iCloud Drive files are available locally
        let iCloudAvailable = !forceExtract && iCloudPageURL != nil && fileManager.fileExists(atPath: iCloudPageURL!.path)

        if iCloudAvailable, let pageURL = iCloudPageURL {
            // Use iCloud Drive files
            let archiveFolder = pageURL.deletingLastPathComponent()
            let assetsFolder = archiveFolder.appendingPathComponent("assets", isDirectory: true)

            // Build list of files to download
            var filesToDownload = buildFilesToDownload(
                pageURL: pageURL,
                assetsFolder: assetsFolder,
                assetManifestJSON: item.assetManifestJSON
            )

            // Add reader if expected
            if let readerURL = iCloudReaderURL {
                filesToDownload.append(readerURL)
            }

            return ResolvedArchive(
                pageURL: pageURL,
                readerURL: iCloudReaderURL,
                assetsFolder: assetsFolder,
                isFromCache: false,
                filesToDownload: filesToDownload
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

    /// Starts downloading iCloud files if needed
    public static func startDownloading(_ urls: [URL]) {
        let fileManager = FileManager.default
        for url in urls {
            if fileManager.isUbiquitousItem(at: url) {
                try? fileManager.startDownloadingUbiquitousItem(at: url)
            }
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

    /// Checks if all iCloud Drive files for an archive are fully synced
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
        guard item.archiveZipData != nil else { return }
        guard isICloudArchiveFullySynced(item: item) else { return }

        // iCloud Drive is fully synced, remove the bundle
        item.archiveZipData = nil
        item.updatedAt = Date()

        // Also clean up local cache if it exists
        if let itemID = item.id {
            let cacheDir = LinkStorage.localCacheDirectoryURL(for: itemID)
            try? FileManager.default.removeItem(at: cacheDir)
        }

        if context.hasChanges {
            try? context.save()
        }
    }

    // MARK: - Private Helpers

    private static func buildFilesToDownload(pageURL: URL, assetsFolder: URL, assetManifestJSON: String?) -> [URL] {
        var files: [URL] = [pageURL]
        let fileManager = FileManager.default

        // Start folder downloads
        let archiveFolder = pageURL.deletingLastPathComponent()
        if fileManager.isUbiquitousItem(at: archiveFolder) {
            try? fileManager.startDownloadingUbiquitousItem(at: archiveFolder)
        }
        if fileManager.isUbiquitousItem(at: assetsFolder) {
            try? fileManager.startDownloadingUbiquitousItem(at: assetsFolder)
        }

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
