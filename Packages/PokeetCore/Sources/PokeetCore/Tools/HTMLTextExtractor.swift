import Foundation

public enum HTMLTextExtractor {
    public static func extract(_ html: String, markdown: Bool) -> String {
        var text = html
        text = replace(text, "<!--[\\s\\S]*?-->", "")
        for tag in ["script", "style", "noscript", "template", "svg"] {
            text = replace(
                text,
                "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>",
                "",
                options: [.caseInsensitive]
            )
        }

        if markdown {
            for level in 1...6 {
                text = replace(
                    text,
                    "<h\(level)\\b[^>]*>([\\s\\S]*?)</h\(level)>",
                    String(repeating: "#", count: level) + " $1\n",
                    options: [.caseInsensitive]
                )
            }
            text = replace(
                text,
                "<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
                "[$2]($1)",
                options: [.caseInsensitive]
            )
            text = replace(text, "<li\\b[^>]*>", "\n- ", options: [.caseInsensitive])
        }

        text = replace(text, "<br\\s*/?>", "\n", options: [.caseInsensitive])
        let blockTags = "p|div|section|article|header|footer|main|aside|ul|ol|li|tr|table|h[1-6]|pre|blockquote"
        text = replace(text, "<(?:\(blockTags))\\b[^>]*>", "\n", options: [.caseInsensitive])
        text = replace(text, "</(?:\(blockTags))\\s*>", "\n", options: [.caseInsensitive])
        text = replace(text, "<[^>]+>", "")
        text = decodeEntities(text)
        text = replace(text, "[ \\t\\x0B\\f\\r]+", " ")
        text = replace(text, " *\\n *", "\n")
        text = replace(text, "\\n{3,}", "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(
        _ text: String,
        _ pattern: String,
        _ template: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private static func decodeEntities(_ text: String) -> String {
        var result = text
        let namedEntities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'"
        ]
        for (entity, value) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: value)
        }

        guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else {
            return result
        }
        let matches = regex.matches(
            in: result,
            options: [],
            range: NSRange(result.startIndex..<result.endIndex, in: result)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let prefixRange = Range(match.range(at: 1), in: result),
                  let valueRange = Range(match.range(at: 2), in: result)
            else {
                continue
            }
            let isHex = !result[prefixRange].isEmpty
            guard let value = Int(result[valueRange], radix: isHex ? 16 : 10),
                  let scalar = UnicodeScalar(value)
            else {
                continue
            }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return result
    }
}
