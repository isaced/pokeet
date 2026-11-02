import Foundation

public enum LLMClientFactory {
    public static func makeClient(
        provider: ProviderConfiguration,
        apiKey: String,
        session: URLSession = .shared
    ) throws -> any ModelClient {
        guard provider.isConfigured(apiKey: apiKey),
              let model = provider.effectiveModelID
        else {
            throw ModelError.notConfigured
        }

        switch provider.wireProtocol {
        case .openAIChatCompletions:
            return OpenAIChatClient(
                baseURL: provider.baseURL,
                model: model,
                apiKey: apiKey,
                session: session
            )
        case .openAIResponses:
            return OpenAIResponsesClient(
                baseURL: provider.baseURL,
                model: model,
                apiKey: apiKey,
                maxOutputTokens: provider.maxOutputTokens,
                session: session
            )
        case .anthropicMessages:
            return AnthropicMessagesClient(
                baseURL: provider.baseURL,
                model: model,
                apiKey: apiKey,
                maxOutputTokens: provider.maxOutputTokens,
                session: session
            )
        case .geminiGenerateContent:
            return GeminiGenerateContentClient(
                baseURL: provider.baseURL,
                model: model,
                apiKey: apiKey,
                maxOutputTokens: provider.maxOutputTokens,
                session: session
            )
        }
    }
}
