import SwiftUI
import StuffBucketCore
#if os(macOS)
import AppKit
#endif

public struct AISettingsView: View {
    @ObservedObject private var keyStorage = AIKeyStorage.shared
    @Environment(\.dismiss) private var dismiss

    @State private var claudeKey = ""
    @State private var openAIKey = ""
    @State private var isValidatingClaude = false
    @State private var isValidatingOpenAI = false
    @State private var claudeModels: [String] = AnthropicModelDefaults.availableModels
    @State private var openAIModels: [String] = OpenAIModelDefaults.availableModels
    @State private var validationError: String?
    @State private var showDeleteConfirmation = false
    @State private var maxSyncFileSizeMB = SyncPolicy.maxFileSizeMB
    @State private var materializedRootPath: String?
    @State private var showSyncResetConfirmation = false
    @State private var isResettingSyncData = false
    @State private var modelRefreshTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                providerSection
                apiKeySection
                modelSection
                syncSection
                resetSyncSection
                deleteSection
            }
            .navigationTitle("AI Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .formStyle(.grouped)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .frame(width: 520, height: 520)
            #endif
            .onAppear {
                claudeKey = keyStorage.claudeAPIKey ?? ""
                openAIKey = keyStorage.openAIAPIKey ?? ""
                maxSyncFileSizeMB = SyncPolicy.maxFileSizeMB
                materializedRootPath = MaterializedDocumentStore.selectedRootPath()
                refreshModelsForCurrentProvider()
            }
            .onChange(of: keyStorage.selectedProvider) { _, _ in
                refreshModelsForCurrentProvider()
            }
            .onDisappear {
                modelRefreshTask?.cancel()
            }
            .alert("Validation Error", isPresented: .constant(validationError != nil)) {
                Button("OK") { validationError = nil }
            } message: {
                Text(validationError ?? "")
            }
            .confirmationDialog("Delete API Keys", isPresented: $showDeleteConfirmation) {
                Button("Delete All Keys", role: .destructive) {
                    keyStorage.deleteAllKeys()
                    claudeKey = ""
                    openAIKey = ""
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all stored API keys. You'll need to re-enter them to use AI features.")
            }
            .confirmationDialog("Reset Sync Data", isPresented: $showSyncResetConfirmation) {
                Button("Reset Local Data", role: .destructive) {
                    resetSyncData(includeCloudKit: false)
                }
                Button("Reset Local + CloudKit Data", role: .destructive) {
                    resetSyncData(includeCloudKit: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes all synced items and files. Use this only when starting from a clean state.")
            }
        }
    }

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: Binding(
                get: { keyStorage.selectedProvider },
                set: { keyStorage.setSelectedProvider($0) }
            )) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            #if os(iOS)
            .pickerStyle(.segmented)
            #endif
        }
    }

    private var apiKeySection: some View {
        Section {
            switch keyStorage.selectedProvider {
            case .anthropic:
                HStack {
                    SecureField("API Key", text: $claudeKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif

                    if isValidatingClaude {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Save") {
                            saveClaudeKey()
                        }
                        .disabled(claudeKey.isEmpty)
                    }
                }

            case .openAI:
                HStack {
                    SecureField("API Key", text: $openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif

                    if isValidatingOpenAI {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Save") {
                            saveOpenAIKey()
                        }
                        .disabled(openAIKey.isEmpty)
                    }
                }
            }
        } footer: {
            switch keyStorage.selectedProvider {
            case .anthropic:
                Text("Get your API key from console.anthropic.com")
            case .openAI:
                Text("Get your API key from platform.openai.com")
            }
        }
    }

    private var modelSection: some View {
        Section {
            let models = keyStorage.selectedProvider == .anthropic ? claudeModels : openAIModels
            let recommended = keyStorage.selectedProvider == .anthropic
                ? AnthropicModelDefaults.recommendedModels
                : OpenAIModelDefaults.recommendedModels

            Picker("Model", selection: Binding(
                get: {
                    // Ensure the selected model exists in the current provider's list
                    let currentSelection = keyStorage.selectedModelID ?? defaultModelID
                    if models.contains(currentSelection) {
                        return currentSelection
                    }
                    return defaultModelID
                },
                set: { keyStorage.setSelectedModelID($0) }
            )) {
                ForEach(models, id: \.self) { model in
                    HStack {
                        Text(model)
                        if recommended.contains(model) {
                            Text("Recommended")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(model)
                }
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button("Delete All API Keys", role: .destructive) {
                showDeleteConfirmation = true
            }
            .disabled(!keyStorage.hasValidKey)
        }
    }

    private var syncSection: some View {
        Section {
            Stepper(value: $maxSyncFileSizeMB, in: SyncPolicy.minimumMaxFileSizeMB...SyncPolicy.maximumMaxFileSizeMB, step: 50) {
                Text("Max synced file size: \(maxSyncFileSizeMB) MB")
            }
            .onChange(of: maxSyncFileSizeMB) { _, newValue in
                SyncPolicy.maxFileSizeMB = newValue
                maxSyncFileSizeMB = SyncPolicy.maxFileSizeMB
            }

#if os(macOS)
            HStack {
                Text("Finder Folder")
                Spacer()
                Text(materializedRootPath ?? "Not selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Button("Choose Folder...") {
                    chooseMaterializationFolder()
                }
                if let path = materializedRootPath {
                    Button("Open Folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
                    }
                    Button("Clear Folder", role: .destructive) {
                        MaterializedDocumentStore.clearRootFolderSelection()
                        materializedRootPath = nil
                    }
                }
            }
#endif
        } header: {
            Text("Sync")
        } footer: {
            Text("Files larger than this limit won't be imported for sync.")
        }
    }

    private var resetSyncSection: some View {
        Section {
            Button(role: .destructive) {
                showSyncResetConfirmation = true
            } label: {
                if isResettingSyncData {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Resetting sync data...")
                    }
                } else {
                    Text("Reset Sync Data")
                }
            }
            .disabled(isResettingSyncData)
        } header: {
            Text("Reset")
        } footer: {
            Text("Use reset only for development/test environments. It permanently removes local records and optionally CloudKit records.")
        }
    }

    private var defaultModelID: String {
        defaultModelID(for: keyStorage.selectedProvider)
    }

    private func saveClaudeKey() {
        guard !claudeKey.isEmpty else { return }
        isValidatingClaude = true
        modelRefreshTask?.cancel()

        Task {
            do {
                let models = try await fetchModels(for: .anthropic, apiKey: claudeKey)
                await MainActor.run {
                    keyStorage.setClaudeAPIKey(claudeKey)
                    applyModels(models, for: .anthropic)
                    isValidatingClaude = false
                }
            } catch {
                await MainActor.run {
                    validationError = "Invalid API key: \(error.localizedDescription)"
                    isValidatingClaude = false
                }
            }
        }
    }

    private func saveOpenAIKey() {
        guard !openAIKey.isEmpty else { return }
        isValidatingOpenAI = true
        modelRefreshTask?.cancel()

        Task {
            do {
                let models = try await fetchModels(for: .openAI, apiKey: openAIKey)
                await MainActor.run {
                    keyStorage.setOpenAIAPIKey(openAIKey)
                    applyModels(models, for: .openAI)
                    isValidatingOpenAI = false
                }
            } catch {
                await MainActor.run {
                    validationError = "Invalid API key: \(error.localizedDescription)"
                    isValidatingOpenAI = false
                }
            }
        }
    }

    private func refreshModelsForCurrentProvider() {
        modelRefreshTask?.cancel()

        let provider = keyStorage.selectedProvider
        let key: String?
        switch provider {
        case .anthropic:
            key = keyStorage.claudeAPIKey
        case .openAI:
            key = keyStorage.openAIAPIKey
        }

        guard let key, !key.isEmpty else {
            applyModels([], for: provider)
            return
        }

        modelRefreshTask = Task {
            do {
                let models = try await fetchModels(for: provider, apiKey: key)
                try Task.checkCancellation()
                await MainActor.run {
                    guard keyStorage.selectedProvider == provider else { return }
                    applyModels(models, for: provider)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard keyStorage.selectedProvider == provider else { return }
                    applyModels([], for: provider)
                }
            }
        }
    }

    private func fetchModels(for provider: AIProvider, apiKey: String) async throws -> [String] {
        switch provider {
        case .anthropic:
            let client = AnthropicClient(apiKey: apiKey)
            return try await client.validateAPIKey()
        case .openAI:
            let client = OpenAIClient(apiKey: apiKey)
            let allModels = try await client.validateAPIKey()
            return OpenAIClient.chatModelIDs(from: allModels)
        }
    }

    private func applyModels(_ models: [String], for provider: AIProvider) {
        let effectiveModels = models.isEmpty ? fallbackModels(for: provider) : models
        switch provider {
        case .anthropic:
            claudeModels = effectiveModels
        case .openAI:
            openAIModels = effectiveModels
        }

        guard keyStorage.selectedProvider == provider else { return }
        ensureValidSelectedModel(for: provider, availableModels: effectiveModels)
    }

    private func ensureValidSelectedModel(for provider: AIProvider, availableModels: [String]) {
        guard !availableModels.isEmpty else {
            keyStorage.setSelectedModelID(nil)
            return
        }

        if let selectedModel = keyStorage.selectedModelID, availableModels.contains(selectedModel) {
            return
        }

        let preferredModel = defaultModelID(for: provider)
        if availableModels.contains(preferredModel) {
            keyStorage.setSelectedModelID(preferredModel)
        } else {
            keyStorage.setSelectedModelID(availableModels[0])
        }
    }

    private func defaultModelID(for provider: AIProvider) -> String {
        switch provider {
        case .anthropic:
            return AnthropicModelDefaults.defaultModelID
        case .openAI:
            return OpenAIModelDefaults.defaultModelID
        }
    }

    private func fallbackModels(for provider: AIProvider) -> [String] {
        switch provider {
        case .anthropic:
            return AnthropicModelDefaults.availableModels
        case .openAI:
            return OpenAIModelDefaults.availableModels
        }
    }

#if os(macOS)
    private func chooseMaterializationFolder() {
        do {
            let url = try MaterializedDocumentStore.chooseRootFolder()
            materializedRootPath = url.path
        } catch {
            if case SyncError.materializationCancelled = error {
                return
            }
            validationError = error.localizedDescription
        }
    }
#endif

    private func resetSyncData(includeCloudKit: Bool) {
        isResettingSyncData = true
        Task {
            do {
                if includeCloudKit {
                    try await SyncResetService.resetLocalAndCloudKitData()
                } else {
                    try await SyncResetService.resetLocalData()
                }
            } catch {
                await MainActor.run {
                    validationError = error.localizedDescription
                }
            }
            await MainActor.run {
                isResettingSyncData = false
            }
        }
    }
}
