import AppKit
import UniformTypeIdentifiers

final class ShareViewController: NSViewController, NSTextViewDelegate {
    private enum SharedPayload {
        case link(URL)
        case document(SharedCaptureStaging)
    }

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "StuffBucket")
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private let subtitleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Add notes or tags before saving")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()

    private let textView: NSTextView = {
        let view = NSTextView(frame: .zero)
        view.font = .systemFont(ofSize: 13)
        view.drawsBackground = false
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isContinuousSpellCheckingEnabled = true
        return view
    }()

    private let textScrollView: NSScrollView = {
        let view = NSScrollView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.hasVerticalScroller = true
        view.borderType = .bezelBorder
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        return view
    }()

    private let placeholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Example: \"Key quote\" tag1, tag2")
        label.font = .systemFont(ofSize: 12)
        label.textColor = .placeholderTextColor
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let saveButton: NSButton = {
        let button = NSButton(title: "Save", target: nil, action: nil)
        button.bezelStyle = .rounded
        return button
    }()

    private let cancelButton: NSButton = {
        let button = NSButton(title: "Cancel", target: nil, action: nil)
        button.bezelStyle = .rounded
        return button
    }()

    private var sharedPayload: SharedPayload?
    private var extensionRequestContext: NSExtensionContext?
    private var didCommitPayload = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    deinit {
        cleanupStagedDocumentIfNeeded()
    }

    override func beginRequest(with context: NSExtensionContext) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.extensionRequestContext = context
            self.loadViewIfNeeded()
            self.textView.string = self.extractTagsText(from: context) ?? ""
            self.updatePlaceholderVisibility()
            self.processShare(in: context)
        }
    }

    private func setupUI() {
        preferredContentSize = NSSize(width: 440, height: 280)

        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false

        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.keyEquivalent = "\u{1b}"

        textView.delegate = self
        textScrollView.documentView = textView
        textScrollView.contentView.addSubview(placeholderLabel)

        let buttonRow = NSStackView(views: [NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.setHuggingPriority(.defaultLow, for: .horizontal)

        let contentStack = NSStackView(views: [titleLabel, subtitleLabel, textScrollView, buttonRow])
        contentStack.orientation = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),

            textScrollView.heightAnchor.constraint(equalToConstant: 120),

            placeholderLabel.leadingAnchor.constraint(equalTo: textScrollView.contentView.leadingAnchor, constant: 6),
            placeholderLabel.topAnchor.constraint(equalTo: textScrollView.contentView.topAnchor, constant: 8)
        ])
    }

    private func processShare(in context: NSExtensionContext) {
        extractImage(from: context) { [weak self] fileURL in
            guard let self else { return }
            if let fileURL {
                if let staged = SharedCaptureStore.stageDocumentCopy(from: fileURL, preferredFileName: fileURL.lastPathComponent) {
                    self.updateSharedPayload(.document(staged))
                } else {
                    self.updateSharedPayload(nil)
                }
                return
            }
            self.extractURL(from: context) { url in
                if let url {
                    if url.isFileURL {
                        if let staged = SharedCaptureStore.stageDocumentCopy(from: url, preferredFileName: url.lastPathComponent) {
                            self.updateSharedPayload(.document(staged))
                        } else {
                            self.updateSharedPayload(nil)
                        }
                    } else {
                        self.updateSharedPayload(.link(url))
                    }
                    return
                }
                self.updateSharedPayload(nil)
            }
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
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) }) {
            loadPropertyListURL(from: provider, completion: completion)
            return
        }
        completion(nil)
    }

    private func extractImage(from context: NSExtensionContext, completion: @escaping (URL?) -> Void) {
        let items = context.inputItems as? [NSExtensionItem] ?? []
        let providers = items.compactMap { $0.attachments }.flatMap { $0 }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else {
            completion(nil)
            return
        }
        let typeIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            UTType(identifier)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier
        provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
            if let url {
                DispatchQueue.main.async {
                    completion(url)
                }
                return
            }
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
                guard let data else {
                    DispatchQueue.main.async {
                        completion(nil)
                    }
                    return
                }
                let fileName = Self.buildImageFileName(provider: provider, typeIdentifier: typeIdentifier)
                let tempURL = Self.writeTemporaryFile(data: data, fileName: fileName)
                DispatchQueue.main.async {
                    completion(tempURL)
                }
            }
        }
    }

    private func loadPropertyListURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { item, _ in
            let url = Self.coerceURLFromPropertyList(item)
            DispatchQueue.main.async {
                completion(url)
            }
        }
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
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(string: trimmed)
        }
        return nil
    }

    private static func coerceURLFromPropertyList(_ item: NSSecureCoding?) -> URL? {
        if let dict = item as? [AnyHashable: Any] {
            return urlFromAny(dict)
        }
        if let dict = item as? NSDictionary {
            return urlFromAny(dict)
        }
        if let data = item as? Data,
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            return urlFromAny(plist)
        }
        return coerceURL(from: item)
    }

    private static func urlFromAny(_ value: Any) -> URL? {
        if let url = value as? URL {
            return url
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), url.scheme != nil {
                return url
            }
            return nil
        }
        if let dict = value as? [AnyHashable: Any] {
            if let nested = dict["NSExtensionJavaScriptPreprocessingResultsKey"] {
                if let url = urlFromAny(nested) {
                    return url
                }
            }
            let preferredKeys = ["URL", "url", "link", "href", "baseURI", "baseUrl", "canonicalURL", "canonicalUrl"]
            for key in preferredKeys {
                if let candidate = dict[key], let url = urlFromAny(candidate) {
                    return url
                }
            }
            for candidate in dict.values {
                if let url = urlFromAny(candidate) {
                    return url
                }
            }
            return nil
        }
        if let array = value as? [Any] {
            for candidate in array {
                if let url = urlFromAny(candidate) {
                    return url
                }
            }
            return nil
        }
        return nil
    }

    private static func buildImageFileName(provider: NSItemProvider, typeIdentifier: String) -> String {
        let base = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = UTType(typeIdentifier)
        let ext = type?.preferredFilenameExtension ?? "png"
        let resolvedBase = (base?.isEmpty == false ? base! : "Image")
        if resolvedBase.lowercased().hasSuffix(".\(ext)") {
            return resolvedBase
        }
        return "\(resolvedBase).\(ext)"
    }

    private static func writeTemporaryFile(data: Data, fileName: String) -> URL? {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let fileURL = rootURL.appendingPathComponent(fileName)
            try data.write(to: fileURL, options: [.atomic])
            return fileURL
        } catch {
            return nil
        }
    }

    @objc private func saveTapped() {
        let tagsText = trimmedText(from: textView.string)
        switch sharedPayload {
        case .link(let url):
            SharedCaptureStore.enqueue(url: url, tagsText: tagsText)
            openContainingAppAndComplete()
        case .document(let staging):
            SharedCaptureStore.enqueueStagedDocument(staging, tagsText: tagsText)
            didCommitPayload = true
            openContainingAppAndComplete()
        case .none:
            completeRequest()
        }
    }

    @objc private func cancelTapped() {
        cleanupStagedDocumentIfNeeded()
        completeRequest()
    }

    func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateSharedPayload(_ payload: SharedPayload?) {
        if case .document(let existing) = sharedPayload {
            let keepExisting: Bool
            if case .document(let next) = payload {
                keepExisting = next.relativePath == existing.relativePath
            } else {
                keepExisting = false
            }
            if !keepExisting {
                SharedCaptureStore.removeSharedFile(relativePath: existing.relativePath)
            }
        }

        sharedPayload = payload
        switch payload {
        case .link(let url):
            saveButton.isEnabled = true
            subtitleLabel.stringValue = url.host ?? url.absoluteString
        case .document(let staging):
            saveButton.isEnabled = true
            subtitleLabel.stringValue = staging.fileName
        case .none:
            saveButton.isEnabled = false
            subtitleLabel.stringValue = "No URL or image found in this share."
        }
    }

    private func cleanupStagedDocumentIfNeeded() {
        guard !didCommitPayload else { return }
        if case .document(let staging) = sharedPayload {
            SharedCaptureStore.removeSharedFile(relativePath: staging.relativePath)
        }
    }

    private func openContainingAppAndComplete() {
        guard let context = extensionRequestContext else {
            completeRequest()
            return
        }
        Self.openContainingApp(from: context) { [weak self] in
            self?.completeRequest()
        }
    }

    private func completeRequest() {
        extensionRequestContext?.completeRequest(returningItems: nil)
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
