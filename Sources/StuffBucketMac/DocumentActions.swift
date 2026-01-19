import AppKit
import SwiftUI

/// macOS-specific document actions
enum DocumentActions {
    static func openDocument(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func showInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
