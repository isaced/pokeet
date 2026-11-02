import Foundation

struct TestDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pokeet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ relativePath: String, _ content: String) throws {
        let fileURL = url.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
