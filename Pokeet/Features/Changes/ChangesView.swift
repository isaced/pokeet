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
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let added = file.addedLines, let removed = file.removedLines {
                DiffStatView(added: added, removed: removed)
            }
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

private struct DiffStatView: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 6) {
            if added + removed > 0 {
                DiffStatBar(added: added, removed: removed)
            }

            HStack(spacing: 4) {
                if added > 0 {
                    Text("+\(added)")
                        .foregroundStyle(.green)
                }
                if removed > 0 {
                    Text("−\(removed)")
                        .foregroundStyle(.red)
                }
                if added == 0 && removed == 0 {
                    Text("—")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption.monospacedDigit().weight(.medium))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) added, \(removed) removed")
    }
}

private struct DiffStatBar: View {
    let added: Int
    let removed: Int

    private let width: CGFloat = 34
    private let height: CGFloat = 4

    var body: some View {
        let total = added + removed
        let gap: CGFloat = added > 0 && removed > 0 ? 2 : 0
        let available = width - gap
        let addedWidth = total > 0 ? available * CGFloat(added) / CGFloat(total) : 0
        let removedWidth = total > 0 ? available * CGFloat(removed) / CGFloat(total) : 0

        HStack(spacing: gap) {
            if addedWidth > 0 {
                Capsule()
                    .fill(Color.green.opacity(0.8))
                    .frame(width: addedWidth, height: height)
            }
            if removedWidth > 0 {
                Capsule()
                    .fill(Color.red.opacity(0.8))
                    .frame(width: removedWidth, height: height)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
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
                    DiffText(text: text, path: file.path)
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
    let path: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var oldHighlighted: [AttributedString]?
    @State private var newHighlighted: [AttributedString]?
    @State private var highlightRevision = UUID()

    private var document: DiffDocument {
        DiffDocument(text)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.lines) { line in
                        Text(attributedLine(line))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(foreground(for: line.kind))
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .frame(minWidth: proxy.size.width, alignment: .leading)
                            .background(background(for: line.kind))
                    }
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
        }
        .task(id: colorScheme) {
            await highlight()
        }
        .onChange(of: text) { _, _ in
            Task { await highlight() }
        }
    }

    private func attributedLine(_ line: DiffDocument.Line) -> AttributedString {
        guard let prefix = line.prefix else {
            return AttributedString(line.raw)
        }

        var result = AttributedString(prefix)
        result.foregroundColor = prefixColor(for: line.kind)

        let highlighted: AttributedString?
        switch line.kind {
        case .added:
            highlighted = highlightedLine(line.newIndex, in: newHighlighted)
        case .removed:
            highlighted = highlightedLine(line.oldIndex, in: oldHighlighted)
        case .context:
            highlighted = highlightedLine(line.newIndex, in: newHighlighted)
                ?? highlightedLine(line.oldIndex, in: oldHighlighted)
        default:
            highlighted = nil
        }

        result.append(highlighted ?? AttributedString(line.content))
        return result
    }

    private func highlightedLine(
        _ index: Int?,
        in lines: [AttributedString]?
    ) -> AttributedString? {
        guard let index, let lines, lines.indices.contains(index) else {
            return nil
        }
        return lines[index]
    }

    private func highlight() async {
        guard let language = CodeLanguage.alias(for: path) else {
            oldHighlighted = nil
            newHighlighted = nil
            return
        }

        let document = DiffDocument(text)
        guard !document.oldText.isEmpty || !document.newText.isEmpty else {
            oldHighlighted = nil
            newHighlighted = nil
            return
        }

        let revision = UUID()
        highlightRevision = revision
        let isDark = colorScheme == .dark

        let old = document.oldText.isEmpty ? nil : await CodeHighlighter.highlight(
            text: document.oldText,
            language: language,
            isDark: isDark,
            expectedLineCount: document.oldLineCount
        )
        let new = document.newText.isEmpty ? nil : await CodeHighlighter.highlight(
            text: document.newText,
            language: language,
            isDark: isDark,
            expectedLineCount: document.newLineCount
        )

        guard !Task.isCancelled, highlightRevision == revision else { return }
        oldHighlighted = old
        newHighlighted = new
    }

    private func foreground(for kind: DiffLineKind) -> Color {
        switch kind {
        case .hunk: .blue
        case .fileHeader, .metadata: .secondary
        case .added, .removed, .context: .primary
        }
    }

    private func prefixColor(for kind: DiffLineKind) -> Color {
        switch kind {
        case .added: .green
        case .removed: .red
        default: .secondary
        }
    }

    private func background(for kind: DiffLineKind) -> Color {
        switch kind {
        case .hunk: Color.blue.opacity(0.08)
        case .added: Color.green.opacity(0.14)
        case .removed: Color.red.opacity(0.14)
        default: .clear
        }
    }
}
