import Foundation

public struct ReadImageTool: AgentTool {
    public static let toolName = "read_image"

    public init() {}

    public var capabilities: Set<ToolCapability> { [.readFiles] }

    public var schema: ToolSchema {
        ToolSchema(
            name: Self.toolName,
            description: """
            Attach an image from the repository (screenshot, design, diagram) so you can look at \
            it. Supports PNG, JPEG, GIF and WebP up to 8 MB; it is downscaled and sent as JPEG. \
            Images cost tokens, so read one only when the visual itself matters.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object([
                        "type": .string("string"),
                        "description": .string("Image path relative to the repository root.")
                    ])
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            var path: String
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        let path = arguments.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw ToolError.invalidInput("path must not be empty.")
        }

        let url: URL
        let info: FileInfo
        do {
            try context.workspace.validate(path)
            url = try PathSandbox(root: context.workspace.root).resolve(path)
            info = try FileProbe.probe(path, in: context.workspace)
        } catch {
            throw ToolError.workspace(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }

        guard info.exists else {
            return ToolOutput(content: "No such file: \(path)")
        }
        guard !info.isDirectory else {
            return ToolOutput(content: "\(path) is a directory, not an image.")
        }
        guard info.sizeBytes <= ImageDownscaler.maximumSourceBytes else {
            return ToolOutput(
                content: "\(path) is \(info.sizeDescription), larger than the "
                    + "\(ByteCountFormatter.string(fromByteCount: Int64(ImageDownscaler.maximumSourceBytes), countStyle: .file)) image limit."
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolError.workspace(error.localizedDescription)
        }

        guard let downscaled = ImageDownscaler.downscale(data) else {
            return ToolOutput(
                content: "Could not decode \(path) as an image. Supported formats: PNG, JPEG, GIF, WebP."
            )
        }

        let size = ByteCountFormatter.string(fromByteCount: Int64(downscaled.image.data.count), countStyle: .file)
        return ToolOutput(
            content: "Attached \(path) — \(downscaled.pixelWidth)×\(downscaled.pixelHeight) px, "
                + "\(size) JPEG. The image content follows in this turn.",
            images: [downscaled.image]
        )
    }
}
