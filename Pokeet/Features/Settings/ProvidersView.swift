import PokeetCore
import SwiftUI

struct ProvidersView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var editing: ProviderConfiguration?
    @State private var pendingDelete: ProviderConfiguration?

    var body: some View {
        List {
            ForEach(environment.settings.providers) { provider in
                HStack(spacing: 10) {
                    NavigationLink {
                        ProviderEditorView(
                            provider: provider,
                            isNew: false
                        )
                    } label: {
                        ProviderRow(
                            provider: provider,
                            isActive: environment.settings.activeProviderID == provider.id
                        )
                    }

                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { provider.isEnabled },
                            set: { environment.settings.setEnabled($0, for: provider.id) }
                        )
                    )
                    .labelsHidden()
                    .accessibilityLabel("Enable \(provider.name)")
                }
                .swipeActions {
                    Button(role: .destructive) {
                        pendingDelete = provider
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Providers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Add provider") {
                        ForEach(ProviderTemplates.all) { template in
                            Button {
                                editing = ProviderTemplates.configuration(from: template)
                            } label: {
                                Label(template.name, systemImage: template.iconName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if environment.settings.providers.isEmpty {
                ContentUnavailableView(
                    "No providers",
                    systemImage: "server.rack",
                    description: Text("Add a provider to configure a model.")
                )
            }
        }
        .sheet(item: $editing) { provider in
            ProviderEditorView(
                provider: provider,
                isNew: environment.settings.provider(id: provider.id) == nil
            )
        }
        .confirmationDialog(
            "Delete provider?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { provider in
            Button("Delete \(provider.name)", role: .destructive) {
                environment.settings.deleteProvider(id: provider.id)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { provider in
            Text("The API key for \(provider.name) will also be removed.")
        }
    }
}

private struct ProviderRow: View {
    let provider: ProviderConfiguration
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: provider.iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(provider.name)
                        .font(.headline)
                    if isActive {
                        Text("ACTIVE")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(provider.wireProtocol.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(provider.effectiveModelID ?? "No model selected")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .opacity(provider.isEnabled ? 1 : 0.55)
    }
}
