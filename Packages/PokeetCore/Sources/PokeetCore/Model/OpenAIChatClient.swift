import Foundation

public struct OpenAIChatClient: ModelClient {
    private let baseURL: String
    private let model: String
    private let apiKey: String
    private let session: URLSession

    public init(
        baseURL: String,
        model: String,
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
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
                    message: errorMessage(from: data)
                )
            }

            let wireResponse: WireResponse
            do {
                wireResponse = try JSONDecoder().decode(WireResponse.self, from: data)
            } catch {
                throw ModelError.decoding(error.localizedDescription)
            }

            guard let choice = wireResponse.choices.first else {
                throw ModelError.invalidResponse("No choices returned")
            }

            return ChatResponse(
                message: choice.message.chatMessage,
                finishReason: choice.finishReason,
                usage: wireResponse.usage?.modelUsage
            )
        } catch {
            throw mapTransportError(error)
        }
    }

    public func stream(_ request: ChatRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapTransportError(error))
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
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 8192 { break }
            }
            throw ModelError.http(
                status: httpResponse.statusCode,
                message: errorMessage(from: body)
            )
        }

        var content = ""
        var toolCalls: [Int: ToolCallAccumulator] = [:]
        var finishReason: String?
        var streamUsage: ModelUsage?

        for try await line in bytes.lines {
            try Task.checkCancellation()

            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst(5)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if payload.isEmpty || payload == "[DONE]" {
                if payload == "[DONE]" { break }
                continue
            }

            guard let data = payload.data(using: .utf8) else { continue }

            let chunk: WireStreamChunk
            do {
                chunk = try JSONDecoder().decode(WireStreamChunk.self, from: data)
            } catch {
                throw ModelError.decoding(error.localizedDescription)
            }

            if let error = chunk.error {
                throw ModelError.invalidResponse(error.message ?? "Stream error")
            }

            if let usage = chunk.usage?.modelUsage {
                streamUsage = usage
            }

            guard let choice = chunk.choices?.first else { continue }

            if let reasoning = choice.delta?.reasoningContent, !reasoning.isEmpty {
                continuation.yield(.reasoningDelta(reasoning))
            }

            if let delta = choice.delta?.content, !delta.isEmpty {
                content += delta
                continuation.yield(.textDelta(delta))
            }

            for toolCallDelta in choice.delta?.toolCalls ?? [] {
                let index = toolCallDelta.index ?? 0
                var accumulator = toolCalls[index] ?? ToolCallAccumulator(index: index)

                if let id = toolCallDelta.id {
                    accumulator.id = id
                }
                if let name = toolCallDelta.function?.name {
                    accumulator.name = name
                }
                if let arguments = toolCallDelta.function?.arguments {
                    accumulator.arguments += arguments
                }

                toolCalls[index] = accumulator
            }

            if let reason = choice.finishReason {
                finishReason = reason
            }
        }

        let calls = toolCalls.values
            .sorted { $0.index < $1.index }
            .compactMap { accumulator -> ToolCall? in
                guard !accumulator.name.isEmpty else { return nil }
                return ToolCall(
                    id: accumulator.id.isEmpty ? UUID().uuidString : accumulator.id,
                    name: accumulator.name,
                    arguments: accumulator.arguments
                )
            }

        continuation.yield(.completed(ChatResponse(
            message: .assistant(
                content.isEmpty ? nil : content,
                toolCalls: calls.isEmpty ? nil : calls
            ),
            finishReason: finishReason,
            usage: streamUsage
        )))
    }

    private func makeURLRequest(_ request: ChatRequest, stream: Bool) throws -> URLRequest {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty, let endpoint = endpointURL else {
            throw ModelError.notConfigured
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if stream {
            urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }

        let sortedTools = request.tools.sorted { $0.name < $1.name }

        do {
            let encoder = JSONEncoder()
            // Stable key and tool order keep upstream prompt caches warm.
            encoder.outputFormatting = [.sortedKeys]
            urlRequest.httpBody = try encoder.encode(WireRequest(
                model: model,
                messages: request.messages.map { WireMessage($0) },
                tools: sortedTools.isEmpty ? nil : sortedTools.map { WireTool($0) },
                toolChoice: sortedTools.isEmpty ? nil : "auto",
                stream: stream ? true : nil,
                streamOptions: stream ? WireStreamOptions() : nil
            ))
        } catch {
            throw ModelError.decoding(error.localizedDescription)
        }

        return urlRequest
    }

    private func mapTransportError(_ error: Error) -> ModelError {
        if let error = error as? ModelError {
            return error
        }
        if let error = error as? URLError, error.code == .cancelled {
            return .cancelled
        }
        if error is CancellationError {
            return .cancelled
        }
        return .network(error.localizedDescription)
    }

    private var endpointURL: URL? {
        var text = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") {
            text.removeLast()
        }
        guard let base = URL(string: text),
              let scheme = base.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              base.host != nil
        else { return nil }

        let endpoint = base.path.hasSuffix("/chat/completions")
            ? base
            : base.appendingPathComponent("chat/completions")

        // ATS local networking covers hostnames, not loopback IP literals.
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        if let host = components.host, host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            components.host = "localhost"
        }
        return components.url ?? endpoint
    }

    private func errorMessage(from data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let message = envelope.error?.message,
           !message.isEmpty {
            return message
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return String(text.prefix(500))
        }
        return "Unknown error"
    }
}

private struct WireRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let tools: [WireTool]?
    let toolChoice: String?
    let stream: Bool?
    let streamOptions: WireStreamOptions?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
        case stream
        case streamOptions = "stream_options"
    }
}

private struct WireStreamOptions: Encodable {
    let includeUsage = true

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

private struct WireMessage: Codable {
    var role: String
    var content: String?
    var toolCalls: [WireToolCall]?
    var toolCallID: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }

    init(role: String, content: String?, toolCalls: [WireToolCall]?, toolCallID: String?) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    init(_ message: ChatMessage) {
        role = message.role.rawValue
        content = message.content
        toolCalls = message.toolCalls?.map { WireToolCall($0) }
        toolCallID = message.toolCallID
    }

    var chatMessage: ChatMessage {
        ChatMessage(
            role: ChatMessage.Role(rawValue: role) ?? .assistant,
            content: content,
            toolCalls: toolCalls?.map(\.toolCall),
            toolCallID: toolCallID
        )
    }
}

private struct WireToolCall: Codable {
    struct Function: Codable {
        let name: String
        let arguments: String

        enum CodingKeys: String, CodingKey {
            case name
            case arguments
        }

        init(name: String, arguments: String) {
            self.name = name
            self.arguments = arguments
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)

            if let text = try? container.decode(String.self, forKey: .arguments) {
                arguments = text
            } else {
                let value = try container.decode(JSONValue.self, forKey: .arguments)
                let data = try JSONEncoder().encode(value)
                arguments = String(decoding: data, as: UTF8.self)
            }
        }
    }

    let id: String
    let type: String
    let function: Function

    init(_ call: ToolCall) {
        id = call.id
        type = "function"
        function = Function(name: call.name, arguments: call.arguments)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "function"
        function = try container.decode(Function.self, forKey: .function)
    }

    var toolCall: ToolCall {
        ToolCall(id: id, name: function.name, arguments: function.arguments)
    }
}

private struct WireTool: Encodable {
    struct Function: Encodable {
        let name: String
        let description: String
        let parameters: JSONValue
    }

    let type = "function"
    let function: Function

    init(_ schema: ToolSchema) {
        function = Function(
            name: schema.name,
            description: schema.description,
            parameters: schema.parameters
        )
    }
}

private struct WireResponse: Decodable {
    struct Choice: Decodable {
        let message: WireMessage
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case message
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
    let usage: WireUsage?
}

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

private struct WireStreamChunk: Decodable {
    struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable {
        let content: String?
        let reasoningContent: String?
        let toolCalls: [WireToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    let choices: [Choice]?
    let error: WireStreamError?
    let usage: WireUsage?
}

private struct WireUsage: Decodable {
    struct PromptDetails: Decodable {
        let cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    struct CompletionDetails: Decodable {
        let reasoningTokens: Int?

        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    let promptTokens: Int?
    let completionTokens: Int?
    let promptTokensDetails: PromptDetails?
    let completionTokensDetails: CompletionDetails?
    let promptCacheHitTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case completionTokensDetails = "completion_tokens_details"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
    }

    var modelUsage: ModelUsage? {
        guard let promptTokens else { return nil }

        return ModelUsage(
            inputTokens: promptTokens,
            outputTokens: completionTokens ?? 0,
            cachedInputTokens: promptTokensDetails?.cachedTokens
                ?? promptCacheHitTokens
                ?? 0,
            reasoningTokens: completionTokensDetails?.reasoningTokens
        )
    }
}

private struct WireStreamError: Decodable {
    let message: String?
}

private struct WireToolCallDelta: Decodable {
    struct Function: Decodable {
        let name: String?
        let arguments: String?
    }

    let index: Int?
    let id: String?
    let function: Function?
}

private struct ToolCallAccumulator {
    let index: Int
    var id = ""
    var name = ""
    var arguments = ""
}
