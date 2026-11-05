import PokeetCore
import SwiftUI

/// Paste a repository, look at what is inside, pick. The terminal equivalent is
/// `skills add owner/repo --skill name`; here the `--skill` flag is the list.
struct SkillRepositorySheet: View {
    let onImported: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @State private var isFetching = false
    @State private var progress: Double = 0
    @State private var repository: RemoteSkillRepository?
    @State private var selected: Set<String> = []
    @State private var errorMessage: String?
    @State private var isImporting = false
    @State private var fetchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("vercel-labs/skills", text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .disabled(isFetching || isImporting)
                        .onSubmit { fetch() }

                    if isFetching {
                        HStack(spacing: 10) {
                            ProgressView(value: progress)
                            Button("Cancel") { cancelFetch() }
                                .buttonStyle(.borderless)
                        }
                    } else {
                        Button(repository == nil ? "Fetch" : "Fetch Again") { fetch() }
                            .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Repository")
                } footer: {
                    Text("Paste owner/repo, a repository URL, or a link to the skill folder (…/tree/main/skills/find-skills). Private repositories use the token in Settings → Git, and network access follows Settings → Network.")
                }

                if let repository {
                    Section {
                        if repository.skills.isEmpty {
                            Text("No skills found in this repository.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(repository.skills) { skill in
                                Button {
                                    toggle(skill)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: selected.contains(skill.name)
                                            ? "checkmark.circle.fill"
                                            : "circle")
                                            .foregroundStyle(selected.contains(skill.name) ? Color.accentColor : Color.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(skill.name)
                                                .foregroundStyle(.primary)
                                            Text(skill.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                            Text(skill.location)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("\(repository.skills.count) skills found")
                    } footer: {
                        Text(provenanceLine(for: repository))
                    }

                    if !repository.issues.isEmpty {
                        Section("Skipped") {
                            ForEach(repository.issues) { issue in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.message)
                                    Text(issue.path)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import from Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelFetch()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import \(selected.count)") {
                        Task { await importSelection() }
                    }
                    .disabled(selected.isEmpty || isImporting)
                }
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onDisappear {
            cancelFetch()
            repository?.remove()
        }
    }

    // MARK: - Actions

    private func fetch() {
        guard !isFetching else { return }
        errorMessage = nil
        repository?.remove()
        repository = nil
        selected = []
        progress = 0
        isFetching = true

        let target = link
        let skills = environment.skills
        fetchTask = Task {
            do {
                let fetched = try await skills.fetchRepository(target) { value in
                    Task { @MainActor in progress = value }
                }
                await MainActor.run {
                    repository = fetched
                    selected = Set(fetched.suggested.map(\.name))
                    isFetching = false
                }
            } catch {
                await MainActor.run {
                    isFetching = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func cancelFetch() {
        fetchTask?.cancel()
        fetchTask = nil
        isFetching = false
    }

    private func toggle(_ skill: Skill) {
        if selected.contains(skill.name) {
            selected.remove(skill.name)
        } else {
            selected.insert(skill.name)
        }
    }

    private func importSelection() async {
        guard let repository else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            try await environment.skills.importSkills(
                from: repository,
                names: Array(selected)
            )
            onImported()
            repository.remove()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func provenanceLine(for repository: RemoteSkillRepository) -> String {
        var parts = [repository.source.url.absoluteString]
        if let ref = repository.source.ref { parts.append("ref \(ref)") }
        if let commit = repository.commit { parts.append(String(commit.prefix(7))) }
        return parts.joined(separator: " · ")
    }
}
