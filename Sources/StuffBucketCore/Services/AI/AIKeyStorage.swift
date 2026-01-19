import Foundation

public enum AIProvider: String, CaseIterable, Codable {
    case anthropic = "Anthropic"
    case openAI = "OpenAI"
}

public final class AIKeyStorage: ObservableObject {
    public static let shared = AIKeyStorage()

    private let cloudStore = NSUbiquitousKeyValueStore.default
    private let localStore = UserDefaults.standard

    private enum Keys {
        static let claudeAPIKey = "claudeAPIKey"
        static let openAIAPIKey = "openAIAPIKey"
        static let selectedProvider = "selectedAIProvider"
        static let selectedModelID = "selectedAIModelID"
        static let isAITaggingEnabled = "isAITaggingEnabled"
    }

    @Published public private(set) var claudeAPIKey: String?
    @Published public private(set) var openAIAPIKey: String?
    @Published public var selectedProvider: AIProvider = .anthropic
    @Published public var selectedModelID: String?
    @Published public var isAITaggingEnabled: Bool = false

    public var hasValidKey: Bool {
        switch selectedProvider {
        case .anthropic:
            return claudeAPIKey != nil && !claudeAPIKey!.isEmpty
        case .openAI:
            return openAIAPIKey != nil && !openAIAPIKey!.isEmpty
        }
    }

    public var currentAPIKey: String? {
        switch selectedProvider {
        case .anthropic:
            return claudeAPIKey
        case .openAI:
            return openAIAPIKey
        }
    }

    private init() {
        loadFromStore()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore
        )
        cloudStore.synchronize()
    }

    private func loadFromStore() {
        // Try cloud first, fall back to local
        claudeAPIKey = cloudStore.string(forKey: Keys.claudeAPIKey)
            ?? localStore.string(forKey: Keys.claudeAPIKey)
        openAIAPIKey = cloudStore.string(forKey: Keys.openAIAPIKey)
            ?? localStore.string(forKey: Keys.openAIAPIKey)

        let providerRaw = cloudStore.string(forKey: Keys.selectedProvider)
            ?? localStore.string(forKey: Keys.selectedProvider)
        if let providerRaw, let provider = AIProvider(rawValue: providerRaw) {
            selectedProvider = provider
        }

        selectedModelID = cloudStore.string(forKey: Keys.selectedModelID)
            ?? localStore.string(forKey: Keys.selectedModelID)

        // For bool, check if cloud has a value, otherwise use local
        if cloudStore.object(forKey: Keys.isAITaggingEnabled) != nil {
            isAITaggingEnabled = cloudStore.bool(forKey: Keys.isAITaggingEnabled)
        } else {
            isAITaggingEnabled = localStore.bool(forKey: Keys.isAITaggingEnabled)
        }
    }

    @objc private func storeDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.loadFromStore()
        }
    }

    public func setClaudeAPIKey(_ key: String?) {
        claudeAPIKey = key
        cloudStore.set(key, forKey: Keys.claudeAPIKey)
        localStore.set(key, forKey: Keys.claudeAPIKey)
        cloudStore.synchronize()
    }

    public func setOpenAIAPIKey(_ key: String?) {
        openAIAPIKey = key
        cloudStore.set(key, forKey: Keys.openAIAPIKey)
        localStore.set(key, forKey: Keys.openAIAPIKey)
        cloudStore.synchronize()
    }

    public func setSelectedProvider(_ provider: AIProvider) {
        selectedProvider = provider
        cloudStore.set(provider.rawValue, forKey: Keys.selectedProvider)
        localStore.set(provider.rawValue, forKey: Keys.selectedProvider)
        cloudStore.synchronize()
    }

    public func setSelectedModelID(_ modelID: String?) {
        selectedModelID = modelID
        cloudStore.set(modelID, forKey: Keys.selectedModelID)
        localStore.set(modelID, forKey: Keys.selectedModelID)
        cloudStore.synchronize()
    }

    public func setAITaggingEnabled(_ enabled: Bool) {
        isAITaggingEnabled = enabled
        cloudStore.set(enabled, forKey: Keys.isAITaggingEnabled)
        localStore.set(enabled, forKey: Keys.isAITaggingEnabled)
        cloudStore.synchronize()
    }

    public func deleteAllKeys() {
        claudeAPIKey = nil
        openAIAPIKey = nil
        selectedModelID = nil

        cloudStore.removeObject(forKey: Keys.claudeAPIKey)
        cloudStore.removeObject(forKey: Keys.openAIAPIKey)
        cloudStore.removeObject(forKey: Keys.selectedModelID)
        localStore.removeObject(forKey: Keys.claudeAPIKey)
        localStore.removeObject(forKey: Keys.openAIAPIKey)
        localStore.removeObject(forKey: Keys.selectedModelID)
        cloudStore.synchronize()
    }
}
