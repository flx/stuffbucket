import AppKit
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: .zero)
    }

    override func beginRequest(with context: NSExtensionContext) {
        extractURL(from: context) { url in
            if let url {
                SharedCaptureStore.enqueue(url: url)
                Self.openContainingApp(from: context)
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

    private func loadURL(from provider: NSItemProvider, typeIdentifier: String, completion: @escaping (URL?) -> Void) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            let url = Self.coerceURL(from: item)
            DispatchQueue.main.async {
                completion(url)
            }
        }
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

    private static func openContainingApp(from context: NSExtensionContext) {
        guard let url = URL(string: "stuffbucket://import") else { return }
        context.open(url, completionHandler: nil)
    }
}
