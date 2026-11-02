import Foundation

public struct OpenAIResponsesClient: ModelClient {
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
        var toolCalls: [String: ToolCallBuilder] = [:]
        var finalResponse: WireResponse?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            if SSELines.isDone(line) { break }
            guard let payload = SSELines.payload(from: line),
                  let data = payload.data(using: .utf8)
            else { continue }

            let event: WireStreamEvent
            do {
                event = try JSONDecoder().decode(WireStreamEvent.self, from: data)
            } catch {
                throw ModelError.decoding(error.localizedDescription)
            }

            if let error = event.error {
                throw ModelError.invalidResponse(error.message ?? "Stream error")
            }

            switch event.type {
            case "response.output_text.delta":
                if let delta = event.delta, !delta.isEmpty {
                    content += delta
                    continuation.yield(.textDelta(delta))
                }

            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = event.delta, !delta.isEmpty {
                    continuation.yield(.reasoningDelta(delta))
                }

            case "response.output_item.added":
                if let item = event.item, item.type == "function_call" {
                    let key = item.id ?? item.callID ?? UUID().uuidString
                    toolCalls[key] = ToolCallBuilder(
                        callID: item.callID ?? key,
                        name: item.name ?? "",
                        arguments: item.argumentString ?? ""
                    )
                }

            case "response.function_call_arguments.delta":
                guard let key = event.itemID else { continue }
                var builder = toolCalls[key] ?? ToolCallBuilder(
                    callID: key,
                    name: "",
                    arguments: ""
                )
                builder.arguments += event.delta ?? ""
                toolCalls[key] = builder

            case "response.output_item.done":
                if let item = event.item, item.type == "function_call" {
                    let key = item.id ?? item.callID ?? UUID().uuidString
                    var builder = toolCalls[key] ?? ToolCallBuilder(
                        callID: item.callID ?? key,
                        name: item.name ?? "",
                        arguments: ""
                    )
                    if let name = item.name, !name.isEmpty { builder.name = name }
                    if let arguments = item.argumentString { builder.arguments = arguments }
                    toolCalls[key] = builder
                }

            case "response.completed", "response.incomplete":
                if let response = event.response {
                    finalResponse = response
                }

            case "response.failed":
                let message = event.response?.error?.message
                    ?? event.error?.message
                    ?? "The model response failed."
                throw ModelError.invalidResponse(message)

            case "error":
                throw ModelError.invalidResponse(event.error?.message ?? "Stream error")

            default:
                continue
            }
        }

        let streamedCalls = toolCalls.values
            .filter { !$0.name.isEmpty }
            .map { ToolCall(id: $0.callID, name: $0.name, arguments: $0.arguments) }

        let chatResponse = finalResponse?.chatResponse(
            fallbackText: content,
            fallbackToolCalls: streamedCalls
        ) ?? ChatResponse(
            message: .assistant(
                content.isEmpty ? nil : content,
                toolCalls: streamedCalls.isEmpty ? nil : streamedCalls
            ),
            finishReason: nil,
            usage: nil
        )

        continuation.yield(.completed(chatResponse))
    }

    private func makeURLRequest(_ request: ChatRequest, stream: Bool) throws -> URLRequest {
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !model.isEmpty,
              let url = ModelHTTP.validated(
                  ModelHTTP.normalizedURL(baseURL: baseURL, appending: "responses")
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
            "Authorization": "Bearer \(apiKey)",
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

        var input: [JSONValue] = []
        for message in request.messages where message.role != .system {
            switch message.role {
            case .user:
                guard let content = message.content, !content.isEmpty else { continue }
                input.append(.object([
                    "role": .string("user"),
                    "content": .string(content)
                ]))

            case .assistant:
                if let content = message.content, !content.isEmpty {
                    input.append(.object([
                        "role": .string("assistant"),
                        "content": .string(content)
                    ]))
                }
                for call in message.toolCalls ?? [] {
                    input.append(.object([
                        "type": .string("function_call"),
                        "call_id": .string(call.id),
                        "name": .string(call.name),
                        "arguments": .string(call.arguments)
                    ]))
                }

            case .tool:
                input.append(.object([
                    "type": .string("function_call_output"),
                    "call_id": .string(message.toolCallID ?? ""),
                    "output": .string(message.content ?? "")
                ]))

            case .system:
                break
            }
        }

        var object: [String: JSONValue] = [
            "model": .string(model),
            "input": .array(input),
            "stream": .bool(stream),
            "store": .bool(false),
            "max_output_tokens": .number(Double(maxOutputTokens))
        ]

        if !system.isEmpty {
            object["instructions"] = .string(system)
        }

        if !request.tools.isEmpty {
            object["tools"] = .array(
                request.tools
                    .sorted { $0.name < $1.name }
                    .map { tool in
                        .object([
                            "type": .string("function"),
                            "name": .string(tool.name),
                            "description": .string(tool.description),
                            "parameters": tool.parameters
                        ])
                    }
            )
            object["tool_choice"] = .string("auto")
        }

        return .object(object)
    }
}

private struct ToolCallBuilder {
    var callID: String
    var name: String
    var arguments: String
}

private struct WireResponse: Decodable {
    struct IncompleteDetails: Decodable {
        let reason: String?
    }

    struct Error: Decodable {
        let message: String?
    }

    let status: String?
    let incompleteDetails: IncompleteDetails?
    let output: [WireOutputItem]?
    let usage: WireUsage?
    let error: Error?

    enum CodingKeys: String, CodingKey {
        case status
        case incompleteDetails = "incomplete_details"
        case output
        case usage
        case error
    }

    var finishReason: String? {
        if status == "incomplete" {
            return incompleteDetails?.reason ?? "incomplete"
        }
        return status
    }

    func chatResponse(
        fallbackText: String = "",
        fallbackToolCalls: [ToolCall] = []
    ) -> ChatResponse {
        var text = ""
        var calls: [ToolCall] = []

        for item in output ?? [] {
            switch item.type {
            case "message":
                for content in item.content ?? [] {
                    if let value = content.text, !value.isEmpty {
                        text += value
                    }
                }
            case "function_call":
                guard let name = item.name, !name.isEmpty else { continue }
                calls.append(ToolCall(
                    id: item.callID ?? item.id ?? UUID().uuidString,
                    name: name,
                    arguments: item.argumentString ?? "{}"
                ))
            default:
                continue
            }
        }

        if text.isEmpty { text = fallbackText }
        if calls.isEmpty { calls = fallbackToolCalls }

        return ChatResponse(
            message: .assistant(
                text.isEmpty ? nil : text,
                toolCalls: calls.isEmpty ? nil : calls
            ),
            finishReason: finishReason,
            usage: usage?.modelUsage
        )
    }
}

private struct WireOutputItem: Decodable {
    let type: String
    let id: String?
    let role: String?
    let content: [WireContent]?
    let callID: String?
    let name: String?
    let arguments: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case role
        case content
        case callID = "call_id"
        case name
        case arguments
    }

    var argumentString: String? {
        guard let arguments else { return nil }
        if case .string(let value) = arguments {
            return value
        }
        guard let data = try? JSONEncoder().encode(arguments) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct WireContent: Decodable {
    let type: String?
    let text: String?
}

private struct WireUsage: Decodable {
    struct InputDetails: Decodable {
        let cachedTokens: Int?

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    struct OutputDetails: Decodable {
        let reasoningTokens: Int?

        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    let inputTokens: Int?
    let outputTokens: Int?
    let inputTokensDetails: InputDetails?
    let outputTokensDetails: OutputDetails?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokensDetails = "output_tokens_details"
    }

    var modelUsage: ModelUsage? {
        guard let inputTokens else { return nil }
        return ModelUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens ?? 0,
            cachedInputTokens: inputTokensDetails?.cachedTokens ?? 0,
            reasoningTokens: outputTokensDetails?.reasoningTokens
        )
    }
}

private struct WireStreamEvent: Decodable {
    let type: String
    let delta: String?
    let itemID: String?
    let item: WireOutputItem?
    let response: WireResponse?
    let error: WireResponse.Error?

    enum CodingKeys: String, CodingKey {
        case type
        case delta
        case itemID = "item_id"
        case item
        case response
        case error
    }
}
