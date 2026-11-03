import PokeetCore
import XCTest
@testable import Pokeet

private struct StubError: LocalizedError {
    var errorDescription: String? { "Stats unavailable" }
}

private struct StubGitInspector: GitInspecting {
    var isRepo = true
    var statuses: [GitFileStatus] = []
    var workingDiff = ""
    var stagedDiff = ""
    var stats: [GitFileDiffStat] = []
    var statsError: Error?

    func isRepository(at root: URL) -> Bool {
        isRepo
    }

    func workingTreeStatus(at root: URL) async throws -> [GitFileStatus] {
        statuses
    }

    func diff(at root: URL, path: String?, staged: Bool) async throws -> String {
        staged ? stagedDiff : workingDiff
    }

    func diffStat(at root: URL) async throws -> [GitFileDiffStat] {
        if let statsError {
            throw statsError
        }
        return stats
    }

    func log(at root: URL, limit: Int) async throws -> [GitCommitInfo] {
        []
    }
}

@MainActor
final class ChangesModelTests: XCTestCase {
    private func makeProject() throws -> (Project, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-changes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            Project(directory: directory, remoteHost: "example.com", isGitRepository: true),
            directory
        )
    }

    func testAttachesDiffStats() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        var git = StubGitInspector()
        git.statuses = [
            GitFileStatus(path: "src/main.swift", state: "modified"),
            GitFileStatus(path: "README.md", state: "new")
        ]
        git.stats = [
            GitFileDiffStat(path: "src/main.swift", added: 5, removed: 2),
            GitFileDiffStat(path: "README.md", added: 3, removed: 0)
        ]

        let model = ChangesModel(project: project, git: git)
        await model.load()

        let main = try XCTUnwrap(model.files.first { $0.path == "src/main.swift" })
        XCTAssertEqual(main.addedLines, 5)
        XCTAssertEqual(main.removedLines, 2)

        let readme = try XCTUnwrap(model.files.first { $0.path == "README.md" })
        XCTAssertEqual(readme.addedLines, 3)
        XCTAssertEqual(readme.removedLines, 0)
    }

    func testKeepsFilesWhenDiffStatsFail() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        var git = StubGitInspector()
        git.statuses = [
            GitFileStatus(path: "src/main.swift", state: "modified")
        ]
        git.statsError = StubError()

        let model = ChangesModel(project: project, git: git)
        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.files.map(\.path), ["src/main.swift"])
        XCTAssertNil(model.files.first?.addedLines)
        XCTAssertNil(model.files.first?.removedLines)
    }

    func testListsChangedFilesSorted() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        var git = StubGitInspector()
        git.statuses = [
            GitFileStatus(path: "src/main.swift", state: "modified"),
            GitFileStatus(path: "README.md", state: "new")
        ]

        let model = ChangesModel(project: project, git: git)
        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.files.map(\.path), ["README.md", "src/main.swift"])
        XCTAssertEqual(model.files.first?.state, "new")
    }

    func testReportsNonRepository() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        var git = StubGitInspector()
        git.isRepo = false

        let model = ChangesModel(project: project, git: git)
        await model.load()

        XCTAssertTrue(model.files.isEmpty)
        XCTAssertEqual(model.errorMessage, "This project is not a git repository.")
    }

    func testUsesWorkingTreeDiff() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        var git = StubGitInspector()
        git.workingDiff = "-old\n+new"

        let file = ChangedFile(path: "file.txt", state: "modified")
        let model = GitDiffModel(project: project, file: file, git: git)
        await model.load()

        XCTAssertEqual(model.text, "-old\n+new")
        XCTAssertFalse(model.isStaged)
    }

    func testFallsBackToStagedDiff() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        var git = StubGitInspector()
        git.stagedDiff = "-old\n+staged"

        let file = ChangedFile(path: "file.txt", state: "modified")
        let model = GitDiffModel(project: project, file: file, git: git)
        await model.load()

        XCTAssertEqual(model.text, "-old\n+staged")
        XCTAssertTrue(model.isStaged)
    }

    func testRendersUntrackedFileAsAddedLines() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "one\ntwo\n".write(
            to: directory.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        let git = StubGitInspector()
        let file = ChangedFile(path: "new.txt", state: "new")
        let model = GitDiffModel(project: project, file: file, git: git)
        await model.load()

        XCTAssertEqual(model.text, "New file: new.txt\n+one\n+two")
        XCTAssertFalse(model.isStaged)
    }

    func testReportsNoDiff() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let git = StubGitInspector()
        let file = ChangedFile(path: "file.txt", state: "modified")
        let model = GitDiffModel(project: project, file: file, git: git)
        await model.load()

        XCTAssertEqual(model.text, "No changes to show.")
    }
}
