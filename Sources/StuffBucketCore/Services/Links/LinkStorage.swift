import Foundation

enum StoragePaths {
    static let rootFolderName = "StuffBucket"

    static func localRootURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(rootFolderName, isDirectory: true)
    }
}

public enum StorageMigration {
    public static func migrateLocalStorageIfNeeded() {
        // CloudKit-only file sync mode: files stay local and are mirrored via Core Data binary fields.
        // Intentionally no-op in CloudKit-only mode.
    }
}

public enum LinkStorage {
    public static func url(forRelativePath relativePath: String) -> URL {
        StoragePaths.localRootURL().appendingPathComponent(relativePath)
    }

    static func writeHTML(data: Data, itemID: UUID) throws -> String {
        let fileURL = htmlURL(for: itemID)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return relativeHTMLPath(for: itemID)
    }

    static func writeReaderHTML(data: Data, itemID: UUID) throws -> String {
        let fileURL = readerURL(for: itemID)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return relativeReaderPath(for: itemID)
    }

    static func writeAsset(data: Data, itemID: UUID, fileName: String) throws -> String {
        let fileURL = assetURL(for: itemID, fileName: fileName)
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        return relativeAssetPath(for: fileName)
    }

    static func htmlURL(for itemID: UUID) -> URL {
        itemDirectory(for: itemID)
            .appendingPathComponent("page.html")
    }

    static func readerURL(for itemID: UUID) -> URL {
        itemDirectory(for: itemID)
            .appendingPathComponent("reader.html")
    }

    static func assetURL(for itemID: UUID, fileName: String) -> URL {
        itemDirectory(for: itemID)
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func relativeHTMLPath(for itemID: UUID) -> String {
        "Links/\(itemID.uuidString)/page.html"
    }

    static func relativeReaderPath(for itemID: UUID) -> String {
        "Links/\(itemID.uuidString)/reader.html"
    }

    static func relativeAssetPath(for fileName: String) -> String {
        "assets/\(fileName)"
    }

    /// Returns the directory URL for an item's archive (contains page.html, reader.html, assets/)
    public static func archiveDirectoryURL(for itemID: UUID) -> URL {
        itemDirectory(for: itemID)
    }

    /// Returns the local cache directory URL for an extracted archive bundle.
    /// Used when primary local files aren't available but the CloudKit bundle is.
    public static func localCacheDirectoryURL(for itemID: UUID) -> URL {
        localCacheRoot().appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    /// Returns the page.html URL from the local cache
    public static func localCachePageURL(for itemID: UUID) -> URL {
        localCacheDirectoryURL(for: itemID).appendingPathComponent("page.html")
    }

    /// Returns the reader.html URL from the local cache
    public static func localCacheReaderURL(for itemID: UUID) -> URL {
        localCacheDirectoryURL(for: itemID).appendingPathComponent("reader.html")
    }

    private static func localCacheRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("ExtractedArchives", isDirectory: true)
    }

    private static func linksDirectory() -> URL {
        rootDirectory().appendingPathComponent("Links", isDirectory: true)
    }

    private static func itemDirectory(for itemID: UUID) -> URL {
        linksDirectory().appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    private static func rootDirectory() -> URL {
        return StoragePaths.localRootURL()
    }
}

public enum DocumentStorage {
    /// Result of copying a document, includes optional bundle data for CloudKit sync
    public struct CopyResult {
        public let relativePath: String
        public let bundleData: Data?
    }

    static func copyDocument(from sourceURL: URL, itemID: UUID, fileName: String) throws -> String {
        let name = fileName.isEmpty ? "Document" : fileName
        let fileSize = try documentFileSize(at: sourceURL)
        let maxBytes = SyncPolicy.maxFileSizeBytes
        if fileSize > maxBytes {
            throw SyncError.fileTooLarge(fileName: name, actualBytes: fileSize, limitBytes: maxBytes)
        }
        let destinationURL = documentURL(for: itemID, fileName: name)
        let directoryURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return relativePath(for: itemID, fileName: name)
    }

    /// Copies a document and creates a CloudKit sync bundle
    static func copyDocumentWithBundle(from sourceURL: URL, itemID: UUID, fileName: String) throws -> CopyResult {
        let storedName = fileName.isEmpty ? "Document" : fileName
        let path = try copyDocument(from: sourceURL, itemID: itemID, fileName: storedName)

        // Store a direct document payload for CloudKit sync to avoid large in-memory archive creation.
        let destinationURL = documentURL(for: itemID, fileName: storedName)
        guard let bundleData = try? Data(contentsOf: destinationURL, options: [.mappedIfSafe]) else {
            throw SyncError.syncBundleCreationFailed(fileName: storedName)
        }

        return CopyResult(relativePath: path, bundleData: bundleData)
    }

    /// Returns the document directory URL for an item
    public static func documentDirectoryURL(for itemID: UUID) -> URL {
        documentsDirectory().appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    public static func url(forRelativePath relativePath: String) -> URL {
        rootDirectory().appendingPathComponent(relativePath)
    }

    public static func documentURL(for itemID: UUID, fileName: String) -> URL {
        documentsDirectory()
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func relativePath(for itemID: UUID, fileName: String) -> String {
        "Documents/\(itemID.uuidString)/\(fileName)"
    }

    private static func documentsDirectory() -> URL {
        rootDirectory().appendingPathComponent("Documents", isDirectory: true)
    }

    private static func rootDirectory() -> URL {
        return StoragePaths.localRootURL()
    }

    private static func documentFileSize(at url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        if let values = try? url.resourceValues(forKeys: keys) {
            if let size = values.totalFileAllocatedSize {
                return Int64(size)
            }
            if let size = values.fileAllocatedSize {
                return Int64(size)
            }
            if let size = values.fileSize {
                return Int64(size)
            }
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if let fileSize = attrs[.size] as? NSNumber {
            return fileSize.int64Value
        }
        return 0
    }
}
