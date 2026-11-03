import Foundation
import Testing
@testable import PokeetCore

private struct StubGitInspector: GitInspecting {
    var isRepo = true
    var statuses: [GitFileStatus] = []
    var diffText = ""
    var commits: [GitCommitInfo] = []
    var blob: GitBlobContent?
    var commit: GitCommitDetails?
    var showError: GitInspectError?

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

    func blob(at root: URL, ref: String, path: String) async throws -> GitBlobContent {
        if let showError { throw showError }
        guard let blob else { throw GitInspectError.notFound(ref: ref, path: path) }
        return blob
    }

    func commitDetails(at root: URL, ref: String) async throws -> GitCommitDetails {
        if let showError { throw showError }
        guard let commit else { throw GitInspectError.unknownRevision(ref) }
        return commit
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

    @Test func showsFileAtRevision() async throws {
        let (context, directory) = try makeContext(git: StubGitInspector(blob: GitBlobContent(
            ref: "HEAD~2",
            path: "README.md",
            text: "one\ntwo\n",
            sizeBytes: 8,
            isBinary: false
        )))
        defer { directory.cleanup() }

        let output = try await GitShowTool().execute(
            arguments: Data(#"{"ref":"HEAD~2","path":"README.md"}"#.utf8),
            context: context
        )

        #expect(output.content.contains("ref: HEAD~2"))
        #expect(output.content.contains("1\tone"))
        #expect(output.content.contains("2\ttwo"))
    }

    @Test func showsCommitDetails() async throws {
        let (context, directory) = try makeContext(git: StubGitInspector(commit: GitCommitDetails(
            hash: "abc123",
            author: "Pokeet",
            date: Date(timeIntervalSince1970: 0),
            message: "Fix the parser\n\nExplains why.",
            diff: "diff --git a/a.swift b/a.swift\n+let x = 1"
        )))
        defer { directory.cleanup() }

        let output = try await GitShowTool().execute(
            arguments: Data("{}".utf8),
            context: context
        )

        #expect(output.content.contains("commit abc123"))
        #expect(output.content.contains("author: Pokeet"))
        #expect(output.content.contains("Explains why."))
        #expect(output.content.contains("+let x = 1"))
    }

    @Test func reportsUnknownRevisionAndMissingFile() async throws {
        let (unknown, first) = try makeContext(git: StubGitInspector(
            showError: .unknownRevision("nope")
        ))
        defer { first.cleanup() }
        let unknownOutput = try await GitShowTool().execute(
            arguments: Data(#"{"ref":"nope"}"#.utf8),
            context: unknown
        )
        #expect(unknownOutput.content.contains("Unknown revision 'nope'"))

        let (missing, second) = try makeContext(git: StubGitInspector())
        defer { second.cleanup() }
        let missingOutput = try await GitShowTool().execute(
            arguments: Data(#"{"path":"gone.swift"}"#.utf8),
            context: missing
        )
        #expect(missingOutput.content.contains("No file at 'gone.swift' in 'HEAD'"))
    }

    @Test func rejectsPathsOutsideTheWorkspace() async throws {
        let (context, directory) = try makeContext(git: StubGitInspector())
        defer { directory.cleanup() }

        await #expect(throws: ToolError.self) {
            _ = try await GitShowTool().execute(
                arguments: Data(#"{"path":"../secret"}"#.utf8),
                context: context
            )
        }
    }

    @Test func reportsMissingGitInspector() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let output = try await GitShowTool().execute(
            arguments: Data("{}".utf8),
            context: ToolContext(workspace: FileWorkspace(root: directory.url))
        )
        #expect(output.content.contains("not available"))
    }

    @Test func reportsGitCallDetails() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let client = ScriptedModelClient([
            ChatResponse(
                message: .assistant(
                    nil,
                    toolCalls: [
                        ToolCall(
                            id: "diff_1",
                            name: "git_diff",
                            arguments: #"{"staged":true,"path":"Sources/App.swift"}"#
                        ),
                        ToolCall(id: "status_1", name: "git_status", arguments: "{}"),
                        ToolCall(id: "log_1", name: "git_log", arguments: #"{"limit":5}"#)
                    ]
                ),
                finishReason: "tool_calls"
            ),
            ChatResponse(message: .assistant("done"), finishReason: "stop")
        ])
        let session = AgentSession(
            client: client,
            workspace: FileWorkspace(root: directory.url),
            git: StubGitInspector(),
            mode: .bypass
        )
        let recorder = EventRecorder()

        try await session.send(
            "inspect",
            approval: { _ in [] },
            onEvent: { await recorder.record($0) }
        )

        let details = await recorder.snapshot().compactMap { event -> (String, String?)? in
            if case .toolStarted(let name, _, let detail, _) = event {
                return (name, detail)
            }
            return nil
        }

        #expect(details.count == 3)
        #expect(details[0].0 == "git_diff")
        #expect(details[0].1 == "staged · Sources/App.swift")
        #expect(details[1].0 == "git_status")
        #expect(details[1].1 == "working tree")
        #expect(details[2].0 == "git_log")
        #expect(details[2].1 == "last 5 commits")
    }
}
