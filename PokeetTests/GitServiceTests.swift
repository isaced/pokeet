import PokeetCore
import SwiftGitX
import XCTest
@testable import Pokeet

final class GitServiceTests: XCTestCase {
    func testStatusCommitAndCleanTree() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try Repository.create(at: directory)
        try repository.config.set("user.name", to: "Pokeet Tests")
        try repository.config.set("user.email", to: "tests@pokeet.local")

        try "hello\n".write(
            to: directory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = SwiftGitXGitService()

        let statusBefore = try await service.status(at: directory)
        XCTAssertEqual(statusBefore.map(\.path), ["README.md"])
        XCTAssertEqual(statusBefore.first?.state, "new")

        let hash = try await service.commitAll(
            at: directory,
            message: "Initial commit",
            author: GitAuthor(name: "Pokeet Tests", email: "tests@pokeet.local")
        )
        XCTAssertEqual(hash.count, 40)

        let statusAfter = try await service.status(at: directory)
        XCTAssertTrue(statusAfter.isEmpty)
    }

    func testInspectsStatusDiffAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try Repository.create(at: directory)
        try repository.config.set("user.name", to: "Pokeet Tests")
        try repository.config.set("user.email", to: "tests@pokeet.local")

        let readme = directory.appendingPathComponent("README.md")
        try "hello\n".write(to: readme, atomically: true, encoding: .utf8)

        let service = SwiftGitXGitService()
        XCTAssertTrue(service.isRepository(at: directory))

        _ = try await service.commitAll(
            at: directory,
            message: "Initial commit",
            author: GitAuthor(name: "Pokeet Tests", email: "tests@pokeet.local")
        )

        try "hello world\n".write(to: readme, atomically: true, encoding: .utf8)
        try "new\n".write(
            to: directory.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )

        let status = try await service.workingTreeStatus(at: directory)
        XCTAssertEqual(Set(status.map(\.path)), ["README.md", "new.txt"])
        XCTAssertEqual(status.first(where: { $0.path == "README.md" })?.state, "modified")
        XCTAssertEqual(status.first(where: { $0.path == "new.txt" })?.state, "new")

        let diff = try await service.diff(at: directory, path: "README.md", staged: false)
        XCTAssertTrue(diff.contains("-hello"))
        XCTAssertTrue(diff.contains("+hello world"))

        let commits = try await service.log(at: directory, limit: 1)
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.subject, "Initial commit")
        XCTAssertEqual(commits.first?.author, "Pokeet Tests")
        XCTAssertEqual(commits.first?.hash.count, 40)
    }

    func testCommitAllStagesDeletions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try Repository.create(at: directory)
        try repository.config.set("user.name", to: "Pokeet Tests")
        try repository.config.set("user.email", to: "tests@pokeet.local")

        let readme = directory.appendingPathComponent("README.md")
        try "hello\n".write(to: readme, atomically: true, encoding: .utf8)

        let service = SwiftGitXGitService()
        _ = try await service.commitAll(
            at: directory,
            message: "Initial commit",
            author: GitAuthor(name: "Pokeet Tests", email: "tests@pokeet.local")
        )

        try FileManager.default.removeItem(at: readme)

        _ = try await service.commitAll(
            at: directory,
            message: "Delete README",
            author: GitAuthor(name: "Pokeet Tests", email: "tests@pokeet.local")
        )

        let status = try await service.status(at: directory)
        XCTAssertTrue(status.isEmpty)
    }

    func testDiffStatCountsOverlappingStagedAndUnstagedEditsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try Repository.create(at: directory)
        try repository.config.set("user.name", to: "Pokeet Tests")
        try repository.config.set("user.email", to: "tests@pokeet.local")

        let service = SwiftGitXGitService()
        let file = directory.appendingPathComponent("main.swift")
        try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await service.commitAll(
            at: directory,
            message: "Initial commit",
            author: GitAuthor(name: "Pokeet Tests", email: "tests@pokeet.local")
        )

        // Stage one version, then edit the same line again in the working tree.
        try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
        let staging = try Repository(at: directory, createIfNotExists: false)
        try staging.add(path: "main.swift")
        try "let value = 3\n".write(to: file, atomically: true, encoding: .utf8)

        let stats = try await service.diffStat(at: directory)
        let entry = try XCTUnwrap(stats.first { $0.path == "main.swift" })
        XCTAssertEqual(entry.added, 1)
        XCTAssertEqual(entry.removed, 1)
    }

    func testDiffStatCountsUntrackedAndDeletedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try Repository.create(at: directory)
        try repository.config.set("user.name", to: "Pokeet Tests")
        try repository.config.set("user.email", to: "tests@pokeet.local")

        let service = SwiftGitXGitService()
        let kept = directory.appendingPathComponent("kept.swift")
        let removed = directory.appendingPathComponent("removed.swift")
        try "let kept = 1\n".write(to: kept, atomically: true, encoding: .utf8)
        try "let removed = 1\n".write(to: removed, atomically: true, encoding: .utf8)
        _ = try await service.commitAll(
            at: directory,
            message: "Initial commit",
            author: GitAuthor(name: "Pokeet Tests", email: "tests@pokeet.local")
        )

        try FileManager.default.removeItem(at: removed)
        try "one\ntwo\nthree\n".write(
            to: directory.appendingPathComponent("new.swift"),
            atomically: true,
            encoding: .utf8
        )

        let stats = try await service.diffStat(at: directory)

        let newFile = try XCTUnwrap(stats.first { $0.path == "new.swift" })
        XCTAssertEqual(newFile.added, 3)
        XCTAssertEqual(newFile.removed, 0)

        let deleted = try XCTUnwrap(stats.first { $0.path == "removed.swift" })
        XCTAssertEqual(deleted.added, 0)
        XCTAssertEqual(deleted.removed, 1)

        XCTAssertNil(stats.first { $0.path == "kept.swift" })
    }

    func testDiffStatCoversRepositoriesWithoutACommit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try Repository.create(at: directory)
        try "one\ntwo\n".write(
            to: directory.appendingPathComponent("staged.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "one\ntwo\nthree\n".write(
            to: directory.appendingPathComponent("untracked.swift"),
            atomically: true,
            encoding: .utf8
        )
        let staging = try Repository(at: directory, createIfNotExists: false)
        try staging.add(path: "staged.swift")

        let stats = try await SwiftGitXGitService().diffStat(at: directory)

        let staged = try XCTUnwrap(stats.first { $0.path == "staged.swift" })
        XCTAssertEqual(staged.added, 2)
        XCTAssertEqual(staged.removed, 0)

        let untracked = try XCTUnwrap(stats.first { $0.path == "untracked.swift" })
        XCTAssertEqual(untracked.added, 3)
        XCTAssertEqual(untracked.removed, 0)
    }

    func testCommitWithoutChangesThrows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try Repository.create(at: directory)
        try repository.config.set("user.name", to: "Pokeet Tests")
        try repository.config.set("user.email", to: "tests@pokeet.local")

        let service = SwiftGitXGitService()
        do {
            _ = try await service.commitAll(
                at: directory,
                message: "Nothing",
                author: GitAuthor(name: "Pokeet Tests", email: "tests@pokeet.local")
            )
            XCTFail("Expected noChanges")
        } catch let error as GitServiceError {
            XCTAssertEqual(error, .noChanges)
        }
    }
}
