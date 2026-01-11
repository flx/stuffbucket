import Foundation

enum LinkStorage {
    private static let rootFolderName = "StuffBucket"

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

    private static func linksDirectory() -> URL {
        rootDirectory().appendingPathComponent("Links", isDirectory: true)
    }

    private static func itemDirectory(for itemID: UUID) -> URL {
        linksDirectory().appendingPathComponent(itemID.uuidString, isDirectory: true)
    }

    private static func rootDirectory() -> URL {
        if let iCloudRoot = FileManager.default.url(forUbiquityContainerIdentifier: ICloudConfig.containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(rootFolderName, isDirectory: true) {
            return iCloudRoot
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(rootFolderName, isDirectory: true)
    }
}

enum DocumentStorage {
    private static let rootFolderName = "StuffBucket"

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

    static func url(forRelativePath relativePath: String) -> URL {
        rootDirectory().appendingPathComponent(relativePath)
    }

    static func documentURL(for itemID: UUID, fileName: String) -> URL {
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
        if let iCloudRoot = FileManager.default.url(forUbiquityContainerIdentifier: ICloudConfig.containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(rootFolderName, isDirectory: true) {
            return iCloudRoot
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(rootFolderName, isDirectory: true)
    }
}
