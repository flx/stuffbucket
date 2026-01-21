import Foundation

enum StoragePaths {
    static let rootFolderName = "StuffBucket"

    static func iCloudRootURL(fileManager: FileManager = .default) -> URL? {
        fileManager.url(forUbiquityContainerIdentifier: ICloudConfig.containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(rootFolderName, isDirectory: true)
    }

    static func localRootURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(rootFolderName, isDirectory: true)
    }
}

public enum StorageMigration {
    private static let migrationQueue = DispatchQueue(label: "com.digitalhandstand.stuffbucket.storage.migration", qos: .utility)

    public static func migrateLocalStorageIfNeeded() {
        migrationQueue.async {
            let fileManager = FileManager.default
            guard let iCloudRoot = StoragePaths.iCloudRootURL(fileManager: fileManager) else { return }
            let localRoot = StoragePaths.localRootURL(fileManager: fileManager)
            guard fileManager.fileExists(atPath: localRoot.path) else { return }

            do {
                try fileManager.createDirectory(at: iCloudRoot, withIntermediateDirectories: true)
            } catch {
                NSLog("Storage migration: failed to create iCloud root: \(error)")
                return
            }

            let folders = ["Links", "Documents", "Protected"]
            for folder in folders {
                let localFolder = localRoot.appendingPathComponent(folder, isDirectory: true)
                guard fileManager.fileExists(atPath: localFolder.path) else { continue }
                let iCloudFolder = iCloudRoot.appendingPathComponent(folder, isDirectory: true)
                try? fileManager.createDirectory(at: iCloudFolder, withIntermediateDirectories: true)
                migrateContents(from: localFolder, to: iCloudFolder, fileManager: fileManager)
                pruneEmptyDirectories(root: localFolder, fileManager: fileManager)
            }
        }
    }

    private static func migrateContents(from localRoot: URL, to iCloudRoot: URL, fileManager: FileManager) {
        let localRootPath = localRoot.path
        let prefix = localRootPath.hasSuffix("/") ? localRootPath : localRootPath + "/"
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: localRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let localURL as URL in enumerator {
            guard localURL.path.hasPrefix(prefix) else { continue }
            let relativePath = String(localURL.path.dropFirst(prefix.count))
            guard !relativePath.isEmpty else { continue }
            let isDirectory = (try? localURL.resourceValues(forKeys: directoryKeys))?.isDirectory ?? false
            let destinationURL = iCloudRoot.appendingPathComponent(relativePath, isDirectory: isDirectory)

            if isDirectory {
                try? fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                continue
            }

            let shouldReplace = shouldReplaceDestination(localURL: localURL, destinationURL: destinationURL, fileManager: fileManager)
            if fileManager.fileExists(atPath: destinationURL.path) && !shouldReplace {
                try? fileManager.removeItem(at: localURL)
                continue
            }
            do {
                try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: localURL, to: destinationURL)
                try? fileManager.removeItem(at: localURL)
            } catch {
                NSLog("Storage migration: failed to copy \(localURL.lastPathComponent): \(error)")
            }
        }
    }

    private static func shouldReplaceDestination(
        localURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: destinationURL.path) else { return true }
        let localDate = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let destinationDate = (try? destinationURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        switch (localDate, destinationDate) {
        case let (.some(local), .some(destination)):
            return local > destination
        case (.some, .none):
            return true
        default:
            return false
        }
    }

    private static func pruneEmptyDirectories(root: URL, fileManager: FileManager) {
        let directoryKeys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(directoryKeys),
            options: [.skipsHiddenFiles]
        ) else { return }
        var directories: [URL] = []

        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: directoryKeys))?.isDirectory ?? false
            if isDirectory {
                directories.append(url)
            }
        }

        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path), contents.isEmpty else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }

        if let contents = try? fileManager.contentsOfDirectory(atPath: root.path), contents.isEmpty {
            try? fileManager.removeItem(at: root)
        }
    }
}

public enum LinkStorage {
    public static func url(forRelativePath relativePath: String) -> URL {
        let fileManager = FileManager.default
        if let iCloudRoot = StoragePaths.iCloudRootURL(fileManager: fileManager) {
            let iCloudURL = iCloudRoot.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: iCloudURL.path) {
                return iCloudURL
            }
            let localURL = StoragePaths.localRootURL(fileManager: fileManager).appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: localURL.path) {
                return localURL
            }
            return iCloudURL
        }
        return StoragePaths.localRootURL(fileManager: fileManager).appendingPathComponent(relativePath)
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
    /// Used when iCloud Drive files aren't available but the CloudKit bundle is.
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
        if let iCloudRoot = StoragePaths.iCloudRootURL() {
            return iCloudRoot
        }
        return StoragePaths.localRootURL()
    }
}

public enum DocumentStorage {
    static func copyDocument(from sourceURL: URL, itemID: UUID, fileName: String) throws -> String {
        let name = fileName.isEmpty ? "Document" : fileName
        let destinationURL = documentURL(for: itemID, fileName: name)
        let directoryURL = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return relativePath(for: itemID, fileName: name)
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
        if let iCloudRoot = StoragePaths.iCloudRootURL() {
            return iCloudRoot
        }
        return StoragePaths.localRootURL()
    }
}
