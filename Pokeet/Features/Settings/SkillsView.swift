import PokeetCore
import SwiftUI
import UniformTypeIdentifiers

/// What is loaded right now, and the only place a global skill can be added or removed.
/// Project skills are listed read-only: a repository is the one thing that should edit them.
struct SkillsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var isPickingFiles = false
    @State private var isImportingFromRepository = false
    @State private var pending: PendingImport?
    @State private var collision: PendingImport?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if !environment.skills.globalIssues.isEmpty {
                Section {
                    ForEach(environment.skills.globalIssues) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.message)
                            Text(issue.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Problems")
                } footer: {
                    Text("These files were skipped. Fix the frontmatter in a project, or import the skill again here.")
                }
            }

            Section {
                if environment.skills.global.isEmpty {
                    Text("No skills yet. Import a folder with a SKILL.md, or add one under .agents/skills/ in a project.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(environment.skills.global.skills) { skill in
                        NavigationLink {
                            SkillDetailView(skill: skill, catalog: environment.skills.global)
                        } label: {
                            SkillRow(skill: skill)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                Task { await delete(skill) }
                            }
                        }
                    }
                }
            } header: {
                Text("This app")
            } footer: {
                Text("Shared by every project. \(environment.skills.global.skills.count) loaded.")
            }

            ForEach(environment.skills.projects) { entry in
                if !entry.catalog.skills.isEmpty {
                    Section {
                        ForEach(entry.catalog.skills) { skill in
                            NavigationLink {
                                SkillDetailView(skill: skill, catalog: entry.catalog)
                            } label: {
                                SkillRow(skill: skill)
                            }
                        }
                    } header: {
                        Text(entry.project.name)
                    } footer: {
                        Text("From the repository. Pokeet will not change these; edit them in the project.")
                    }
                }
            }
        }
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isPickingFiles = true
                    } label: {
                        Label("Import from Files…", systemImage: "folder")
                    }
                    Button {
                        isImportingFromRepository = true
                    } label: {
                        Label("Import from Repository…", systemImage: "globe")
                    }
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .disabled(isWorking)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Reload") {
                    Task { await environment.skills.refresh() }
                }
            }
        }
        .task {
            await environment.skills.refresh()
        }
        .fileImporter(
            isPresented: $isPickingFiles,
            allowedContentTypes: [.folder, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await prepareImport(from: url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $isImportingFromRepository) {
            SkillRepositorySheet {
                environment.reloadSkillsInOpenChats()
            }
        }
        .sheet(item: $pending) { item in
            SkillImportPreview(
                inspection: item.inspection,
                isWorking: isWorking,
                onImport: { Task { await importSkill(item, replacing: nil) } }
            )
        }
        .alert(
            "Replace skill?",
            isPresented: Binding(
                get: { collision != nil },
                set: { if !$0 { collision = nil } }
            )
        ) {
            if let collision {
                Button("Replace", role: .destructive) {
                    let item = collision
                    self.collision = nil
                    Task { await importSkill(item, replacing: item.name) }
                }
            }
            Button("Cancel", role: .cancel) { collision = nil }
        } message: {
            Text("There is already a skill named \"\(collision?.name ?? "")\". Replacing it swaps the whole folder.")
        }
        .alert(
            "Skill not imported",
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

    // MARK: - Actions

    private func prepareImport(from url: URL) async {
        let inspection = await environment.skills.preview(of: url)
        guard let skill = inspection.skill else {
            errorMessage = inspection.issues.first?.message ?? "That folder is not a usable skill."
            return
        }

        let item = PendingImport(url: url, name: skill.name, inspection: inspection)
        if environment.skills.global.skill(named: skill.name) != nil {
            collision = item
        } else {
            pending = item
        }
    }

    private func importSkill(_ item: PendingImport, replacing: String?) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await environment.skills.importSkill(from: item.url, replacing: replacing)
            pending = nil
            environment.reloadSkillsInOpenChats()
        } catch {
            pending = nil
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ skill: Skill) async {
        do {
            try await environment.skills.delete(skill)
            environment.reloadSkillsInOpenChats()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    struct PendingImport: Identifiable {
        let url: URL
        let name: String
        let inspection: SkillCatalog.Inspection

        var id: URL { url }
    }
}

private struct SkillRow: View {
    let skill: Skill

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(skill.name)
                if skill.disablesModelInvocation {
                    Image(systemName: "hand.raised")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Only loads when asked for")
                }
            }
            Text(skill.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct SkillImportPreview: View {
    let inspection: SkillCatalog.Inspection
    let isWorking: Bool
    let onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let skill = inspection.skill {
                    Section {
                        LabeledContent("Name", value: skill.name)
                        Text(skill.description)
                    } header: {
                        Text("Skill")
                    }

                    if !inspection.issues.isEmpty {
                        Section("Warnings") {
                            ForEach(inspection.issues) { issue in
                                Text(issue.message)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Section {
                        Text("This text becomes instructions the agent follows. Read it if you did not write it.")
                            .font(.callout)
                    }
                } else {
                    Section("Cannot import this") {
                        ForEach(inspection.issues) { issue in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.message)
                                Text(issue.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onImport)
                        .disabled(inspection.skill == nil || isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Read-only by design: a global `SKILL.md` lives outside the workspace sandbox, so the
/// editor cannot reach it without handing `SkillsStore` a write path.
private struct SkillDetailView: View {
    let skill: Skill
    let catalog: SkillCatalog

    var body: some View {
        List {
            Section {
                Text(skill.description)
            } header: {
                Text("When it applies")
            }

            Section {
                if let body = try? catalog.read(skill.location, maxBytes: 100_000) {
                    Text(body)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("Could not read this skill file.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(skill.location)
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
