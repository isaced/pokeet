import Foundation

public struct FileInfo: Sendable, Equatable {
    public var path: String
    public var exists: Bool
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var sizeBytes: Int
    public var lineCount: Int
    public var isText: Bool
    public var modified: Date?

    public init(
        path: String,
        exists: Bool,
        isDirectory: Bool = false,
        isSymbolicLink: Bool = false,
        sizeBytes: Int = 0,
        lineCount: Int = 0,
        isText: Bool = true,
        modified: Date? = nil
    ) {
        self.path = path
        self.exists = exists
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.sizeBytes = sizeBytes
        self.lineCount = lineCount
        self.isText = isText
        self.modified = modified
    }

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

/// Shared metadata lookup for `file_info` and the script sandbox.
public enum FileProbe {
    /// Lines are counted only for files the agent could actually read.
    public static let lineCountLimit = 512_000
    private static let textSampleBytes = 8_192

    public static func probe(
        _ path: String,
        in workspace: any Workspace,
        lineCountLimit: Int = lineCountLimit
    ) throws -> FileInfo {
        let sandbox = PathSandbox(root: workspace.root)
        let url = try sandbox.resolve(path, allowRoot: true)

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return FileInfo(path: path, exists: false)
        }
        if isDirectory.boolValue {
            return FileInfo(path: path, exists: true, isDirectory: true)
        }

        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey
        ])
        let size = values?.fileSize ?? 0
        let sample = readSample(at: url, limit: textSampleBytes)
        let isText = Self.looksLikeText(sample)

        var lines = 0
        if isText, size <= lineCountLimit,
           let text = try? workspace.read(path, maxBytes: lineCountLimit) {
            lines = lineCount(of: text)
        }

        return FileInfo(
            path: path,
            exists: true,
            isSymbolicLink: values?.isSymbolicLink ?? false,
            sizeBytes: size,
            lineCount: lines,
            isText: isText,
            modified: values?.contentModificationDate
        )
    }

    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 0
        for character in text where character == "\n" {
            count += 1
        }
        return text.hasSuffix("\n") ? count : count + 1
    }

    private static func readSample(at url: URL, limit: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? Data()
    }

    /// A file is text when the sample decodes as UTF-8 and holds no NUL bytes.
    private static func looksLikeText(_ sample: Data) -> Bool {
        guard !sample.isEmpty else { return true }
        if sample.contains(0) { return false }
        return String(data: sample, encoding: .utf8) != nil
    }
}
