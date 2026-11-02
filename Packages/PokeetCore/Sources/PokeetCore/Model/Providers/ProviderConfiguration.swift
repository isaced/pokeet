import Foundation

public enum WireProtocol: String, Codable, Sendable, CaseIterable, Identifiable {
    case openAIChatCompletions
    case openAIResponses
    case anthropicMessages
    case geminiGenerateContent

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAIChatCompletions:
            "OpenAI Chat Completions"
        case .openAIResponses:
            "OpenAI Responses"
        case .anthropicMessages:
            "Anthropic Messages"
        case .geminiGenerateContent:
            "Gemini generateContent"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAIChatCompletions, .openAIResponses:
            "https://api.openai.com/v1"
        case .anthropicMessages:
            "https://api.anthropic.com/v1"
        case .geminiGenerateContent:
            "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    public var defaultModelID: String {
        switch self {
        case .openAIChatCompletions, .openAIResponses:
            "gpt-4.1-mini"
        case .anthropicMessages:
            "claude-sonnet-4-5"
        case .geminiGenerateContent:
            "gemini-2.5-flash"
        }
    }
}

public struct ProviderModel: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var displayName: String?
    public var contextWindow: Int?
    public var isCustom: Bool

    public init(
        id: String,
        displayName: String? = nil,
        contextWindow: Int? = nil,
        isCustom: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.isCustom = isCustom
    }

    public var label: String {
        displayName?.isEmpty == false ? displayName! : id
    }
}

public struct ProviderConfiguration: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var iconName: String
    public var isEnabled: Bool
    public var wireProtocol: WireProtocol
    public var baseURL: String
    public var models: [ProviderModel]
    public var selectedModelIDs: [String]
    public var defaultModelID: String
    public var maxOutputTokens: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        iconName: String = "server.rack",
        isEnabled: Bool = true,
        wireProtocol: WireProtocol,
        baseURL: String,
        models: [ProviderModel] = [],
        selectedModelIDs: [String] = [],
        defaultModelID: String = "",
        maxOutputTokens: Int = 8192,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.isEnabled = isEnabled
        self.wireProtocol = wireProtocol
        self.baseURL = baseURL
        self.models = models
        self.selectedModelIDs = selectedModelIDs
        self.defaultModelID = defaultModelID
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.createdAt = createdAt
    }

    public var selectedModels: [ProviderModel] {
        let selected = Set(selectedModelIDs)
        return models.filter { selected.contains($0.id) }
    }

    public var effectiveModelID: String? {
        if selectedModelIDs.contains(defaultModelID), !defaultModelID.isEmpty {
            return defaultModelID
        }
        return selectedModelIDs.first
    }

    public var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isConfigured(apiKey: String) -> Bool {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              effectiveModelID?.isEmpty == false,
              let url = URL(string: trimmedBaseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else { return false }
        return true
    }

    public mutating func mergeModels(_ fetched: [ProviderModel]) {
        var indexByID = Dictionary(
            uniqueKeysWithValues: models.enumerated().map { ($0.element.id, $0.offset) }
        )

        for model in fetched where !model.id.isEmpty {
            if let index = indexByID[model.id] {
                var existing = models[index]
                if existing.displayName?.isEmpty != false, let name = model.displayName {
                    existing.displayName = name
                }
                if existing.contextWindow == nil {
                    existing.contextWindow = model.contextWindow
                }
                models[index] = existing
            } else {
                models.append(model)
                indexByID[model.id] = models.count - 1
            }
        }

        models.sort {
            if $0.isCustom != $1.isCustom {
                return !$0.isCustom
            }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }

        if selectedModelIDs.isEmpty, let first = models.first {
            selectedModelIDs = [first.id]
            defaultModelID = first.id
        } else if !selectedModelIDs.contains(defaultModelID),
                  let first = selectedModelIDs.first {
            defaultModelID = first
        }
    }

    public mutating func addCustomModel(id rawID: String) -> String? {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if !models.contains(where: { $0.id == id }) {
            models.append(ProviderModel(id: id, isCustom: true))
        }
        if !selectedModelIDs.contains(id) {
            selectedModelIDs.append(id)
        }
        if defaultModelID.isEmpty {
            defaultModelID = id
        }
        return id
    }
}
