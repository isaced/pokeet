import Observation
import PokeetCore
import SwiftUI

@MainActor
@Observable
final class ProjectFilePickerModel {
    let project: Project
    let entryLimit: Int

    private(set) var files: [String] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isTruncated = false

    init(project: Project, entryLimit: Int = 2_000) {
        self.project = project
        self.entryLimit = max(1, entryLimit)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let root = project.directory
        let limit = entryLimit

        do {
            let entries = try await Task.detached(priority: .userInitiated) {
                try FileWorkspace(root: root).list("", recursive: true, maxEntries: limit + 1)
            }.value

            let files = entries
                .filter { !$0.isDirectory }
                .map(\.path)
                .filter { ($0 as NSString).lastPathComponent != ".DS_Store" }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            isTruncated = files.count > limit
            self.files = Array(files.prefix(limit))
        } catch {
            files = []
            isTruncated = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

struct ProjectFilePickerView: View {
    let project: Project
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectFilePickerModel
    @State private var query = ""

    init(project: Project, onSelect: @escaping (String) -> Void) {
        self.project = project
        self.onSelect = onSelect
        _model = State(initialValue: ProjectFilePickerModel(project: project))
    }

    private var filteredFiles: [String] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return model.files }
        return model.files.filter { $0.lowercased().contains(value) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.files.isEmpty {
                    ProgressView("Finding files…")
                } else if let error = model.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't list files", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await model.load() }
                        }
                    }
                } else if filteredFiles.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "No files" : "No matches",
                        systemImage: "doc",
                        description: Text(
                            query.isEmpty
                                ? "This project has no files to reference yet."
                                : "Try a different file name."
                        )
                    )
                } else {
                    List {
                        ForEach(filteredFiles, id: \.self) { path in
                            Button {
                                onSelect(path)
                                dismiss()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(.secondary)
                                    Text(path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if model.isTruncated {
                            Text("Showing the first \(model.entryLimit) files. Use search to narrow down.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search files"
            )
            .navigationTitle("At file")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await model.load()
            }
        }
    }
}
