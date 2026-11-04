import SwiftUI

struct RootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(AppEnvironment.self) private var environment
    @State private var path: [Project] = []

    private var usesSplitLayout: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    var body: some View {
        if usesSplitLayout {
            SplitRootView()
        } else {
            NavigationStack(path: $path) {
                ProjectsView()
            }
            .onChange(of: environment.pendingSessionLink) { _, _ in
                openLinkedProject()
            }
            .onChange(of: environment.projects.projects) { _, _ in
                openLinkedProject()
            }
            .task {
                openLinkedProject()
            }
        }
    }

    /// A tapped notification names a project folder; the sessions screen it lands on then
    /// picks the conversation out of `pendingSessionLink`.
    private func openLinkedProject() {
        guard let link = environment.pendingSessionLink else { return }
        let match = environment.projects.projects.filter {
            $0.directory.standardizedFileURL.path
                == link.projectDirectory.standardizedFileURL.path
        }
        guard !match.isEmpty else { return }
        path = match
    }
}
