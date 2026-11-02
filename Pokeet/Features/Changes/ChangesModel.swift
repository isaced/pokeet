import Foundation
import Observation
import PokeetCore

struct ChangedFile: Identifiable, Hashable, Sendable {
    let path: String
    let state: String

    var id: String { path }

    var name: String {
        (path as NSString).lastPathComponent
    }
}

@MainActor
@Observable
final class ChangesModel {
    let project: Project
    let git: any GitInspecting

    private(set) var files: [ChangedFile] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(project: Project, git: any GitInspecting) {
        self.project = project
        self.git = git
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard git.isRepository(at: project.directory) else {
            files = []
            errorMessage = "This project is not a git repository."
            return
        }

        do {
            files = try await git.workingTreeStatus(at: project.directory)
                .map { ChangedFile(path: $0.path, state: $0.state) }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        } catch {
            files = []
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class GitDiffModel {
    let project: Project
    let file: ChangedFile
    let git: any GitInspecting

    private(set) var text: String?
    private(set) var isStaged = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    init(project: Project, file: ChangedFile, git: any GitInspecting) {
        self.project = project
        self.file = file
        self.git = git
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        text = nil
        isStaged = false
        defer { isLoading = false }

        do {
            var diff = try await git.diff(
                at: project.directory,
                path: file.path,
                staged: false
            )

            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let stagedDiff = try await git.diff(
                    at: project.directory,
                    path: file.path,
                    staged: true
                )
                if !stagedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    diff = stagedDiff
                    isStaged = true
                }
            }

            if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               file.state == "new" {
                diff = try await untrackedDiff()
            }

            text = diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "No changes to show."
                : diff
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private func untrackedDiff() async throws -> String {
        let root = project.directory
        let path = file.path

        let content = try await Task.detached(priority: .userInitiated) {
            try FileWorkspace(root: root).read(path, maxBytes: 200_000)
        }.value

        guard !content.isEmpty else {
            return "New empty file."
        }

        var normalized = content
        if normalized.hasSuffix("\n") {
            normalized.removeLast()
        }
        let body = normalized.components(separatedBy: "\n").map { "+" + $0 }
        return (["New file: \(path)"] + body).joined(separator: "\n")
    }
}
