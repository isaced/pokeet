import Foundation

struct StreamBuffer: Sendable {
    static let flushInterval = Duration.milliseconds(33)

    private(set) var assistant = ""
    private(set) var reasoning = ""

    var isEmpty: Bool {
        assistant.isEmpty && reasoning.isEmpty
    }

    mutating func appendAssistant(_ text: String) {
        assistant += text
    }

    mutating func appendReasoning(_ text: String) {
        reasoning += text
    }

    mutating func drainAssistant() -> String {
        defer { assistant = "" }
        return assistant
    }

    mutating func drainReasoning() -> String {
        defer { reasoning = "" }
        return reasoning
    }

    mutating func clear() {
        assistant = ""
        reasoning = ""
    }
}
