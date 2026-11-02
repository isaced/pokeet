import Foundation

public struct GeminiGenerateContentClient: ModelClient {
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

            if let error = wireResponse.error {
                throw ModelError.invalidResponse(error.message ?? "Gemini returned an error.")
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
        var calls: [ToolCall] = []
        var finishReason: String?
        var usage: ModelUsage?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = SSELines.payload(from: line),
                  let data = payload.data(using: .utf8)
            else { continue }

            let chunk: WireResponse
            do {
                chunk = try JSONDecoder().decode(WireResponse.self, from: data)
            } catch {
                throw ModelError.decoding(error.localizedDescription)
            }

            if let error = chunk.error {
                throw ModelError.invalidResponse(error.message ?? "Stream error")
            }

            if let metadata = chunk.usageMetadata {
                usage = metadata.modelUsage
            }

            guard let candidate = chunk.candidates?.first else { continue }

            if let reason = candidate.finishReason {
                finishReason = reason
            }

            for part in candidate.content?.parts ?? [] {
                if let functionCall = part.functionCall {
                    guard let name = functionCall.name, !name.isEmpty else { continue }
                    calls.append(ToolCall(
                        id: UUID().uuidString,
                        name: name,
                        arguments: functionCall.argumentString
                    ))
                } else if let text = part.text, !text.isEmpty {
                    if part.thought == true {
                        continuation.yield(.reasoningDelta(text))
                    } else {
                        content += text
                        continuation.yield(.textDelta(text))
                    }
                }
            }
        }

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
              let url = ModelHTTP.geminiURL(
                  baseURL: baseURL,
                  model: model,
                  action: stream ? "streamGenerateContent" : "generateContent",
                  query: stream ? "alt=sse" : nil
              )
        else {
            throw ModelError.notConfigured
        }

        let body = Self.requestBody(
            request,
            maxOutputTokens: maxOutputTokens
        )
        let data = try ModelHTTP.encodeJSON(body)

        var headers = [
            "x-goog-api-key": apiKey,
            "Content-Type": "application/json"
        ]
        if stream {
            headers["Accept"] = "text/event-stream"
        }

        return ModelHTTP.request(url: url, headers: headers, body: data)
    }

    private static func requestBody(
        _ request: ChatRequest,
        maxOutputTokens: Int
    ) -> JSONValue {
        let system = request.messages
            .filter { $0.role == .system }
            .compactMap(\.content)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var toolNames: [String: String] = [:]
        var turns = GeminiTurns()

        for message in request.messages where message.role != .system {
            switch message.role {
            case .user:
                for image in message.images ?? [] {
                    turns.append(role: "user", part: .object([
                        "inlineData": .object([
                            "mimeType": .string(image.mimeType),
                            "data": .string(image.base64)
                        ])
                    ]))
                }
                if let content = message.content, !content.isEmpty {
                    turns.append(role: "user", part: .object(["text": .string(content)]))
                }

            case .assistant:
                var parts: [JSONValue] = []
                if let content = message.content, !content.isEmpty {
                    parts.append(.object(["text": .string(content)]))
                }
                for call in message.toolCalls ?? [] {
                    toolNames[call.id] = call.name
                    parts.append(.object([
                        "functionCall": .object([
                            "name": .string(call.name),
                            "args": jsonObject(from: call.arguments)
                        ])
                    ]))
                }
                for part in parts {
                    turns.append(role: "model", part: part)
                }

            case .tool:
                let name = toolNames[message.toolCallID ?? ""] ?? "tool"
                turns.append(role: "user", part: .object([
                    "functionResponse": .object([
                        "name": .string(name),
                        "response": .object([
                            "result": .string(message.content ?? "")
                        ])
                    ])
                ]))

            case .system:
                break
            }
        }

        var contents = turns.values
        if let first = contents.first,
           case .object(let object) = first,
           object["role"] == .string("model") {
            contents.insert(.object([
                "role": .string("user"),
                "parts": .array([.object(["text": .string("Continue.")])])
            ]), at: 0)
        }

        var object: [String: JSONValue] = [
            "contents": .array(contents),
            "generationConfig": .object([
                "maxOutputTokens": .number(Double(maxOutputTokens))
            ])
        ]

        if !system.isEmpty {
            object["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(system)])])
            ])
        }

        if !request.tools.isEmpty {
            object["tools"] = .array([
                .object([
                    "functionDeclarations": .array(
                        request.tools
                            .sorted { $0.name < $1.name }
                            .map { tool in
                                .object([
                                    "name": .string(tool.name),
                                    "description": .string(tool.description),
                                    "parameters": sanitizeSchema(tool.parameters)
                                ])
                            }
                    )
                ])
            ])
            object["toolConfig"] = .object([
                "functionCallingConfig": .object([
                    "mode": .string("AUTO")
                ])
            ])
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

    private static func sanitizeSchema(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            let removed: Set<String> = [
                "additionalProperties", "$schema", "$defs", "definitions",
                "title", "default", "examples", "strict"
            ]
            return .object(
                object.reduce(into: [:]) { result, element in
                    guard !removed.contains(element.key) else { return }
                    result[element.key] = sanitizeSchema(element.value)
                }
            )
        case .array(let values):
            return .array(values.map(sanitizeSchema))
        default:
            return value
        }
    }
}

private struct GeminiTurns {
    private(set) var values: [JSONValue] = []
    private var roles: [String] = []

    mutating func append(role: String, part: JSONValue) {
        if roles.last == role,
           case .object(var object) = values[values.count - 1],
           case .array(var parts) = object["parts"] {
            parts.append(part)
            object["parts"] = .array(parts)
            values[values.count - 1] = .object(object)
        } else {
            values.append(.object([
                "role": .string(role),
                "parts": .array([part])
            ]))
            roles.append(role)
        }
    }
}

private struct WireResponse: Decodable {
    let candidates: [WireCandidate]?
    let usageMetadata: WireUsage?
    let error: WireError?

    enum CodingKeys: String, CodingKey {
        case candidates
        case usageMetadata
        case error
    }

    func chatResponse() -> ChatResponse {
        let candidate = candidates?.first
        var text = ""
        var calls: [ToolCall] = []

        for part in candidate?.content?.parts ?? [] {
            if let functionCall = part.functionCall {
                guard let name = functionCall.name, !name.isEmpty else { continue }
                calls.append(ToolCall(
                    id: UUID().uuidString,
                    name: name,
                    arguments: functionCall.argumentString
                ))
            } else if part.thought != true, let value = part.text, !value.isEmpty {
                text += value
            }
        }

        return ChatResponse(
            message: .assistant(
                text.isEmpty ? nil : text,
                toolCalls: calls.isEmpty ? nil : calls
            ),
            finishReason: candidate?.finishReason,
            usage: usageMetadata?.modelUsage
        )
    }
}

private struct WireCandidate: Decodable {
    let content: WireContent?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case finishReason
    }
}

private struct WireContent: Decodable {
    let role: String?
    let parts: [WirePart]?
}

private struct WirePart: Decodable {
    let text: String?
    let thought: Bool?
    let functionCall: WireFunctionCall?
}

private struct WireFunctionCall: Decodable {
    let name: String?
    let args: JSONValue?

    var argumentString: String {
        guard let args else { return "{}" }
        guard let data = try? JSONEncoder().encode(args) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct WireUsage: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let cachedContentTokenCount: Int?
    let thoughtsTokenCount: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokenCount
        case candidatesTokenCount
        case cachedContentTokenCount
        case thoughtsTokenCount
    }

    var modelUsage: ModelUsage? {
        guard let promptTokenCount else { return nil }
        return ModelUsage(
            inputTokens: promptTokenCount,
            outputTokens: candidatesTokenCount ?? 0,
            cachedInputTokens: cachedContentTokenCount ?? 0,
            reasoningTokens: thoughtsTokenCount
        )
    }
}

private struct WireError: Decodable {
    let code: Int?
    let message: String?
    let status: String?
}
