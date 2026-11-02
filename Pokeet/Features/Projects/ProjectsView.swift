import SwiftUI

struct ProjectsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isShowingNewProject = false
    @State private var isShowingSettings = false

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
}
