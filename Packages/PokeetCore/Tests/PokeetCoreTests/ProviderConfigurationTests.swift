import Foundation
import Testing
@testable import PokeetCore

struct ProviderConfigurationTests {
    @Test func seedsFourProviderTemplates() {
        let providers = ProviderTemplates.seededProviders

        #expect(providers.count == 4)
        #expect(Set(providers.map(\.wireProtocol)) == Set(WireProtocol.allCases))
        #expect(providers.map(\.name) == ["OpenAI", "Anthropic", "Gemini", "OpenAI Compatible"])
        #expect(providers.allSatisfy { $0.isEnabled })

        let openAI = providers[0]
        #expect(openAI.wireProtocol == .openAIResponses)
        #expect(openAI.effectiveModelID == "gpt-4.1-mini")
        #expect(openAI.selectedModelIDs.count == 3)
    }

    @Test func effectiveModelFallsBackToFirstSelected() {
        var provider = ProviderConfiguration(
            name: "Test",
            wireProtocol: .openAIChatCompletions,
            baseURL: "https://example.com/v1",
            selectedModelIDs: ["one", "two"],
            defaultModelID: "missing"
        )

        #expect(provider.effectiveModelID == "one")
        provider.defaultModelID = "two"
        #expect(provider.effectiveModelID == "two")
    }

    @Test func mergesFetchedModelsWithoutDroppingCustomOnes() {
        var provider = ProviderConfiguration(
            name: "Test",
            wireProtocol: .openAIChatCompletions,
            baseURL: "https://example.com/v1",
            models: [
                ProviderModel(id: "custom", isCustom: true),
                ProviderModel(id: "shared")
            ],
            selectedModelIDs: [],
            defaultModelID: ""
        )

        provider.mergeModels([
            ProviderModel(id: "shared", displayName: "Shared", contextWindow: 128_000),
            ProviderModel(id: "new", displayName: "New")
        ])

        #expect(provider.models.map(\.id) == ["new", "shared", "custom"])
        #expect(provider.models.first(where: { $0.id == "shared" })?.displayName == "Shared")
        #expect(provider.models.first(where: { $0.id == "shared" })?.contextWindow == 128_000)
        #expect(provider.selectedModelIDs == ["new"])
        #expect(provider.defaultModelID == "new")
    }

    @Test func addsCustomModelAndSelectsIt() {
        var provider = ProviderConfiguration(
            name: "Test",
            wireProtocol: .openAIResponses,
            baseURL: "https://example.com/v1"
        )

        let id = provider.addCustomModel(id: " my-model ")

        #expect(id == "my-model")
        #expect(provider.models == [ProviderModel(id: "my-model", isCustom: true)])
        #expect(provider.selectedModelIDs == ["my-model"])
        #expect(provider.defaultModelID == "my-model")
    }

    @Test func configurationRequiresKeyModelAndValidURL() {
        var provider = ProviderConfiguration(
            name: "Test",
            wireProtocol: .openAIResponses,
            baseURL: "https://example.com/v1",
            selectedModelIDs: ["model"],
            defaultModelID: "model"
        )

        #expect(provider.isConfigured(apiKey: "key"))
        #expect(!provider.isConfigured(apiKey: " "))

        provider.baseURL = "not a url"
        #expect(!provider.isConfigured(apiKey: "key"))
    }

    @Test func factorySelectsClientForEachProtocol() throws {
        for wireProtocol in WireProtocol.allCases {
            let provider = ProviderConfiguration(
                name: "Test",
                wireProtocol: wireProtocol,
                baseURL: wireProtocol.defaultBaseURL,
                selectedModelIDs: ["model"],
                defaultModelID: "model"
            )
            let client = try LLMClientFactory.makeClient(
                provider: provider,
                apiKey: "key"
            )

            switch wireProtocol {
            case .openAIChatCompletions:
                #expect(client is OpenAIChatClient)
            case .openAIResponses:
                #expect(client is OpenAIResponsesClient)
            case .anthropicMessages:
                #expect(client is AnthropicMessagesClient)
            case .geminiGenerateContent:
                #expect(client is GeminiGenerateContentClient)
            }
        }
    }

    @Test func factoryRejectsIncompleteConfiguration() {
        let provider = ProviderConfiguration(
            name: "Test",
            wireProtocol: .openAIResponses,
            baseURL: "https://example.com/v1",
            selectedModelIDs: ["model"],
            defaultModelID: "model"
        )

        #expect(throws: ModelError.notConfigured) {
            try LLMClientFactory.makeClient(provider: provider, apiKey: "")
        }

        var missingModel = provider
        missingModel.selectedModelIDs = []
        missingModel.defaultModelID = ""
        #expect(throws: ModelError.notConfigured) {
            try LLMClientFactory.makeClient(provider: missingModel, apiKey: "key")
        }
    }

    @Test func codableRoundtrip() throws {
        let provider = ProviderTemplates.seededProviders[2]
        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: data)

        #expect(decoded == provider)
    }
}
