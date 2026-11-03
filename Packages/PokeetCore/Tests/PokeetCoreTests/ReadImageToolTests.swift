import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PokeetCore

struct ReadImageToolTests {
    @Test func attachesDownscaledImage() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try makePNG(width: 400, height: 200).write(to: directory.url.appending(path: "shot.png"))

        let output = try await read(#"{"path":"shot.png"}"#, in: directory)

        #expect(output.images.count == 1)
        #expect(output.images.first?.mimeType == "image/jpeg")
        #expect(output.images.first?.data.isEmpty == false)
        #expect(output.content.contains("Attached shot.png"))
        #expect(output.content.contains("400×200"))
    }

    @Test func capsPixelSize() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try makePNG(width: 3_000, height: 1_500).write(to: directory.url.appending(path: "wide.png"))

        let output = try await read(#"{"path":"wide.png"}"#, in: directory)

        let downscaled = try ImageDownscaler.downscale(
            try Data(contentsOf: directory.url.appending(path: "wide.png"))
        )
        #expect(downscaled?.pixelWidth == 1_280)
        #expect(output.content.contains("1280×640"))
    }

    @Test func reportsNonImages() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("notes.txt", "not an image\n")

        let output = try await read(#"{"path":"notes.txt"}"#, in: directory)
        #expect(output.images.isEmpty)
        #expect(output.content.contains("Could not decode"))
    }

    @Test func reportsMissingFileAndDirectory() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        try directory.write("folder/keep.txt", "x\n")

        let missing = try await read(#"{"path":"nope.png"}"#, in: directory)
        #expect(missing.content.contains("No such file"))

        let folder = try await read(#"{"path":"folder"}"#, in: directory)
        #expect(folder.content.contains("is a directory"))
    }

    @Test func rejectsOversizedFiles() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        let big = Data(repeating: 0x89, count: ImageDownscaler.maximumSourceBytes + 1)
        try big.write(to: directory.url.appending(path: "huge.png"))

        let output = try await read(#"{"path":"huge.png"}"#, in: directory)
        #expect(output.images.isEmpty)
        #expect(output.content.contains("image limit"))
    }

    @Test func rejectsPathsOutsideTheWorkspace() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        await #expect(throws: ToolError.self) {
            _ = try await read(#"{"path":"../escape.png"}"#, in: directory)
        }
    }

    private func read(_ arguments: String, in directory: TestDirectory) async throws -> ToolOutput {
        try await ReadImageTool().execute(
            arguments: Data(arguments.utf8),
            context: ToolContext(workspace: FileWorkspace(root: directory.url))
        )
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())

        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
