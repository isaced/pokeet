import PokeetCore
import SwiftUI
import Textual
import UIKit

struct MessageBubble: View, Equatable {
    let bubble: ChatViewModel.Bubble

    nonisolated static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        let a = lhs.bubble
        let b = rhs.bubble
        return a.id == b.id
            && a.role == b.role
            && a.text == b.text
            && a.isStreaming == b.isStreaming
            && a.filePaths == b.filePaths
            && a.images.count == b.images.count
            && a.reasoningDuration == b.reasoningDuration
    }

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
            ReasoningBubble(
                text: bubble.text,
                isStreaming: bubble.isStreaming,
                duration: bubble.reasoningDuration
            )
        case .assistant:
            HStack {
                Group {
                    if bubble.isStreaming {
                        Text(bubble.text)
                    } else {
                        StructuredText(markdown: bubble.text)
                            .textual.structuredTextStyle(.gitHub)
                            .textual.textSelection(.enabled)
                    }
                }
                .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
        case .tool:
            HStack(alignment: .center, spacing: 6) {
                if bubble.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.secondary)
                } else {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                }
                Text(bubble.text)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .notice:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption2)
                Text(bubble.text)
                    .font(.caption)
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
                if let uiImage = DecodedImageCache.image(for: image.data) {
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

@MainActor
enum DecodedImageCache {
    private static let cache: NSCache<NSData, UIImage> = {
        let cache = NSCache<NSData, UIImage>()
        cache.countLimit = 32
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func image(for data: Data) -> UIImage? {
        let key = data as NSData
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }
}
