import PokeetCore
import SwiftUI
import Textual
import UIKit

struct MessageBubble: View {
    let bubble: ChatViewModel.Bubble

    var body: some View {
        switch bubble.role {
        case .user:
            HStack {
                Spacer(minLength: 48)

                VStack(alignment: .trailing, spacing: 8) {
                    if !bubble.filePaths.isEmpty {
                        FileReferenceChips(paths: bubble.filePaths)
                    }

                    if !bubble.images.isEmpty {
                        UserImageGrid(images: bubble.images)
                    }

                    if !bubble.text.isEmpty {
                        Text(bubble.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(Color.accentColor)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }
        case .reasoning:
            ReasoningBubble(text: bubble.text, isStreaming: bubble.isStreaming)
        case .assistant:
            HStack {
                StructuredText(markdown: bubble.text)
                    .textual.structuredTextStyle(.gitHub)
                    .textual.textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.primary)
                    .background(Color(.secondarySystemBackground).opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Spacer(minLength: 32)
            }
        case .tool:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption2)
                Text(bubble.text)
                    .font(.caption.monospaced())
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(bubble.text)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FileReferenceChips: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(paths, id: \.self) { path in
                HStack(spacing: 5) {
                    Image(systemName: "doc.text")
                    Text("@\(path)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
    }
}

private struct UserImageGrid: View {
    let images: [ChatImage]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.prefix(4).enumerated()), id: \.offset) { _, image in
                if let uiImage = UIImage(data: image.data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(
                            width: images.count == 1 ? 200 : 72,
                            height: images.count == 1 ? 150 : 72
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .frame(
                            width: images.count == 1 ? 200 : 72,
                            height: images.count == 1 ? 150 : 72
                        )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(images.count) attached image(s)")
    }
}
