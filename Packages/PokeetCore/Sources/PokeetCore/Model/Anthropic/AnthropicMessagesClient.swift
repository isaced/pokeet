import Foundation

public struct AnthropicMessagesClient: ModelClient {
    private let baseURL: String
    private let model: String
    private let apiKey: String
    private let maxOutputTokens: Int
    private let session: URLSession

    public init(
        baseURL: String,
        model: String,
        apiKey: String,
        maxOutputTokens: Int = 8192,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.maxOutputTokens = max(1, maxOutputTokens)
        self.session = session
    }

    public func complete(_ request: ChatRequest) async throws -> ChatResponse {
        let urlRequest = try makeURLRequest(request, stream: false)

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ModelError.invalidResponse("Missing HTTP response")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ModelError.http(
                    status: httpResponse.statusCode,
                    message: ModelHTTP.errorMessage(from: data)
                )
            }

            let wireResponse: WireResponse
            do {
                wireResponse = try JSONDecoder().decode(WireResponse.self, from: data)
            } catch {
                throw ModelError.decoding(error.localizedDescription)
            }

            return wireResponse.chatResponse()
        } catch {
            throw ModelHTTP.mapTransportError(error)
        }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: ModelHTTP.mapTransportError(error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func performStream(
        _ request: ChatRequest,
        continuation: AsyncThrowingStream<ModelStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(request, stream: true)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ModelError.invalidResponse("Missing HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = try await ModelHTTP.readErrorBody(bytes)
            throw ModelError.http(
                status: httpResponse.statusCode,
                message: ModelHTTP.errorMessage(from: body)
            )
        }

        var content = ""
        var toolCalls: [Int: ToolCallBuilder] = [:]
        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0
        var finishReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = SSELines.payload(from: line),
                  let data = payload.data(using: .utf8)
            else { continue }

            let event: WireStreamEvent
            do {
                event = try JSONDecoder().decode(WireStreamEvent.self, from: data)
            } catch {
                throw ModelError.decoding(error.localizedDescription)
            }

            switch event.type {
            case "message_start":
                if let usage = event.message?.usage {
                    inputTokens = usage.totalInputTokens
                    cachedTokens = usage.cacheReadInputTokens ?? 0
                    outputTokens = usage.outputTokens ?? 0
                }

            case "content_block_start":
                guard let index = event.index, let block = event.contentBlock else { continue }
                if block.type == "tool_use" {
                    toolCalls[index] = ToolCallBuilder(
                        id: block.id ?? UUID().uuidString,
                        name: block.name ?? "",
                        arguments: ""
                    )
                }

            case "content_block_delta":
                guard let delta = event.delta else { continue }
                switch delta.type {
                case "text_delta":
                    if let text = delta.text, !text.isEmpty {
                        content += text
                        continuation.yield(.textDelta(text))
                    }
                case "thinking_delta":
                    if let thinking = delta.thinking, !thinking.isEmpty {
                        continuation.yield(.reasoningDelta(thinking))
                    }
                case "input_json_delta":
                    guard let index = event.index else { continue }
                    var builder = toolCalls[index] ?? ToolCallBuilder(
                        id: UUID().uuidString,
                        name: "",
                        arguments: ""
                    )
                    builder.arguments += delta.partialJSON ?? ""
                    toolCalls[index] = builder
                default:
                    continue
                }

            case "message_delta":
                if let reason = event.delta?.stopReason {
                    finishReason = reason
                }
                if let usage = event.usage {
                    outputTokens = usage.outputTokens ?? outputTokens
                    inputTokens = max(inputTokens, usage.totalInputTokens)
                    cachedTokens = max(cachedTokens, usage.cacheReadInputTokens ?? 0)
                }

            case "message_stop":
                continue

            case "error":
                throw ModelError.invalidResponse(event.error?.message ?? "Stream error")

            default:
                continue
            }
        }

        let calls = toolCalls
            .sorted { $0.key < $1.key }
            .compactMap { _, builder -> ToolCall? in
                guard !builder.name.isEmpty else { return nil }
                return ToolCall(
                    id: builder.id,
                    name: builder.name,
                    arguments: builder.arguments.isEmpty ? "{}" : builder.arguments
                )
            }

        let usage = inputTokens > 0 || outputTokens > 0
            ? ModelUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cachedInputTokens: cachedTokens,
                reasoningTokens: nil
            )
            : nil

        continuation.yield(.completed(ChatResponse(
            message: .assistant(
                content.isEmpty ? nil : content,
                toolCalls: calls.isEmpty ? nil : calls
            ),
            finishReason: finishReason,
            usage: usage
        )))
    }

    private func makeURLRequest(_ request: ChatRequest, stream: Bool) throws -> URLRequest {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty,
              let url = ModelHTTP.validated(
                  ModelHTTP.normalizedURL(baseURL: baseURL, appending: "messages")
              )
        else {
            throw ModelError.notConfigured
        }

        let body = Self.requestBody(
            request,
            model: model,
            maxOutputTokens: maxOutputTokens,
            stream: stream
        )
        let data = try ModelHTTP.encodeJSON(body)

        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json"
        ]
        if stream {
            headers["Accept"] = "text/event-stream"
        }

        return ModelHTTP.request(url: url, headers: headers, body: data)
    }

    private static func requestBody(
        _ request: ChatRequest,
        model: String,
        maxOutputTokens: Int,
        stream: Bool
    ) -> JSONValue {
        let system = request.messages
            .filter { $0.role == .system }
            .compactMap(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var turns = AnthropicTurns()

        for message in request.messages where message.role != .system {
            switch message.role {
            case .user:
                for image in message.images ?? [] {
                    turns.append(role: "user", block: .object([
                        "type": .string("image"),
                        "source": .object([
                            "type": .string("base64"),
                            "media_type": .string(image.mimeType),
                            "data": .string(image.base64)
                        ])
                    ]))
                }
                if let content = message.content, !content.isEmpty {
                    turns.append(role: "user", block: .object([
                        "type": .string("text"),
                        "text": .string(content)
                    ]))
                }

            case .assistant:
                var blocks: [JSONValue] = []
                if let content = message.content, !content.isEmpty {
                    blocks.append(.object([
                        "type": .string("text"),
                        "text": .string(content)
                    ]))
                }
                for call in message.toolCalls ?? [] {
                    blocks.append(.object([
                        "type": .string("tool_use"),
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": jsonObject(from: call.arguments)
                    ]))
                }
                for block in blocks {
                    turns.append(role: "assistant", block: block)
                }

            case .tool:
                turns.append(role: "user", block: .object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(message.toolCallID ?? ""),
                    "content": .string(message.content ?? "")
                ]))

            case .system:
                break
            }
        }

        var messages = turns.values
        if let first = messages.first,
           case .object(let object) = first,
           object["role"] == .string("assistant") {
            messages.insert(.object([
                "role": .string("user"),
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Continue.")])
                ])
            ]), at: 0)
        }

        var object: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxOutputTokens)),
            "messages": .array(messages),
            "stream": .bool(stream)
        ]

        if !system.isEmpty {
            object["system"] = .string(system)
        }

        if !request.tools.isEmpty {
            object["tools"] = .array(
                request.tools
                    .sorted { $0.name < $1.name }
                    .map { tool in
                        .object([
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "input_schema": tool.parameters
                        ])
                    }
            )
            object["tool_choice"] = .object(["type": .string("auto")])
        }

        return .object(object)
    }

    private static func jsonObject(from arguments: String) -> JSONValue {
        guard let data = arguments.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value
        else {
            return .object([:])
        }
        return value
    }
}

private struct AnthropicTurns {
    private(set) var values: [JSONValue] = []
    private var roles: [String] = []

    mutating func append(role: String, block: JSONValue) {
        if roles.last == role,
           case .object(var object) = values[values.count - 1],
           case .array(var blocks) = object["content"] {
            blocks.append(block)
            object["content"] = .array(blocks)
            values[values.count - 1] = .object(object)
        } else {
            values.append(.object([
                "role": .string(role),
                "content": .array([block])
            ]))
            roles.append(role)
        }
    }
}

private struct ToolCallBuilder {
    var id: String
    var name: String
    var arguments: String
}

private struct WireResponse: Decodable {
    let content: [WireContentBlock]
    let stopReason: String?
    let usage: WireUsage?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
        case usage
    }

    func chatResponse() -> ChatResponse {
        var text = ""
        var calls: [ToolCall] = []

        for block in content {
            switch block.type {
            case "text":
                if let value = block.text, !value.isEmpty {
                    text += value
                }
            case "tool_use":
                guard let name = block.name, !name.isEmpty else { continue }
                calls.append(ToolCall(
                    id: block.id ?? UUID().uuidString,
                    name: name,
                    arguments: block.argumentString
                ))
            default:
                continue
            }
        }

        return ChatResponse(
            message: .assistant(
                text.isEmpty ? nil : text,
                toolCalls: calls.isEmpty ? nil : calls
            ),
            finishReason: stopReason,
            usage: usage?.modelUsage
        )
    }
}

private struct WireContentBlock: Decodable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: JSONValue?

    var argumentString: String {
        guard let input else { return "{}" }
        guard let data = try? JSONEncoder().encode(input) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct WireUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationInputTokens: Int?
    let cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }

    var totalInputTokens: Int {
        (inputTokens ?? 0) + (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
    }

    var modelUsage: ModelUsage? {
        guard inputTokens != nil else { return nil }
        return ModelUsage(
            inputTokens: totalInputTokens,
            outputTokens: outputTokens ?? 0,
            cachedInputTokens: cacheReadInputTokens ?? 0,
            reasoningTokens: nil
        )
    }
}

private struct WireStreamEvent: Decodable {
    let type: String
    let index: Int?
    let message: WireMessageStart?
    let contentBlock: WireContentBlockStart?
    let delta: WireDelta?
    let usage: WireUsage?
    let error: WireError?

    enum CodingKeys: String, CodingKey {
        case type
        case index
        case message
        case contentBlock = "content_block"
        case delta
        case usage
        case error
    }
}

private struct WireMessageStart: Decodable {
    let usage: WireUsage?
}

private struct WireContentBlockStart: Decodable {
    let type: String
    let id: String?
    let name: String?
}

private struct WireDelta: Decodable {
    let type: String?
    let text: String?
    let thinking: String?
    let partialJSON: String?
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case partialJSON = "partial_json"
        case stopReason = "stop_reason"
    }
}

private struct WireError: Decodable {
    let type: String?
    let message: String?
}
