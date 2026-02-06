import AppKit
import SwiftUI
import StuffBucketCore

/// macOS-specific document actions
enum DocumentActions {
    static func openDocument(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func showInFinder(item: Item) throws {
        let materializedURL = try MaterializedDocumentStore.materializeDocument(for: item)
        NSWorkspace.shared.activateFileViewerSelecting([materializedURL])
    }
}
