import Foundation
import PokeetCore
import UIKit

enum ChatImageProcessor {
    static let maxDimension: CGFloat = 1_280

    static func makeChatImage(from data: Data) -> ChatImage? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let target = CGSize(
            width: max(1, floor(image.size.width * scale)),
            height: max(1, floor(image.size.height * scale))
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { context in
            let rect = CGRect(origin: .zero, size: target)
            context.cgContext.setFillColor(UIColor.systemBackground.cgColor)
            context.cgContext.fill(rect)
            image.draw(in: rect)
        }

        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else {
            return nil
        }
        return ChatImage(mimeType: "image/jpeg", data: jpeg)
    }
}
