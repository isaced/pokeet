import XCTest
@testable import Pokeet

@MainActor
final class ProjectFilePickerTests: XCTestCase {
    func testListsFilesRecursivelyWithoutDirectoriesOrNoise() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = [
            "Sources/main.swift",
            "README.md",
            "Sources/Nested/tool.swift",
            ".DS_Store"
        ]
        for path in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "content\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let project = Project(directory: directory, remoteHost: nil, isGitRepository: false)
        let model = ProjectFilePickerModel(project: project)
        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.files, [
            "README.md",
            "Sources/main.swift",
            "Sources/Nested/tool.swift"
        ])
        XCTAssertFalse(model.isTruncated)
    }

    func testReportsTruncation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0..<5 {
            try "content\n".write(
                to: directory.appendingPathComponent("file-\(index).txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let project = Project(directory: directory, remoteHost: nil, isGitRepository: false)
        let model = ProjectFilePickerModel(project: project, entryLimit: 3)
        await model.load()

        XCTAssertEqual(model.files.count, 3)
        XCTAssertTrue(model.isTruncated)
    }
}
