public struct DiffLine: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case context
        case added
        case removed
    }

    public let kind: Kind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct DiffHunk: Sendable, Hashable, Identifiable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let lines: [DiffLine]

    public var id: String {
        "\(oldStart):\(oldCount)-\(newStart):\(newCount)"
    }

    public var header: String {
        "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
    }

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct FileDiff: Sendable, Hashable {
    public let hunks: [DiffHunk]
    public let addedLines: Int
    public let removedLines: Int

    public var isEmpty: Bool { hunks.isEmpty }

    public init(hunks: [DiffHunk], addedLines: Int, removedLines: Int) {
        self.hunks = hunks
        self.addedLines = addedLines
        self.removedLines = removedLines
    }

    public static let empty = FileDiff(hunks: [], addedLines: 0, removedLines: 0)
}
