import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {

    private let confirmationLabel: UILabel = {
        let label = UILabel()
        label.text = "Saved to StuffBucket"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemBlue
        view.layer.cornerRadius = 12
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        setupUI()
    }

    private func setupUI() {
        view.addSubview(containerView)
        containerView.addSubview(confirmationLabel)

        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 220),
            containerView.heightAnchor.constraint(equalToConstant: 60),

            confirmationLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            confirmationLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
        ])

        containerView.alpha = 0
        containerView.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        processShare()
    }

    private func processShare() {
        extractURL { [weak self] url in
            guard let self else { return }

            if let url {
                SharedCaptureStore.enqueue(url: url, tagsText: nil)
                self.showConfirmationAndDismiss()
            } else {
                self.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }

    private func showConfirmationAndDismiss() {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5) {
            self.containerView.alpha = 1
            self.containerView.transform = .identity
        } completion: { _ in
            // Brief delay to show the confirmation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.openContainingAppAndDismiss()
            }
        }
    }

    private func openContainingAppAndDismiss() {
        guard let url = URL(string: "stuffbucket://import") else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

        // Use responder chain to open URL (workaround for share extension limitation)
        var responder: UIResponder? = self
        while responder != nil {
            if let application = responder as? UIApplication {
                application.open(url, options: [:]) { _ in
                    self.extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }
            responder = responder?.next
        }

        // Fallback: try the selector-based approach
        let selector = sel_registerName("openURL:")
        responder = self
        while responder != nil {
            if responder!.responds(to: selector) {
                responder!.perform(selector, with: url)
                break
            }
            responder = responder?.next
        }

        // Complete even if we couldn't open the app
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func extractURL(completion: @escaping (URL?) -> Void) {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
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
}
