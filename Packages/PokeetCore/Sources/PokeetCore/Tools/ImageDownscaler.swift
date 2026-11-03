import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DownscaledImage: Sendable {
    public let image: ChatImage
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(image: ChatImage, pixelWidth: Int, pixelHeight: Int) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Turns a repository image into something a model can consume: bounded pixels, JPEG, small.
///
/// ImageIO is used instead of UIKit so the kernel stays portable to macOS.
public enum ImageDownscaler {
    public static let maximumSourceBytes = 8 * 1_024 * 1_024
    public static let maxDimension: CGFloat = 1_280
    public static let quality: CGFloat = 0.8

    public static func downscale(_ data: Data, maxDimension: CGFloat = maxDimension) -> DownscaledImage? {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }

        return DownscaledImage(
            image: ChatImage(mimeType: "image/jpeg", data: output as Data),
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}
