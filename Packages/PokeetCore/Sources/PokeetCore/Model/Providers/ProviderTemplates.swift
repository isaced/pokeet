import Foundation

public struct ProviderTemplate: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let iconName: String
    public let wireProtocol: WireProtocol
    public let baseURL: String
    public let models: [ProviderModel]

    public init(
        id: String,
        name: String,
        iconName: String,
        wireProtocol: WireProtocol,
        baseURL: String,
        models: [ProviderModel]
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.wireProtocol = wireProtocol
        self.baseURL = baseURL
        self.models = models
    }
}

public enum ProviderTemplates {
    public static let all: [ProviderTemplate] = [
        ProviderTemplate(
            id: "openai",
            name: "OpenAI",
            iconName: "brain.head.profile",
            wireProtocol: .openAIResponses,
            baseURL: WireProtocol.openAIResponses.defaultBaseURL,
            models: [
                ProviderModel(id: "gpt-4.1-mini"),
                ProviderModel(id: "gpt-4.1"),
                ProviderModel(id: "o4-mini")
            ]
        ),
        ProviderTemplate(
            id: "anthropic",
            name: "Anthropic",
            iconName: "text.bubble",
            wireProtocol: .anthropicMessages,
            baseURL: WireProtocol.anthropicMessages.defaultBaseURL,
            models: [
                ProviderModel(id: "claude-sonnet-4-5"),
                ProviderModel(id: "claude-haiku-4-5"),
                ProviderModel(id: "claude-opus-4-1")
            ]
        ),
        ProviderTemplate(
            id: "gemini",
            name: "Gemini",
            iconName: "sparkle",
            wireProtocol: .geminiGenerateContent,
            baseURL: WireProtocol.geminiGenerateContent.defaultBaseURL,
            models: [
                ProviderModel(id: "gemini-2.5-flash"),
                ProviderModel(id: "gemini-2.5-pro")
            ]
        ),
        ProviderTemplate(
            id: "compatible",
            name: "OpenAI Compatible",
            iconName: "server.rack",
            wireProtocol: .openAIChatCompletions,
            baseURL: "",
            models: []
        )
    ]

    public static func configuration(
        from template: ProviderTemplate,
        id: UUID = UUID(),
        now: Date = Date()
    ) -> ProviderConfiguration {
        let selected = template.models.map(\.id)
        return ProviderConfiguration(
            id: id,
            name: template.name,
            iconName: template.iconName,
            wireProtocol: template.wireProtocol,
            baseURL: template.baseURL,
            models: template.models,
            selectedModelIDs: selected,
            defaultModelID: selected.first ?? "",
            createdAt: now
        )
    }

    public static var seededProviders: [ProviderConfiguration] {
        all.map { configuration(from: $0) }
    }
}
