import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController, UITextViewDelegate {
    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "StuffBucket"
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let subtitleLabel: UILabel = {
        let label = UILabel()
        label.text = "Add notes or tags before saving"
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let textView: UITextView = {
        let view = UITextView()
        view.font = .systemFont(ofSize: 15)
        view.backgroundColor = UIColor.secondarySystemBackground
        view.layer.cornerRadius = 10
        view.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let placeholderLabel: UILabel = {
        let label = UILabel()
        label.text = "Example: \"Key quote\" ai research tags"
        label.font = .systemFont(ofSize: 14)
        label.textColor = .tertiaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let saveButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Save", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        button.backgroundColor = UIColor.systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let cancelButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Cancel", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16)
        button.backgroundColor = UIColor.secondarySystemBackground
        button.setTitleColor(.label, for: .normal)
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let buttonStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private let containerStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private var sharedURL: URL?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        view.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        textView.delegate = self
        saveButton.isEnabled = false
        saveButton.alpha = 0.5
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        processShare()
    }

    private func setupUI() {
        view.addSubview(containerStack)
        containerStack.addArrangedSubview(titleLabel)
        containerStack.addArrangedSubview(subtitleLabel)
        containerStack.addArrangedSubview(textView)
        containerStack.addArrangedSubview(buttonStack)

        textView.addSubview(placeholderLabel)

        buttonStack.addArrangedSubview(cancelButton)
        buttonStack.addArrangedSubview(saveButton)

        NSLayoutConstraint.activate([
            containerStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            containerStack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            containerStack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),

            textView.heightAnchor.constraint(equalToConstant: 120),
            saveButton.heightAnchor.constraint(equalToConstant: 44),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),

            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -12)
        ])
    }

    private func processShare() {
        extractURL { [weak self] url in
            guard let self else { return }
            sharedURL = url
            if let url {
                saveButton.isEnabled = true
                saveButton.alpha = 1
                subtitleLabel.text = url.host ?? "Add notes or tags before saving"
            } else {
                subtitleLabel.text = "No URL found in this share."
                saveButton.isEnabled = false
                saveButton.alpha = 0.5
            }
        }
    }

    @objc private func saveTapped() {
        guard let url = sharedURL else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        let trimmed = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tagsText = trimmed.isEmpty ? nil : trimmed
        SharedCaptureStore.enqueue(url: url, tagsText: tagsText)
        openContainingAppAndDismiss()
    }

    @objc private func cancelTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    private func openContainingAppAndDismiss() {
        guard let url = URL(string: "stuffbucket://import") else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }

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

        let selector = sel_registerName("openURL:")
        responder = self
        while responder != nil {
            if responder!.responds(to: selector) {
                responder!.perform(selector, with: url)
                break
            }
            responder = responder?.next
        }

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
