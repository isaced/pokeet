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

        do {
            urlRequest.httpBody = try JSONEncoder().encode(WireRequest(
                model: model,
                messages: request.messages.map { WireMessage($0) },
                tools: request.tools.isEmpty ? nil : request.tools.map { WireTool($0) },
                toolChoice: request.tools.isEmpty ? nil : "auto"
            ))
        } catch {
            throw ModelError.decoding(error.localizedDescription)
        }

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
                finishReason: choice.finishReason
            )
        } catch let error as ModelError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw ModelError.cancelled
        } catch is CancellationError {
            throw ModelError.cancelled
        } catch {
            throw ModelError.network(error.localizedDescription)
        }
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

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case tools
        case toolChoice = "tool_choice"
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
}

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}
