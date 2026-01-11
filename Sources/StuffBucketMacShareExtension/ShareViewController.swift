import AppKit
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func beginRequest(with context: NSExtensionContext) {
        let tagsText = extractTagsText(from: context)
        extractURL(from: context) { url in
            if let url {
                SharedCaptureStore.enqueue(url: url, tagsText: tagsText)
                Self.openContainingApp(from: context) {
                    context.completeRequest(returningItems: nil)
                }
                return
            }
            context.completeRequest(returningItems: nil)
        }
    }

    private func extractURL(from context: NSExtensionContext, completion: @escaping (URL?) -> Void) {
        let items = context.inputItems as? [NSExtensionItem] ?? []
        let providers = items.compactMap { $0.attachments }.flatMap { $0 }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            loadURL(from: provider, typeIdentifier: UTType.url.identifier, completion: completion)
            return
        }
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            loadURL(from: provider, typeIdentifier: UTType.plainText.identifier, completion: completion)
            return
        }
        completion(nil)
    }

    private func extractTagsText(from context: NSExtensionContext) -> String? {
        let items = context.inputItems as? [NSExtensionItem] ?? []
        for item in items {
            if let text = trimmedText(from: item.attributedContentText?.string) {
                return text
            }
            if let userInfo = item.userInfo {
                if let text = trimmedText(from: userInfo[NSExtensionItemAttributedContentTextKey] as? NSAttributedString) {
                    return text
                }
                if let text = trimmedText(from: userInfo[NSExtensionItemAttributedContentTextKey] as? String) {
                    return text
                }
                if let text = trimmedText(from: userInfo[NSExtensionItemAttributedTitleKey] as? NSAttributedString) {
                    return text
                }
                if let text = trimmedText(from: userInfo[NSExtensionItemAttributedTitleKey] as? String) {
                    return text
                }
            }
        }
        return nil
    }

    private func loadURL(from provider: NSItemProvider, typeIdentifier: String, completion: @escaping (URL?) -> Void) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            let url = Self.coerceURL(from: item)
            DispatchQueue.main.async {
                completion(url)
            }
        }
    }

    private func trimmedText(from text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func trimmedText(from text: NSAttributedString?) -> String? {
        trimmedText(from: text?.string)
    }

    private static func coerceURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }

    private static func openContainingApp(from context: NSExtensionContext, completion: @escaping () -> Void) {
        guard let url = URL(string: "stuffbucket-mac://import") else {
            completion()
            return
        }
        let bundleIdentifier = "com.digitalhandstand.stuffbucket.app.mac"
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, _ in
                completion()
            }
            return
        }
        context.open(url) { _ in
            completion()
        }
    }
}
