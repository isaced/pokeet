import SwiftUI

struct ProjectRow: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            if project.isGitRepository {
                if let host = project.remoteHost {
                    HStack(spacing: 4) {
                        Image(systemName: "network")
                        Text(host)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text("Local project")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
