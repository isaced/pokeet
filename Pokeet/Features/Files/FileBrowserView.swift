import SwiftUI
import Textual

struct FileBrowserView: View {
    let project: Project

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DirectoryView(project: project, isRoot: true)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct DirectoryView: View {
    let project: Project
    let path: String
    let isRoot: Bool

    @State private var model: DirectoryListingModel

    init(project: Project, path: String = "", isRoot: Bool = false) {
        self.project = project
        self.path = path
        self.isRoot = isRoot
        _model = State(initialValue: DirectoryListingModel(project: project, path: path))
    }

    var body: some View {
        List {
            ForEach(model.entries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        DirectoryView(project: project, path: entry.path)
                    } label: {
                        EntryRow(entry: entry)
                    }
                } else {
                    NavigationLink {
                        FileDetailView(project: project, path: entry.path)
                    } label: {
                        EntryRow(entry: entry)
                    }
                }
            }

            if model.isTruncated {
                Text("Showing the first \(model.entryLimit) items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle(isRoot ? project.name : model.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if model.isLoading && model.entries.isEmpty {
                ProgressView("Loading…")
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await model.load() }
                    }
                }
            } else if model.entries.isEmpty {
                ContentUnavailableView(
                    "Empty folder",
                    systemImage: "folder",
                    description: Text("Files created in this project will appear here.")
                )
            }
        }
        .refreshable {
            await model.load()
        }
        .task {
            await model.load()
        }
    }
}

private struct EntryRow: View {
    let entry: FileBrowserEntry

    var body: some View {
        Label {
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
    }

    private var symbol: String {
        guard !entry.isDirectory else { return "folder.fill" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "swift":
            return "swift"
        case "md", "markdown":
            return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "webp", "heic":
            return "photo"
        case "json", "yml", "yaml", "toml", "plist":
            return "curlybraces"
        case "sh", "zsh", "bash":
            return "terminal"
        default:
            return "doc.text"
        }
    }

    private var color: Color {
        guard !entry.isDirectory else { return .blue }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "swift":
            return .orange
        case "md", "markdown":
            return .blue
        case "png", "jpg", "jpeg", "gif", "webp", "heic":
            return .purple
        case "json", "yml", "yaml", "toml", "plist":
            return .green
        default:
            return .secondary
        }
    }
}

private struct FileDetailView: View {
    let project: Project
    let path: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var model: FileDetailModel
    @State private var showsPreview: Bool

    init(project: Project, path: String) {
        self.project = project
        self.path = path
        _model = State(initialValue: FileDetailModel(project: project, path: path))
        _showsPreview = State(initialValue: Self.isMarkdown(path))
    }

    private var isMarkdown: Bool {
        Self.isMarkdown(path)
    }

    private static func isMarkdown(_ path: String) -> Bool {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown":
            return true
        default:
            return (path as NSString).lastPathComponent.lowercased() == "readme"
        }
    }

    var body: some View {
        Group {
            if model.isLoading && model.text == nil {
                ProgressView("Loading…")
            } else if let error = model.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't open file", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await model.load() }
                    }
                }
            } else if let text = model.text, text.isEmpty {
                ContentUnavailableView(
                    "Empty file",
                    systemImage: "doc",
                    description: Text("This file has no content.")
                )
            } else if isMarkdown, showsPreview, let text = model.text {
                markdownPreview(text)
            } else {
                content
            }
        }
        .navigationTitle(model.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isMarkdown {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsPreview.toggle()
                    } label: {
                        Image(
                            systemName: showsPreview
                                ? "chevron.left.forwardslash.chevron.right"
                                : "doc.richtext"
                        )
                    }
                    .accessibilityLabel(
                        showsPreview ? "Show source" : "Preview markdown"
                    )
                }
            }
        }
        .task {
            await model.load()
            await model.highlight(isDark: colorScheme == .dark)
        }
        .onChange(of: colorScheme) { _, newScheme in
            Task { await model.highlight(isDark: newScheme == .dark) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(model.lines.count) lines")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func markdownPreview(_ text: String) -> some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                StructuredText(markdown: text)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var content: some View {
        let lines = model.displayLines

        return VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(minWidth: 34, alignment: .trailing)

                            Text(line)
                                .font(.system(size: 12.5, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
        }
    }
}
