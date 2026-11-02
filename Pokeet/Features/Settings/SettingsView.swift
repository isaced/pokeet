import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = environment.settings

        NavigationStack {
            Form {
                Section {
                    TextField("Base URL", text: $settings.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Model", text: $settings.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $settings.apiKey)
                } header: {
                    Text("Model")
                } footer: {
                    Text("Any OpenAI-compatible chat completions endpoint. Use localhost for a local server. The key is stored in the iOS Keychain.")
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
}
