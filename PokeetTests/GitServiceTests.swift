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
