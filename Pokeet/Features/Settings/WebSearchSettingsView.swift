import PokeetCore
import SwiftUI

/// Web search settings: one switch, a provider list, and whichever credential
/// the selected provider needs. The provider list comes from
/// `WebSearchProviderKind.allCases`, so a new backend shows up here for free.
struct WebSearchSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var credential = ""
    @State private var isTesting = false
    @State private var testOutcome: TestOutcome?

    private enum TestOutcome: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var settings = environment.settings
        let kind = settings.webSearchProviderKind

        Form {
            Section {
                Toggle("Enable web search", isOn: $settings.webSearchEnabled)
            } footer: {
                Text("Lets the agent look up pages it has not seen. Queries leave the device and go straight to the provider below; nothing passes through Pokeet.")
            }

            Section {
                ProviderPicker(
                    selection: Binding(
                        get: { settings.webSearchProviderKind },
                        set: { settings.setWebSearchProvider($0) }
                    )
                )
            } header: {
                Text("Provider")
            } footer: {
                Text(kind.summary)
            }

            Section {
                if kind.credentialIsSecret {
                    SecretField(title: kind.credentialLabel, text: $credential)
                } else {
                    TextField(kind.credentialLabel, text: $credential)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let url = kind.dashboardURL {
                    Link(destination: url) {
                        Label("Get an API key from \(kind.displayName)", systemImage: "arrow.up.right.square")
                    }
                    .font(.callout)
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text(kind.credentialFooter)
            }

            Section {
                Button {
                    Task { await runTest(kind) }
                } label: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isTesting ? "Searching…" : "Test search")
                    }
                }
                .disabled(isTesting || credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                switch testOutcome {
                case .success(let message):
                    Label(message, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case nil:
                    EmptyView()
                }
            } footer: {
                Text("Runs one query with the credentials above and shows the first hit. It uses your quota, so it is not free.")
            }
        }
        .navigationTitle("Web Search")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            credential = settings.webSearchCredential(for: settings.webSearchProviderKind)
        }
        .onChange(of: settings.webSearchProviderID) { _, _ in
            testOutcome = nil
            credential = settings.webSearchCredential(for: settings.webSearchProviderKind)
        }
        .onChange(of: credential) { _, newValue in
            settings.setWebSearchCredential(newValue, for: settings.webSearchProviderKind)
        }
    }

    private func runTest(_ kind: WebSearchProviderKind) async {
        guard !isTesting else { return }
        isTesting = true
        testOutcome = nil
        defer { isTesting = false }

        let provider = environment.settings.makeWebSearchProvider(for: kind)
        do {
            let results = try await provider.search(query: "swiftui list diffing", limit: 3)
            guard let first = results.first else {
                testOutcome = .failure("The provider answered, but returned no results.")
                return
            }
            testOutcome = .success("\(results.count) results. First: \(first.title)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            testOutcome = .failure(message)
        }
    }
}
