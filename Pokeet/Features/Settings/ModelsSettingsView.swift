import PokeetCore
import SwiftUI

/// Everything about "which model answers": the active provider and model, and
/// the provider list itself. Kept out of the root Settings form so that screen
/// stays a short index.
struct ModelsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        @Bindable var settings = environment.settings

        Form {
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
            } footer: {
                Text("New chats start with this provider and model. You can switch model from any chat.")
            }

            Section {
                NavigationLink {
                    ProvidersView()
                } label: {
                    LabeledContent {
                        Text("\(settings.providers.count)")
                    } label: {
                        Label("Manage providers", systemImage: "server.rack")
                    }
                }
            } header: {
                Text("Providers")
            } footer: {
                Text("API keys are stored per provider in the iOS Keychain.")
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}
