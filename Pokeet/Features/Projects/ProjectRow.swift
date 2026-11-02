import SwiftUI

struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            if project.isGitRepository {
                if let host = project.remoteHost {
                    Label(host, systemImage: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("Local project", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
