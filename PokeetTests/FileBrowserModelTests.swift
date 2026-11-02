import PokeetCore
import XCTest
@testable import Pokeet

@MainActor
final class FileBrowserModelTests: XCTestCase {
    private func makeProject() throws -> (Project, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-files-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let files: [(String, String)] = [
            ("b.txt", "second\n"),
            ("a.md", "# First\n"),
            ("Sources/main.swift", "print(1)\n"),
            ("Sources/Nested/foo.swift", "let foo = 1\n"),
            (".DS_Store", "junk")
        ]
        for (path, content) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        let project = Project(directory: directory, remoteHost: nil, isGitRepository: false)
        return (project, directory)
    }

    func testListsDirectoriesFirstAndFiltersNoise() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DirectoryListingModel(project: project, path: "")
        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entries.map(\.name), ["Sources", "a.md", "b.txt"])
        XCTAssertEqual(model.entries.first?.isDirectory, true)
        XCTAssertFalse(model.isTruncated)
    }

    func testListsNestedDirectory() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DirectoryListingModel(project: project, path: "Sources")
        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entries.map(\.name), ["Nested", "main.swift"])
        XCTAssertEqual(model.entries.map(\.path), ["Sources/Nested", "Sources/main.swift"])
    }

    func testReportsTruncation() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DirectoryListingModel(project: project, path: "", entryLimit: 2)
        await model.load()

        XCTAssertEqual(model.entries.count, 2)
        XCTAssertTrue(model.isTruncated)
    }

    func testReportsMissingDirectory() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = DirectoryListingModel(project: project, path: "missing")
        await model.load()

        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func testLoadsFileDetailWithLineNumbers() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = FileDetailModel(project: project, path: "Sources/main.swift")
        await model.load()

        XCTAssertEqual(model.name, "main.swift")
        XCTAssertEqual(model.text, "print(1)\n")
        XCTAssertEqual(model.lines, ["print(1)", ""])
        XCTAssertNil(model.errorMessage)
    }

    func testRejectsBinaryFilePreview() async throws {
        let (project, directory) = try makeProject()
        defer { try? FileManager.default.removeItem(at: directory) }

        let binaryURL = directory.appendingPathComponent("image.bin")
        try Data([0, 1, 2, 3]).write(to: binaryURL)

        let model = FileDetailModel(project: project, path: "image.bin")
        await model.load()

        XCTAssertNil(model.text)
        XCTAssertEqual(
            model.errorMessage,
            "Binary file cannot be read as text: image.bin"
        )
    }
}
