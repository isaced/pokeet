import SwiftUI

struct SplitRootView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var selectedProjectID: Project.ID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isShowingNewProject = false
    @State private var isShowingSettings = false

    private var selectedProject: Project? {
        environment.projects.projects.first { $0.id == selectedProjectID }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            NavigationStack {
                if let project = selectedProject {
                    ChatView(
                        project: project,
                        environment: environment,
                        onToggleSidebar: { toggleSidebar() }
                    )
                    .id(project.id)
                } else {
                    ContentUnavailableView(
                        "Select a project",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Choose a project on the left, or create a new one.")
                    )
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await environment.projects.refresh()
        }
        .onChange(of: environment.projects.projects) { _, projects in
            if let selectedProjectID,
               projects.contains(where: { $0.id == selectedProjectID }) {
                return
            }
            selectedProjectID = projects.first?.id
        }
    }

    private var sidebar: some View {
        List(selection: $selectedProjectID) {
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
                ProjectRow(project: project)
                    .tag(project.id)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 400)
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
            NewProjectSheet { project in
                selectedProjectID = project.id
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }

    private func toggleSidebar() {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
    }
}
