import Foundation
import PokeetCore

/// The search backends the app can talk to.
///
/// This enum is the single place a provider is declared. Settings renders the
/// picker, the credential field and the help copy from the metadata below, and
/// `AppSettings` stores one credential per case, so adding a provider means:
///
/// 1. add a case,
/// 2. fill in the metadata,
/// 3. return its adapter from `makeProvider`.
///
/// No settings screen or storage key changes. Cases with a second input (an
/// instance URL instead of a key, say) still fit: the credential slot holds
/// whatever `credentialLabel` describes, and `credentialIsSecret` decides
/// whether Settings masks it.
enum WebSearchProviderKind: String, CaseIterable, Identifiable, Sendable {
    case brave
    case tavily
    case deepseek
    case exa

    var id: String { rawValue }

    /// Used when nothing is stored yet, and when a stored id is no longer known.
    static var fallback: WebSearchProviderKind { .brave }

    static func resolve(_ rawValue: String?) -> WebSearchProviderKind {
        rawValue.flatMap(WebSearchProviderKind.init(rawValue:)) ?? .fallback
    }

    /// Keychain key holding this provider's credential. Naming it after the raw
    /// value keeps existing keys valid when cases are added.
    var credentialKeyName: String {
        "secret.websearch.\(rawValue).apiKey"
    }

    var displayName: String {
        switch self {
        case .brave:
            "Brave Search"
        case .tavily:
            "Tavily"
        case .deepseek:
            "DeepSeek Search"
        case .exa:
            "Exa"
        }
    }

    /// Brand mark from the asset catalog, when one exists. The Settings row
    /// prefers it over `iconName`.
    var brandAssetName: String? {
        switch self {
        case .brave:
            "brand-brave"
        case .tavily:
            "brand-tavily"
        case .deepseek:
            "brand-deepseek"
        case .exa:
            "brand-exa"
        }
    }

    var iconName: String {
        switch self {
        case .brave:
            "shield.lefthalf.filled"
        case .tavily:
            "binoculars.fill"
        case .deepseek:
            "magnifyingglass"
        case .exa:
            "sparkles"
        }
    }

    /// One line under the provider picker: what this backend returns, and what
    /// it costs.
    var summary: String {
        switch self {
        case .brave:
            "Independent index, clean JSON results. Free tier is about 2,000 queries a month at one request per second."
        case .tavily:
            "Built for agents: cleaned snippets per page, one credit per basic search. Free tier is about 1,000 credits a month."
        case .deepseek:
            "DeepSeek's own index with operators like site:, lang: and after:. Returns a long summary per page; billed per 1,000 successful searches."
        case .exa:
            "Natural-language neural search built for agents. Returns excerpts sized to each result's relevance; pay per search."
        }
    }

    var credentialLabel: String {
        switch self {
        case .brave, .tavily, .deepseek, .exa:
            "API key"
        }
    }

    /// Whether the credential must be masked. An instance URL is not a secret.
    var credentialIsSecret: Bool {
        switch self {
        case .brave, .tavily, .deepseek, .exa:
            true
        }
    }

    var credentialFooter: String {
        switch self {
        case .brave:
            "Sent as the X-Subscription-Token header straight to api.search.brave.com. Stored in the iOS Keychain."
        case .tavily:
            "Keys start with tvly- and are sent as a Bearer token to api.tavily.com. Stored in the iOS Keychain."
        case .deepseek:
            "The same deepseek.com key your model provider uses, sent as a Bearer token to api.deepseek.com. Stored in the iOS Keychain."
        case .exa:
            "Create a key in the Exa dashboard; it is sent as a Bearer token to api.exa.ai. Stored in the iOS Keychain."
        }
    }

    /// `nil` when the provider needs no separate signup.
    var dashboardURL: URL? {
        switch self {
        case .brave:
            URL(string: "https://api-dashboard.search.brave.com/app/keys")
        case .tavily:
            URL(string: "https://app.tavily.com/home")
        case .deepseek:
            URL(string: "https://platform.deepseek.com/api_keys")
        case .exa:
            URL(string: "https://dashboard.exa.ai/api-keys")
        }
    }

    func makeProvider(secrets: any SecretStore) -> any WebSearchProviding {
        switch self {
        case .brave:
            BraveSearchProvider(secrets: secrets, keyName: credentialKeyName)
        case .tavily:
            TavilySearchProvider(secrets: secrets, keyName: credentialKeyName)
        case .deepseek:
            DeepSeekSearchProvider(secrets: secrets, keyName: credentialKeyName)
        case .exa:
            ExaSearchProvider(secrets: secrets, keyName: credentialKeyName)
        }
    }
}
