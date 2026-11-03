import Foundation

enum DiffLineKind: Equatable {
    case added
    case removed
    case hunk
    case fileHeader
    case metadata
    case context
}

struct DiffDocument {
    struct Line: Identifiable {
        let id: Int
        let kind: DiffLineKind
        let raw: String
        let content: String
        let prefix: String?
        let oldIndex: Int?
        let newIndex: Int?
    }

    let lines: [Line]
    let oldText: String
    let newText: String
    let oldLineCount: Int
    let newLineCount: Int

    init(_ text: String) {
        var rawLines = text.components(separatedBy: "\n")
        if rawLines.last?.isEmpty == true {
            rawLines.removeLast()
        }

        var oldLines: [String] = []
        var newLines: [String] = []
        var parsed: [Line] = []
        parsed.reserveCapacity(rawLines.count)
        var inHunk = false

        for (index, raw) in rawLines.enumerated() {
            let kind: DiffLineKind
            if raw.hasPrefix("diff --git") {
                inHunk = false
                kind = .metadata
            } else if raw.hasPrefix("@@") {
                inHunk = true
                kind = .hunk
            } else if raw.hasPrefix("\\") {
                kind = .metadata
            } else if inHunk {
                if raw.hasPrefix("+") {
                    kind = .added
                } else if raw.hasPrefix("-") {
                    kind = .removed
                } else {
                    kind = .context
                }
            } else if raw.hasPrefix("+++") || raw.hasPrefix("---") {
                kind = .fileHeader
            } else {
                kind = .metadata
            }

            let content: String
            let prefix: String?
            var oldIndex: Int?
            var newIndex: Int?

            switch kind {
            case .added:
                prefix = "+"
                content = String(raw.dropFirst())
                newIndex = newLines.count
                newLines.append(content)
            case .removed:
                prefix = "-"
                content = String(raw.dropFirst())
                oldIndex = oldLines.count
                oldLines.append(content)
            case .context:
                if raw.hasPrefix(" ") {
                    prefix = " "
                    content = String(raw.dropFirst())
                } else {
                    prefix = raw.isEmpty ? " " : ""
                    content = raw
                }
                oldIndex = oldLines.count
                oldLines.append(content)
                newIndex = newLines.count
                newLines.append(content)
            default:
                prefix = nil
                content = raw
            }

            parsed.append(Line(
                id: index,
                kind: kind,
                raw: raw,
                content: content,
                prefix: prefix,
                oldIndex: oldIndex,
                newIndex: newIndex
            ))
        }

        lines = parsed
        oldText = oldLines.joined(separator: "\n")
        newText = newLines.joined(separator: "\n")
        oldLineCount = oldLines.count
        newLineCount = newLines.count
    }
}
