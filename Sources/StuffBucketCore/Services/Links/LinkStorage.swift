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

    static func htmlURL(for itemID: UUID) -> URL {
        linksDirectory().appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent("page.html")
    }

    static func relativeHTMLPath(for itemID: UUID) -> String {
        "Links/\(itemID.uuidString)/page.html"
    }

    private static func linksDirectory() -> URL {
        rootDirectory().appendingPathComponent("Links", isDirectory: true)
    }

    private static func rootDirectory() -> URL {
        if let iCloudRoot = FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(rootFolderName, isDirectory: true) {
            return iCloudRoot
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(rootFolderName, isDirectory: true)
    }
}
