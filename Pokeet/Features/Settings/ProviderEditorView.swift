import PokeetCore
import SwiftUI

struct ProviderEditorView: View {
    let isNew: Bool

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProviderConfiguration
    @State private var apiKey = ""
    @State private var didLoadKey = false
    @State private var showsAdvanced = false
    @State private var validationError: String?

    private let iconOptions = [
        "brain.head.profile", "text.bubble", "sparkle", "server.rack",
        "cloud", "bolt", "cpu", "globe", "circle.hexagongrid"
    ]

    init(provider: ProviderConfiguration, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: provider)
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                connectionSection
                modelsSection
                advancedSection

                if let validationError {
                    Section {
                        Label(validationError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(isNew ? "New Provider" : "Edit Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") { save() }
                }
            }
            .onAppear {
                guard !didLoadKey else { return }
                didLoadKey = true
                apiKey = environment.settings.apiKey(for: draft.id)
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $draft.name)
                .textInputAutocapitalization(.words)

            LabeledContent("Icon") {
                Menu {
                    ForEach(iconOptions, id: \.self) { icon in
                        Button {
                            draft.iconName = icon
                        } label: {
                            Label(icon, systemImage: icon)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: draft.iconName)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Toggle("Enabled", isOn: $draft.isEnabled)
        }
    }

    private var connectionSection: some View {
        Section {
            Picker("API format", selection: $draft.wireProtocol) {
                ForEach(WireProtocol.allCases) { wireProtocol in
                    Text(wireProtocol.displayName).tag(wireProtocol)
                }
            }
            .onChange(of: draft.wireProtocol) { oldValue, newValue in
                if draft.baseURL.isEmpty || draft.baseURL == oldValue.defaultBaseURL {
                    draft.baseURL = newValue.defaultBaseURL
                }
            }

            TextField("Base URL", text: $draft.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            SecretField(title: "API key", text: $apiKey)
        } header: {
            Text("Connection")
        } footer: {
            Text("The key is stored in the iOS Keychain and scoped to this provider.")
        }
    }

    private var modelsSection: some View {
        Section {
            NavigationLink {
                ModelSelectionView(draft: $draft, apiKey: apiKey)
            } label: {
                LabeledContent(
                    "Models",
                    value: "\(draft.selectedModelIDs.count) selected"
                )
            }

            LabeledContent(
                "Default",
                value: draft.models.first(where: { $0.id == draft.defaultModelID })?.label
                    ?? "Not set"
            )
        } header: {
            Text("Models")
        } footer: {
            Text("Fetch the provider model list, then choose which IDs are available in chat.")
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                TextField(
                    "Max output tokens",
                    value: $draft.maxOutputTokens,
                    format: .number
                )
                .keyboardType(.numberPad)

                Button("Reset base URL") {
                    draft.baseURL = draft.wireProtocol.defaultBaseURL
                }
            }
        }
    }

    private func save() {
        validationError = nil
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            validationError = "Enter a provider name."
            return
        }
        draft.name = name

        guard let url = URL(string: draft.trimmedBaseURL),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host != nil
        else {
            validationError = "Enter a valid HTTP or HTTPS base URL."
            return
        }

        guard !draft.selectedModelIDs.isEmpty else {
            validationError = "Select at least one model."
            return
        }

        environment.settings.saveProvider(
            draft,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}
