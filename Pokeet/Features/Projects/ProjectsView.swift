import SwiftUI

struct ProjectsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingNewProject = false
    @State private var isShowingSettings = false
    @State private var pendingDelete: Project?
    @State private var deletionError: String?

    var body: some View {
        List {
            if !environment.settings.isModelConfigured && !MockModelSupport.isEnabled {
                Section {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Add a model API key to start", systemImage: "key")
                    }
                }
            }

            ForEach(environment.projects.projects) { project in
                NavigationLink(value: project) {
                    ProjectRow(project: project)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        pendingDelete = project
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button(role: .destructive) {
                        pendingDelete = project
                    } label: {
                        Label("Delete Project", systemImage: "trash")
                    }
                }
            }
        }
        .overlay {
            if environment.projects.projects.isEmpty && !environment.projects.isLoading {
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "folder.badge.plus")
                } description: {
                    Text("Create a project, optionally from a Git repository.")
                } actions: {
                    Button("New project") {
                        isShowingNewProject = true
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
            }
        }
        .navigationTitle("Pokeet")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingNewProject = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingNewProject) {
            NewProjectSheet()
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .confirmationDialog(
            "Delete project?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { project in
            Button("Delete \(project.name)", role: .destructive) {
                Task { await delete(project) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text(
                "This permanently deletes the project folder, including local files, "
                    + "and all conversations from this device."
            )
        }
        .alert(
            "Couldn't delete project",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionError ?? "")
        }
        .task {
            await environment.projects.refresh()
        }
        .navigationDestination(for: Project.self) { project in
            ProjectSessionsView(
                project: project,
                store: environment.sessions
            )
        }
    }

    @MainActor
    private func delete(_ project: Project) async {
        pendingDelete = nil
        do {
            try await environment.projects.delete(project)
            await environment.sessions.deleteProject(projectName: project.name)
        } catch {
            deletionError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
