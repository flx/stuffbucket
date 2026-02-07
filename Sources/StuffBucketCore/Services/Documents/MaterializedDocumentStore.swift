import Foundation

#if os(macOS)
import AppKit
#endif

public enum MaterializedDocumentStore {
#if os(macOS)
    private static let bookmarkKey = "com.digitalhandstand.stuffbucket.materializedDocumentFolderBookmark"
    private static let pathKey = "com.digitalhandstand.stuffbucket.materializedDocumentFolderPath"
    private static let materializedSubfolder = "StuffBucket"

    public static func selectedRootPath() -> String? {
        guard let url = resolveRootURL() else { return nil }
        return url.path
    }

    @discardableResult
    public static func chooseRootFolder() throws -> URL {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose where StuffBucket should materialize synced files for Finder."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            throw SyncError.materializationCancelled
        }
        storeRootURL(url)
        return url
    }

    public static func clearRootFolderSelection() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
    }

    public static func materializeDocument(for item: Item) throws -> URL {
        guard let itemID = item.id else {
            throw SyncError.documentUnavailable
        }
        guard let resolved = DocumentResolver.resolve(item: item),
              FileManager.default.fileExists(atPath: resolved.documentURL.path) else {
            throw SyncError.documentUnavailable
        }

        let fileName = item.documentFileName ?? "Document"
        guard let rootURL = resolveRootURL() else {
            throw SyncError.materializationFolderNotSelected
        }

        let destination = rootURL
            .appendingPathComponent(materializedSubfolder, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)

        let rootAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if rootAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: resolved.documentURL, to: destination)
        return destination
    }

    public static func resetMaterializedCopies() {
        guard let rootURL = resolveRootURL() else { return }
        let rootAccess = rootURL.startAccessingSecurityScopedResource()
        defer {
            if rootAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }
        let folder = rootURL.appendingPathComponent(materializedSubfolder, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    private static func storeRootURL(_ url: URL) {
        let normalizedURL = url.standardizedFileURL
        UserDefaults.standard.set(normalizedURL.path, forKey: pathKey)

        do {
            let bookmark = try normalizedURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            // Some folders/providers fail bookmark creation; keep path fallback so the app remains usable.
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            NSLog("MaterializedDocumentStore: failed to create security-scoped bookmark: \(error)")
        }
    }

    private static func resolveRootURL() -> URL? {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if isStale {
                    storeRootURL(url)
                }
                return url
            }
        }

        if let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        return nil
    }
#else
    public static func selectedRootPath() -> String? { nil }
    @discardableResult
    public static func chooseRootFolder() throws -> URL { throw SyncError.materializationFolderNotSelected }
    public static func clearRootFolderSelection() {}
    public static func materializeDocument(for item: Item) throws -> URL { throw SyncError.documentUnavailable }
    public static func resetMaterializedCopies() {}
#endif
}
