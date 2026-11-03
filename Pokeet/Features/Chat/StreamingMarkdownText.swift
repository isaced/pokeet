import SwiftUI
import Textual

struct StreamingMarkdownChunks: Equatable {
    let stable: String
    let tail: String
    let openFence: String?

    var tailMarkdown: String {
        guard let openFence else { return tail }
        return tail + "\n" + openFence
    }
}

enum StreamingMarkdownSplitter {
    private struct Fence {
        let character: Character
        let count: Int

        var closingMarker: String {
            String(repeating: String(character), count: count)
        }
    }

    static func split(_ text: String) -> StreamingMarkdownChunks {
        guard !text.isEmpty else {
            return StreamingMarkdownChunks(stable: "", tail: "", openFence: nil)
        }

        let lines = text.components(separatedBy: "\n")
        var blocks: [String] = []
        var current: [String] = []
        var fence: Fence?

        func flush() {
            guard !current.isEmpty else { return }
            blocks.append(current.joined(separator: "\n"))
            current.removeAll(keepingCapacity: true)
        }

        for (index, line) in lines.enumerated() {
            if let openFence = fence {
                if closesFence(line, fence: openFence) {
                    fence = nil
                }
                current.append(line)
                continue
            }

            if let marker = openingFence(line) {
                fence = marker
                current.append(line)
                continue
            }

            let isBlank = line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
            let isLastLine = index == lines.count - 1
            if isBlank, !isLastLine {
                flush()
                continue
            }

            current.append(line)
        }

        return StreamingMarkdownChunks(
            stable: blocks.joined(separator: "\n\n"),
            tail: current.joined(separator: "\n"),
            openFence: fence?.closingMarker
        )
    }

    private static func openingFence(_ line: String) -> Fence? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, first == "`" || first == "~" else {
            return nil
        }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= 3 else { return nil }
        return Fence(character: first, count: count)
    }

    private static func closesFence(_ line: String, fence: Fence) -> Bool {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = trimmed.first, first == fence.character else {
            return false
        }
        let count = trimmed.prefix(while: { $0 == first }).count
        guard count >= fence.count else { return false }
        return trimmed.dropFirst(count).allSatisfy {
            $0 == " " || $0 == "\t" || $0 == "\r"
        }
    }
}

struct StreamingMarkdownText: View {
    let text: String
    let isStreaming: Bool

    var body: some View {
        if isStreaming {
            streamingBody
        } else {
            StructuredText(markdown: text)
                .textual.structuredTextStyle(.gitHub)
                .textual.textSelection(.enabled)
        }
    }

    private var streamingBody: some View {
        let chunks = StreamingMarkdownSplitter.split(text)
        return VStack(alignment: .leading, spacing: 0) {
            if !chunks.stable.isEmpty {
                StructuredText(markdown: chunks.stable)
                    .textual.structuredTextStyle(.gitHub)
            }
            if !chunks.tail.isEmpty {
                StructuredText(markdown: chunks.tailMarkdown)
                    .textual.structuredTextStyle(.gitHub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
