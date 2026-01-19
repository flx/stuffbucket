import SwiftUI
import StuffBucketCore

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

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                providerSection
                apiKeySection
                modelSection
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
            .frame(width: 450, height: 280)
            #endif
            .onAppear {
                claudeKey = keyStorage.claudeAPIKey ?? ""
                openAIKey = keyStorage.openAIAPIKey ?? ""
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
                get: { keyStorage.selectedModelID ?? defaultModelID },
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

    private var defaultModelID: String {
        switch keyStorage.selectedProvider {
        case .anthropic:
            return AnthropicModelDefaults.defaultModelID
        case .openAI:
            return OpenAIModelDefaults.defaultModelID
        }
    }

    private func saveClaudeKey() {
        guard !claudeKey.isEmpty else { return }
        isValidatingClaude = true

        Task {
            do {
                let client = AnthropicClient(apiKey: claudeKey)
                let models = try await client.validateAPIKey()
                await MainActor.run {
                    keyStorage.setClaudeAPIKey(claudeKey)
                    if !models.isEmpty {
                        claudeModels = models
                    }
                    if keyStorage.selectedModelID == nil {
                        keyStorage.setSelectedModelID(AnthropicModelDefaults.defaultModelID)
                    }
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

        Task {
            do {
                let client = OpenAIClient(apiKey: openAIKey)
                let allModels = try await client.validateAPIKey()
                await MainActor.run {
                    keyStorage.setOpenAIAPIKey(openAIKey)
                    // Filter to chat models only
                    let chatModels = allModels.filter { model in
                        model.hasPrefix("gpt-4") || model.hasPrefix("gpt-3.5")
                    }
                    if !chatModels.isEmpty {
                        openAIModels = chatModels
                    }
                    if keyStorage.selectedModelID == nil {
                        keyStorage.setSelectedModelID(OpenAIModelDefaults.defaultModelID)
                    }
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
}
