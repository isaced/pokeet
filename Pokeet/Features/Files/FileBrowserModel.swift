import Foundation
import Observation
import PokeetCore

struct FileBrowserEntry: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let isDirectory: Bool

    var id: String { path }
}

@MainActor
@Observable
final class DirectoryListingModel {
    let project: Project
    let path: String
    let entryLimit: Int

    private(set) var entries: [FileBrowserEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isTruncated = false

    init(project: Project, path: String, entryLimit: Int = 500) {
        self.project = project
        self.path = path
        self.entryLimit = max(1, entryLimit)
    }

    var title: String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? project.name : name
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let root = project.directory
        let path = path
        let limit = entryLimit

        do {
            let listed = try await Task.detached(priority: .userInitiated) {
                let workspace = FileWorkspace(root: root)
                return try workspace.list(
                    path,
                    recursive: false,
                    maxEntries: limit + 1
                )
            }.value

            let visible = listed.filter { entry in
                let name = (entry.path as NSString).lastPathComponent
                return name != ".DS_Store"
            }

            isTruncated = listed.count > limit
            let mapped = visible.map { entry in
                FileBrowserEntry(
                    path: entry.path,
                    name: (entry.path as NSString).lastPathComponent,
                    isDirectory: entry.isDirectory
                )
            }
            entries = Array(
                mapped
                    .sorted { lhs, rhs in
                        if lhs.isDirectory != rhs.isDirectory {
                            return lhs.isDirectory
                        }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    .prefix(limit)
            )
        } catch {
            entries = []
            isTruncated = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class FileDetailModel {
    let project: Project
    let path: String

    private(set) var text: String?
    private(set) var lines: [String] = []
    private(set) var highlightedLines: [AttributedString]?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var highlightedIsDark: Bool?
    private var highlightRevision = UUID()

    init(project: Project, path: String) {
        self.project = project
        self.path = path
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var displayLines: [AttributedString] {
        if let highlightedLines, highlightedLines.count == lines.count {
            return highlightedLines.map {
                $0.characters.isEmpty ? AttributedString(" ") : $0
            }
        }
        return lines.map { AttributedString($0.isEmpty ? " " : $0) }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        highlightedLines = nil
        highlightedIsDark = nil
        highlightRevision = UUID()
        defer { isLoading = false }

        let root = project.directory
        let path = path

        do {
            let text = try await Task.detached(priority: .userInitiated) {
                let workspace = FileWorkspace(root: root)
                return try workspace.read(path, maxBytes: 200_000)
            }.value
            self.text = text
            lines = text.components(separatedBy: "\n")
        } catch {
            text = nil
            lines = []
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func highlight(isDark: Bool) async {
        guard let text, !text.isEmpty,
              let language = CodeLanguage.alias(for: path),
              text.count <= CodeHighlighter.maximumCharacters
        else {
            highlightedLines = nil
            highlightedIsDark = nil
            return
        }

        if highlightedIsDark == isDark, highlightedLines != nil {
            return
        }

        let revision = UUID()
        highlightRevision = revision
        highlightedLines = nil

        let highlighted = await CodeHighlighter.highlight(
            text: text,
            language: language,
            isDark: isDark,
            expectedLineCount: lines.count
        )

        guard highlightRevision == revision else { return }
        highlightedLines = highlighted
        highlightedIsDark = highlighted == nil ? nil : isDark
    }
}
