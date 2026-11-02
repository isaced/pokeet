import Foundation

public enum LineDiff {
    public static let defaultContext = 3
    public static let largeFileLineLimit = 4_000

    public static func compare(old: String?, new: String, context: Int = defaultContext) -> FileDiff {
        let oldLines = splitLines(old ?? "")
        let newLines = splitLines(new)

        if old == nil {
            return allAdded(newLines)
        }

        if oldLines.count > largeFileLineLimit || newLines.count > largeFileLineLimit {
            return fullReplacement(old: oldLines, new: newLines)
        }

        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.insert(offset)
            case .insert(let offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        var operations: [Operation] = []
        operations.reserveCapacity(oldLines.count + newLines.count)
        var oldIndex = 0
        var newIndex = 0

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedOffsets.contains(oldIndex) {
                operations.append(.removed(oldNumber: oldIndex + 1, text: oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, insertedOffsets.contains(newIndex) {
                operations.append(.added(newNumber: newIndex + 1, text: newLines[newIndex]))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                operations.append(.context(
                    oldNumber: oldIndex + 1,
                    newNumber: newIndex + 1,
                    text: oldLines[oldIndex]
                ))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < oldLines.count {
                operations.append(.removed(oldNumber: oldIndex + 1, text: oldLines[oldIndex]))
                oldIndex += 1
            } else {
                operations.append(.added(newNumber: newIndex + 1, text: newLines[newIndex]))
                newIndex += 1
            }
        }

        let changeIndices = operations.indices.filter {
            if case .context = operations[$0] { return false }
            return true
        }
        guard !changeIndices.isEmpty else { return .empty }

        var ranges: [ClosedRange<Int>] = []
        for index in changeIndices {
            let start = max(0, index - context)
            let end = min(operations.count - 1, index + context)
            if let last = ranges.last, start <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, end)
            } else {
                ranges.append(start...end)
            }
        }

        var hunks: [DiffHunk] = []
        var addedLines = 0
        var removedLines = 0

        for range in ranges {
            let slice = operations[range]
            let lines = slice.map(\.diffLine)
            let oldNumbers = lines.compactMap(\.oldNumber)
            let newNumbers = lines.compactMap(\.newNumber)

            addedLines += slice.filter {
                if case .added = $0 { return true }
                return false
            }.count
            removedLines += slice.filter {
                if case .removed = $0 { return true }
                return false
            }.count

            hunks.append(DiffHunk(
                oldStart: oldNumbers.first ?? 0,
                oldCount: oldNumbers.count,
                newStart: newNumbers.first ?? 0,
                newCount: newNumbers.count,
                lines: lines
            ))
        }

        return FileDiff(hunks: hunks, addedLines: addedLines, removedLines: removedLines)
    }

    private static func allAdded(_ newLines: [String]) -> FileDiff {
        guard !newLines.isEmpty else { return .empty }
        let lines = newLines.enumerated().map {
            DiffLine(kind: .added, oldNumber: nil, newNumber: $0.offset + 1, text: $0.element)
        }
        let hunk = DiffHunk(
            oldStart: 0,
            oldCount: 0,
            newStart: 1,
            newCount: newLines.count,
            lines: lines
        )
        return FileDiff(hunks: [hunk], addedLines: newLines.count, removedLines: 0)
    }

    private static func fullReplacement(old: [String], new: [String]) -> FileDiff {
        guard !old.isEmpty || !new.isEmpty else { return .empty }

        var lines: [DiffLine] = old.enumerated().map {
            DiffLine(kind: .removed, oldNumber: $0.offset + 1, newNumber: nil, text: $0.element)
        }
        lines += new.enumerated().map {
            DiffLine(kind: .added, oldNumber: nil, newNumber: $0.offset + 1, text: $0.element)
        }

        let hunk = DiffHunk(
            oldStart: old.isEmpty ? 0 : 1,
            oldCount: old.count,
            newStart: new.isEmpty ? 0 : 1,
            newCount: new.count,
            lines: lines
        )
        return FileDiff(hunks: [hunk], addedLines: new.count, removedLines: old.count)
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }

    private enum Operation {
        case context(oldNumber: Int, newNumber: Int, text: String)
        case removed(oldNumber: Int, text: String)
        case added(newNumber: Int, text: String)

        var diffLine: DiffLine {
            switch self {
            case .context(let oldNumber, let newNumber, let text):
                DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber, text: text)
            case .removed(let oldNumber, let text):
                DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil, text: text)
            case .added(let newNumber, let text):
                DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber, text: text)
            }
        }
    }
}
