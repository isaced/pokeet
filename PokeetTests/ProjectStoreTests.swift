import XCTest
@testable import Pokeet

@MainActor
final class ProjectStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testScanIncludesEmptyAndGitProjects() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Empty Work", isDirectory: true),
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Repo/.git", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Inbox", isDirectory: true),
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".hidden", isDirectory: true),
            withIntermediateDirectories: false
        )

        let store = ProjectStore(documentsURL: root)
        await store.refresh()

        XCTAssertEqual(Set(store.projects.map(\.name)), ["Empty Work", "Repo"])
        XCTAssertFalse(try XCTUnwrap(store.projects.first { $0.name == "Empty Work" }).isGitRepository)
        XCTAssertTrue(try XCTUnwrap(store.projects.first { $0.name == "Repo" }).isGitRepository)
    }

    func testCreateEmptyProject() async throws {
        let store = ProjectStore(documentsURL: root)
        let project = try await store.createProject(named: "My App")

        XCTAssertEqual(project.directory.lastPathComponent, "My App")
        XCTAssertFalse(project.isGitRepository)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.directory.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: project.directory.appendingPathComponent(".git").path
            )
        )

        await store.refresh()
        XCTAssertTrue(store.projects.contains { $0.id == project.id })
    }

    func testCreateProjectUsesUniqueFolderName() async throws {
        let store = ProjectStore(documentsURL: root)
        let first = try await store.createProject(named: "demo")
        let second = try await store.createProject(named: "demo")

        XCTAssertEqual(first.directory.lastPathComponent, "demo")
        XCTAssertEqual(second.directory.lastPathComponent, "demo-2")
    }

    func testCreateProjectSanitizesName() async throws {
        let store = ProjectStore(documentsURL: root)
        let project = try await store.createProject(named: ".my/app:name")

        XCTAssertEqual(project.directory.lastPathComponent, "my-app-name")
    }

    func testCreateProjectRejectsEmptyAndReservedNames() async throws {
        let store = ProjectStore(documentsURL: root)

        do {
            _ = try await store.createProject(named: "   ")
            XCTFail("Expected invalid name")
        } catch let error as ProjectError {
            XCTAssertEqual(error, .invalidName)
        }

        do {
            _ = try await store.createProject(named: "Inbox")
            XCTFail("Expected reserved name")
        } catch let error as ProjectError {
            guard case .reservedName = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testDeleteProjectRemovesDirectoryAndRefreshes() async throws {
        let store = ProjectStore(documentsURL: root)
        let project = try await store.createProject(named: "Delete Me")
        try "hello".write(
            to: project.directory.appendingPathComponent("note.txt"),
            atomically: true,
            encoding: .utf8
        )

        try await store.delete(project)

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.directory.path))
        XCTAssertFalse(store.projects.contains { $0.id == project.id })
    }

    func testDeleteRejectsProjectOutsideDocuments() async throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let store = ProjectStore(documentsURL: root)
        let project = Project(directory: outside, remoteHost: nil, isGitRepository: false)

        do {
            try await store.delete(project)
            XCTFail("Expected deletion to be rejected")
        } catch let error as ProjectError {
            guard case .deletionFailed = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }
}
