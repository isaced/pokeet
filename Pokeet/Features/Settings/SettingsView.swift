import PokeetCore
import SwiftUI

/// The root Settings form is an index: one row per topic, details live one
/// level down. Model configuration and web search used to be inline here and
/// crowded out everything else.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = environment.settings

        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ModelsSettingsView()
                    } label: {
                        LabeledContent {
                            Text(modelSummary(settings))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } label: {
                            Label("Model", systemImage: "brain.head.profile")
                        }
                    }

                    Picker("Default mode", selection: $settings.defaultAgentMode) {
                        ForEach(AgentMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("The model that answers new chats, and the mode they start in. Both can be changed from any chat.")
                }

                Section {
                    NavigationLink {
                        WebSearchSettingsView()
                    } label: {
                        LabeledContent {
                            Text(webSearchSummary(settings))
                                .foregroundStyle(webSearchNeedsAttention(settings) ? .orange : .secondary)
                        } label: {
                            Label("Web Search", systemImage: "magnifyingglass")
                        }
                    }
                } header: {
                    Text("Tools")
                } footer: {
                    Text("A search backend the agent can query. Search results are snippets; pages are read with the guarded fetch tool.")
                }

                Section {
                    Toggle("Allow network access", isOn: $settings.networkEnabled)
                    TextField(
                        "Allowed hosts",
                        text: $settings.networkAllowedHosts,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } header: {
                    Text("Network")
                } footer: {
                    Text("Comma or newline separated. Leave empty to allow any public HTTPS host. Local and private addresses stay blocked.")
                }

                Section {
                    SecretField(title: "Personal access token", text: $settings.gitToken)
                    TextField("Author name", text: $settings.authorName)
                    TextField("Author email", text: $settings.authorEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Git")
                } footer: {
                    Text("Git operations use HTTPS with a personal access token. SSH is not supported yet.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func modelSummary(_ settings: AppSettings) -> String {
        guard let provider = settings.activeProvider else { return "Not configured" }
        guard let model = provider.effectiveModelID else { return provider.name }
        return "\(provider.name) · \(model)"
    }

    private func webSearchSummary(_ settings: AppSettings) -> String {
        guard settings.webSearchEnabled else { return "Off" }
        guard settings.isWebSearchConfigured else { return "Needs key" }
        return "On · \(settings.webSearchProviderKind.displayName)"
    }

    private func webSearchNeedsAttention(_ settings: AppSettings) -> Bool {
        settings.webSearchEnabled && !settings.isWebSearchConfigured
    }
}
