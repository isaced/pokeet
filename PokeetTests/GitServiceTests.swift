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
