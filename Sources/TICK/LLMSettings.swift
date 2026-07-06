import Foundation

enum LLMProviderConfig {
    static let systemPrompt = "You are TICK, a concise proactive desktop agent. Always answer users in Chinese unless they explicitly request another language. Work in a loop: request a tool when it helps, use tool results, and stop once you can produce the final result."
}

struct LLMSettings: Codable, Equatable {
    var baseURL = ""
    var model = ""
}

@MainActor
final class LLMSettingsStore: ObservableObject {
    @Published var settings: LLMSettings
    @Published var apiKey: String
    @Published var availableModels: [String]
    @Published var statusMessage = ""
    @Published var isLoadingModels = false

    var onSave: (() -> Void)?

    init() {
        let initialSettings: LLMSettings
        if let savedSettings = LocalSettingsStore.read(LLMSettings.self, from: "llm-settings.json") {
            initialSettings = LLMSettingsStore.normalized(savedSettings)
        } else if let data = UserDefaults.standard.data(forKey: "tick.llm.settings"),
                  let savedSettings = try? JSONDecoder().decode(LLMSettings.self, from: data) {
            initialSettings = LLMSettingsStore.normalized(savedSettings)
        } else {
            initialSettings = LLMSettings()
        }

        settings = initialSettings
        apiKey = LocalSecretStore.readChatAPIKey() ?? ""
        availableModels = initialSettings.model.isEmpty ? [] : [initialSettings.model]
    }

    var isConfigured: Bool {
        !settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func save() {
        let normalizedSettings = LLMSettingsStore.normalized(settings)
        settings = normalizedSettings

        guard let data = try? JSONEncoder().encode(normalizedSettings) else {
            statusMessage = "Save failed"
            return
        }

        LocalSettingsStore.save(data, to: "llm-settings.json")
        LocalSecretStore.saveChatAPIKey(apiKey)
        statusMessage = isConfigured ? "Saved" : missingConfigurationMessage
        traceLog("settings.save", "baseURL=\(settings.baseURL)\nmodel=\(settings.model)\nchatKeySet=\(!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)")
        onSave?()
    }

    func loadModels() {
        let requestAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestAPIKey.isEmpty else {
            statusMessage = "API key required"
            traceLog("models.error", "API key required")
            return
        }

        let baseURL = settings.normalizedBaseURL
        guard !baseURL.isEmpty else {
            statusMessage = "Base URL required"
            traceLog("models.error", "Base URL required")
            return
        }

        isLoadingModels = true
        statusMessage = "Loading models..."

        traceLog("models.request", "GET \(baseURL)/models")
        Task {
            do {
                let models = try await LLMClient.fetchModels(baseURL: baseURL, apiKey: requestAPIKey)
                await MainActor.run {
                    self.availableModels = models
                    if !self.availableModels.contains(self.settings.model) {
                        self.settings.model = self.availableModels.first ?? self.settings.model
                    }
                    self.statusMessage = "Models loaded"
                    self.isLoadingModels = false
                    let modelSummary = self.availableModels.joined(separator: ", ")
                    traceLog("models.response", "count=\(self.availableModels.count)\nmodels=\(modelSummary)")
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.isLoadingModels = false
                    traceLog("models.error", self.statusMessage)
                }
            }
        }
    }

    var missingConfigurationMessage: String {
        if settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Base URL required"
        }
        if settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Model required"
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "API key required"
        }
        return "Ready"
    }

    private static func normalized(_ settings: LLMSettings) -> LLMSettings {
        let baseURL = normalizeBaseURL(settings.baseURL)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMSettings(baseURL: baseURL, model: model)
    }

    private static func normalizeBaseURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

extension LLMSettings {
    var normalizedBaseURL: String {
        baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum LocalSettingsStore {
    static func read<T: Decodable>(_ type: T.Type, from fileName: String) -> T? {
        let fileURL = TICKRuntime.rootURL.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save(_ data: Data, to fileName: String) {
        let fileURL = TICKRuntime.rootURL.appendingPathComponent(fileName)
        try? data.write(to: fileURL, options: [.atomic])
    }

    static func remove(_ fileName: String) {
        let fileURL = TICKRuntime.rootURL.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private enum LocalSecretStore {
    static func readChatAPIKey() -> String? {
        readSecret(named: "chat-api-key")
    }

    static func saveChatAPIKey(_ apiKey: String) {
        saveSecret(apiKey, named: "chat-api-key")
    }

    private static func readSecret(named fileName: String) -> String? {
        let fileURL = TICKRuntime.rootURL.appendingPathComponent(fileName)
        guard let key = try? String(contentsOf: fileURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    private static func saveSecret(_ value: String, named fileName: String) {
        let trimmedKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileURL = TICKRuntime.rootURL.appendingPathComponent(fileName)
        if trimmedKey.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        try? trimmedKey.write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
