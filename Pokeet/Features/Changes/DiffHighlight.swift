import Foundation

/// The highlighted old and new sides of a diff, ready to be looked up per line.
///
/// A diff is rendered from two texts — the side before the change and the side
/// after it — so each side is highlighted once and then indexed by the line number
/// the diff already carries, zero based (`DiffLine.newNumber - 1`,
/// `DiffDocument.Line.newIndex`).
struct DiffHighlight: Equatable {
    let oldLines: [AttributedString]?
    let newLines: [AttributedString]?

    static let none = DiffHighlight(oldLines: nil, newLines: nil)

    /// Picks the highlighted text for a single diff line.
    ///
    /// Context lines exist on both sides; the new side wins so the rendered text
    /// matches what the file looks like after the change.
    func line(oldIndex: Int?, newIndex: Int?) -> AttributedString? {
        if let newIndex, let lines = newLines, lines.indices.contains(newIndex) {
            return lines[newIndex]
        }
        if let oldIndex, let lines = oldLines, lines.indices.contains(oldIndex) {
            return lines[oldIndex]
        }
        return nil
    }

    /// Highlights both sides of a diff for `path`.
    ///
    /// Unknown languages, oversized files and sides the highlighter cannot map
    /// back to their input lines fall back to plain text.
    static func load(
        path: String,
        oldText: String,
        newText: String,
        isDark: Bool
    ) async -> DiffHighlight {
        guard let language = CodeLanguage.alias(for: path) else { return .none }

        let oldLines = await highlight(oldText, language: language, isDark: isDark)
        let newLines = await highlight(newText, language: language, isDark: isDark)
        return DiffHighlight(oldLines: oldLines, newLines: newLines)
    }

    private static func highlight(
        _ text: String,
        language: String,
        isDark: Bool
    ) async -> [AttributedString]? {
        await CodeHighlighter.highlight(
            text: text,
            language: language,
            isDark: isDark,
            expectedLineCount: lineCount(of: text)
        )
    }

    /// Counts the lines `CodeHighlighter` returns for `text`.
    ///
    /// Every `\n` starts a new line, and a trailing newline leaves a final empty
    /// line, which is exactly how the highlighter splits its own output. Diff line
    /// numbers index the same split, so line `n` maps to index `n - 1`.
    static func lineCount(of text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.components(separatedBy: "\n").count
    }
}
