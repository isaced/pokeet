import PokeetCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = environment.settings

        NavigationStack {
            Form {
                activeModelSection(settings)

                Section {
                    Picker("Default mode", selection: $settings.defaultAgentMode) {
                        ForEach(AgentMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                } header: {
                    Text("Agent")
                } footer: {
                    Text("New sessions start in this mode. You can change the mode from any chat.")
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
                    NavigationLink {
                        ProvidersView()
                    } label: {
                        Label("Manage providers", systemImage: "server.rack")
                            .badge("\(settings.providers.count)")
                    }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("API keys are stored per provider in the iOS Keychain.")
                }

                Section {
                    SecureField("Personal access token", text: $settings.gitToken)
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

    @ViewBuilder
    private func activeModelSection(_ settings: AppSettings) -> some View {
        Section {
            if let provider = settings.activeProvider {
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { settings.activeProviderID ?? provider.id },
                        set: { settings.setActiveProvider($0) }
                    )
                ) {
                    ForEach(settings.enabledProviders) { item in
                        Text(item.name).tag(item.id)
                    }
                }

                if provider.selectedModels.isEmpty {
                    Label("No models selected for this provider.", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "Model",
                        selection: Binding(
                            get: { provider.effectiveModelID ?? "" },
                            set: { settings.setDefaultModel($0, for: provider.id) }
                        )
                    ) {
                        ForEach(provider.selectedModels) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                }

                LabeledContent("API format", value: provider.wireProtocol.displayName)

                if !settings.isModelConfigured {
                    Label("Add a valid base URL, model and API key.", systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Add a provider to get started.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Active model")
        }
    }
}
