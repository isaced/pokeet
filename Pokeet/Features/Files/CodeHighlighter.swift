import Foundation
import HighlightSwift

enum CodeLanguage {
    static func alias(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "makefile", "gnumakefile":
            return "makefile"
        case "dockerfile":
            return "dockerfile"
        case "podfile", "gemfile", "rakefile":
            return "ruby"
        case "package.resolved":
            return "json"
        default:
            break
        }

        switch (path as NSString).pathExtension.lowercased() {
        case "swift":
            return "swift"
        case "m", "mm":
            return "objectivec"
        case "h", "c":
            return "c"
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx":
            return "cpp"
        case "cs":
            return "csharp"
        case "js", "mjs", "cjs", "jsx":
            return "javascript"
        case "ts", "tsx":
            return "typescript"
        case "json", "jsonc":
            return "json"
        case "yaml", "yml":
            return "yaml"
        case "toml":
            return "toml"
        case "xml", "plist", "svg", "vue", "svelte":
            return "xml"
        case "html", "htm":
            return "xml"
        case "css":
            return "css"
        case "scss":
            return "scss"
        case "less":
            return "less"
        case "sh", "bash", "zsh", "env":
            return "bash"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "go":
            return "go"
        case "rs":
            return "rust"
        case "java":
            return "java"
        case "kt", "kts":
            return "kotlin"
        case "php":
            return "php"
        case "sql":
            return "sql"
        case "md", "markdown":
            return "markdown"
        case "gradle":
            return "gradle"
        case "graphql", "gql":
            return "graphql"
        case "proto":
            return "protobuf"
        case "tex", "latex":
            return "tex"
        default:
            return nil
        }
    }
}

enum CodeHighlighter {
    static let maximumCharacters = 120_000
    private static let highlighter = Highlight()

    static func highlight(
        text: String,
        language: String,
        isDark: Bool,
        expectedLineCount: Int
    ) async -> [AttributedString]? {
        guard !text.isEmpty, text.count <= maximumCharacters else {
            return nil
        }

        let leading = text.prefix { $0.isWhitespace }
        let trailing = text.reversed().prefix { $0.isWhitespace }.reversed()
        let core = text.dropFirst(leading.count).dropLast(trailing.count)
        guard !core.isEmpty else { return nil }

        let colors: HighlightColors = isDark ? .dark(.github) : .light(.github)
        do {
            let highlighted = try await highlighter.attributedText(
                String(core),
                language: language,
                colors: colors
            )
            var combined = AttributedString(String(leading))
            combined.append(highlighted)
            combined.append(AttributedString(String(trailing)))
            let lines = combined.linesPreservingAttributes()
            return lines.count == expectedLineCount ? lines : nil
        } catch {
            return nil
        }
    }
}

extension AttributedString {
    func linesPreservingAttributes() -> [AttributedString] {
        let characters = characters
        guard !characters.isEmpty else {
            return [AttributedString("")]
        }

        var lines: [AttributedString] = []
        var start = characters.startIndex
        var index = characters.startIndex
        while index < characters.endIndex {
            if characters[index] == "\n" {
                lines.append(AttributedString(self[start..<index]))
                start = characters.index(after: index)
            }
            index = characters.index(after: index)
        }
        lines.append(AttributedString(self[start..<characters.endIndex]))
        return lines
    }
}
