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
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(project: Project, path: String) {
        self.project = project
        self.path = path
    }

    var name: String {
        (path as NSString).lastPathComponent
    }

    var lines: [String] {
        guard let text else { return [] }
        return text.components(separatedBy: "\n")
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let root = project.directory
        let path = path

        do {
            text = try await Task.detached(priority: .userInitiated) {
                let workspace = FileWorkspace(root: root)
                return try workspace.read(path, maxBytes: 200_000)
            }.value
        } catch {
            text = nil
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}
