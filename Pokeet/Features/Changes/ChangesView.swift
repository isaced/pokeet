import PokeetCore
import SwiftUI

struct ChangesView: View {
    let project: Project
    let canCommit: Bool
    let onCommit: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var model: ChangesModel

    init(
        project: Project,
        git: any GitInspecting,
        canCommit: Bool = false,
        onCommit: (() -> Void)? = nil
    ) {
        self.project = project
        self.canCommit = canCommit
        self.onCommit = onCommit
        _model = State(initialValue: ChangesModel(project: project, git: git))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.files.isEmpty {
                    ProgressView("Loading changes…")
                } else if let error = model.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load changes", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await model.load() }
                        }
                    }
                } else if model.files.isEmpty {
                    ContentUnavailableView(
                        "No changes",
                        systemImage: "checkmark.circle",
                        description: Text("The working tree is clean.")
                    )
                } else {
                    List(model.files) { file in
                        NavigationLink {
                            GitDiffDetailView(
                                project: project,
                                file: file,
                                git: model.git
                            )
                        } label: {
                            ChangedFileRow(file: file)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await model.load()
                    }
                }
            }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canCommit, let onCommit {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Commit") {
                            dismiss()
                            onCommit()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await model.load()
            }
        }
    }
}

private struct ChangedFileRow: View {
    let file: ChangedFile

    var body: some View {
        HStack(spacing: 10) {
            Text(letter)
                .font(.caption2.bold())
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

            Text(file.path)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var letter: String {
        switch file.state {
        case "new": "A"
        case "deleted": "D"
        case "renamed": "R"
        case "conflicted": "!"
        default: "M"
        }
    }

    private var color: Color {
        switch file.state {
        case "new": .green
        case "deleted": .red
        case "renamed": .orange
        case "conflicted": .purple
        default: .blue
        }
    }
}

private struct GitDiffDetailView: View {
    let project: Project
    let file: ChangedFile
    let git: any GitInspecting

    @State private var model: GitDiffModel

    init(project: Project, file: ChangedFile, git: any GitInspecting) {
        self.project = project
        self.file = file
        self.git = git
        _model = State(initialValue: GitDiffModel(project: project, file: file, git: git))
    }

    var body: some View {
        Group {
            if model.isLoading && model.text == nil {
                ProgressView("Loading diff…")
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load diff", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await model.load() }
                    }
                }
            } else if let text = model.text {
                VStack(spacing: 0) {
                    header
                    Divider()
                    DiffText(text: text)
                }
            } else {
                ProgressView("Loading diff…")
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await model.load()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(file.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if model.isStaged {
                Text("STAGED")
                    .font(.caption2.bold())
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }
}

private struct DiffText: View {
    let text: String

    private var lines: [String] {
        text.components(separatedBy: "\n")
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(foreground(for: line))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(background(for: line))
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
    }

    private func kind(of line: String) -> Kind {
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .fileHeader }
        if line.hasPrefix("diff --git") || line.hasPrefix("index ") { return .metadata }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        if line.hasPrefix("New file:") { return .metadata }
        return .context
    }

    private func foreground(for line: String) -> Color {
        switch kind(of: line) {
        case .hunk: .blue
        case .fileHeader, .metadata: .secondary
        case .added: .primary
        case .removed: .primary
        case .context: .primary
        }
    }

    private func background(for line: String) -> Color {
        switch kind(of: line) {
        case .hunk: Color.blue.opacity(0.08)
        case .added: Color.green.opacity(0.14)
        case .removed: Color.red.opacity(0.14)
        default: .clear
        }
    }

    private enum Kind {
        case added
        case removed
        case hunk
        case fileHeader
        case metadata
        case context
    }
}
