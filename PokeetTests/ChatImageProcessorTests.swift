import UIKit
import XCTest
@testable import Pokeet

final class ChatImageProcessorTests: XCTestCase {
    func testDownscalesAndConvertsToJPEG() throws {
        let size = CGSize(width: 3_000, height: 2_000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let source = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let data = try XCTUnwrap(source.pngData())

        let image = try XCTUnwrap(ChatImageProcessor.makeChatImage(from: data))

        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertFalse(image.data.isEmpty)

        let decoded = try XCTUnwrap(UIImage(data: image.data))
        XCTAssertLessThanOrEqual(max(decoded.size.width, decoded.size.height), 1_280)
        XCTAssertEqual(decoded.size.width / decoded.size.height, 1.5, accuracy: 0.01)
    }

    func testRejectsInvalidData() {
        XCTAssertNil(ChatImageProcessor.makeChatImage(from: Data("not an image".utf8)))
    }
}
