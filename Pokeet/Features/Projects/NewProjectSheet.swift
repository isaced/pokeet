import Observation
import PokeetCore
import SwiftUI

@MainActor
@Observable
final class CreateProjectModel {
    var name = ""
    var gitURLText = ""
    var token = ""

    private(set) var isWorking = false
    private(set) var progress: Double = 0
    var errorMessage: String?

    var trimmedGitURL: String {
        gitURLText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var gitURL: URL? {
        let text = trimmedGitURL
        guard !text.isEmpty,
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil
        else { return nil }
        return components.url
    }

    var isGitURLInvalid: Bool {
        !trimmedGitURL.isEmpty && gitURL == nil
    }

    var suggestedName: String {
        if let url = gitURL {
            var name = url.lastPathComponent
            if name.hasSuffix(".git") {
                name.removeLast(4)
            }
            if !name.isEmpty {
                return name
            }
        }
        return "Project"
    }

    var effectiveName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? suggestedName : trimmed
    }

    var canCreate: Bool {
        guard !isWorking, !isGitURLInvalid else { return false }
        return gitURL != nil || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var buttonTitle: String {
        gitURL == nil ? "Create" : "Create & Clone"
    }

    func create(using environment: AppEnvironment) async -> Project? {
        guard canCreate else { return nil }

        isWorking = true
        progress = 0
        errorMessage = nil
        defer { isWorking = false }

        do {
            let destination = try environment.projects.projectDestination(named: effectiveName)

            if let remoteURL = gitURL {
                let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                try await environment.git.clone(
                    GitRemoteSpec(
                        url: remoteURL,
                        token: trimmedToken.isEmpty ? nil : trimmedToken
                    ),
                    to: destination,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            self?.progress = value
                        }
                    }
                )

                if !trimmedToken.isEmpty {
                    environment.settings.gitToken = trimmedToken
                }
                await environment.projects.refresh()

                return environment.projects.project(at: destination)
                    ?? Project(
                        directory: destination,
                        remoteHost: remoteURL.host,
                        isGitRepository: true
                    )
            }

            return try await environment.projects.createEmptyProject(at: destination)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            return nil
        }
    }
}

struct NewProjectSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var onCreated: ((Project) -> Void)?

    @State private var model = CreateProjectModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Project name", text: $model.name, prompt: Text(model.suggestedName))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Project")
                } footer: {
                    Text("Leave the name empty to use the repository name.")
                }

                Section {
                    TextField("https://github.com/org/repo.git", text: $model.gitURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    if !model.trimmedGitURL.isEmpty {
                        SecureField("Personal access token (private repos)", text: $model.token)
                    }
                } header: {
                    Text("Git repository (optional)")
                } footer: {
                    if model.isGitURLInvalid {
                        Text("Enter a valid HTTPS repository URL.")
                            .foregroundStyle(.red)
                    } else {
                        Text("Filled in? Pokeet clones it after creating the project. Leave it empty to start from an empty folder.")
                    }
                }

                if model.isWorking, model.gitURL != nil {
                    Section {
                        ProgressView(value: model.progress)
                        Text("Cloning \(Int(model.progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Creating project")
                    }
                }

                if let errorMessage = model.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.buttonTitle) { create() }
                        .disabled(!model.canCreate)
                }
            }
            .interactiveDismissDisabled(model.isWorking)
        }
        .onAppear {
            if model.token.isEmpty {
                model.token = environment.settings.gitToken
            }
        }
    }

    private func create() {
        Task {
            if let project = await model.create(using: environment) {
                onCreated?(project)
                dismiss()
            }
        }
    }
}
