import Foundation
import Testing
@testable import PokeetCore

private struct StubGitInspector: GitInspecting {
    var isRepo = true
    var statuses: [GitFileStatus] = []
    var diffText = ""
    var commits: [GitCommitInfo] = []

    func isRepository(at root: URL) -> Bool {
        isRepo
    }

    func workingTreeStatus(at root: URL) async throws -> [GitFileStatus] {
        statuses
    }

    func diff(at root: URL, path: String?, staged: Bool) async throws -> String {
        diffText
    }

    func log(at root: URL, limit: Int) async throws -> [GitCommitInfo] {
        Array(commits.prefix(limit))
    }
}

struct GitToolTests {
    private func makeContext(
        git: StubGitInspector?
    ) throws -> (ToolContext, TestDirectory) {
        let directory = try TestDirectory()
        return (
            ToolContext(
                workspace: FileWorkspace(root: directory.url),
                git: git
            ),
            directory
        )
    }

    @Test func reportsStatusAndFiltersByPath() async throws {
        let (context, directory) = try makeContext(git: StubGitInspector(statuses: [
            GitFileStatus(path: "src/main.swift", state: "modified"),
            GitFileStatus(path: "README.md", state: "new"),
            GitFileStatus(path: "src/old.swift", state: "deleted")
        ]))
        defer { directory.cleanup() }

        let output = try await GitStatusTool().execute(
            arguments: Data(#"{"path":"src"}"#.utf8),
            context: context
        )

        #expect(output.content.contains("modified src/main.swift"))
        #expect(output.content.contains("deleted src/old.swift"))
        #expect(!output.content.contains("README.md"))
    }

    @Test func reportsCleanTree() async throws {
        let (context, directory) = try makeContext(git: StubGitInspector())
        defer { directory.cleanup() }

        let output = try await GitStatusTool().execute(arguments: Data(), context: context)

        #expect(output.content == "Working tree is clean.")
    }

    @Test func reportsMissingGitAndNonRepository() async throws {
        let (context, directory) = try makeContext(git: nil)
        defer { directory.cleanup() }

        let missing = try await GitStatusTool().execute(arguments: Data(), context: context)
        #expect(missing.content.contains("not available"))

        var git = StubGitInspector()
        git.isRepo = false
        let (repoContext, repoDirectory) = try makeContext(git: git)
        defer { repoDirectory.cleanup() }

        let nonRepo = try await GitDiffTool().execute(arguments: Data(), context: repoContext)
        #expect(nonRepo.content.contains("not a git repository"))
    }

    @Test func returnsDiffAndEmptyState() async throws {
        let diff = "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new"
        let (context, directory) = try makeContext(git: StubGitInspector(diffText: diff))
        defer { directory.cleanup() }

        let output = try await GitDiffTool().execute(arguments: Data(), context: context)
        #expect(output.content == diff)

        let (emptyContext, emptyDirectory) = try makeContext(git: StubGitInspector(diffText: "  \n"))
        defer { emptyDirectory.cleanup() }

        let empty = try await GitDiffTool().execute(arguments: Data(), context: emptyContext)
        #expect(empty.content == "No changes.")
    }

    @Test func formatsRecentCommits() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let commits = [
            GitCommitInfo(hash: String(repeating: "a", count: 40), author: "Ada", date: date, subject: "Latest"),
            GitCommitInfo(hash: String(repeating: "b", count: 40), author: "Bob", date: date, subject: "Older")
        ]
        let (context, directory) = try makeContext(git: StubGitInspector(commits: commits))
        defer { directory.cleanup() }

        let output = try await GitLogTool().execute(
            arguments: Data(#"{"limit":1}"#.utf8),
            context: context
        )

        #expect(output.content.contains("aaaaaaaa"))
        #expect(output.content.contains("Ada: Latest"))
        #expect(!output.content.contains("Older"))
    }

    @Test func reportsEmptyHistory() async throws {
        let (context, directory) = try makeContext(git: StubGitInspector())
        defer { directory.cleanup() }

        let output = try await GitLogTool().execute(arguments: Data(), context: context)
        #expect(output.content == "No commits yet.")
    }
}
