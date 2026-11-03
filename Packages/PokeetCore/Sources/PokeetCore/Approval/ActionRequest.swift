import Foundation

public struct ActionRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let method: String
    public let url: String
    public let headers: [String: String]
    public let bodyPreview: String

    public init(
        id: UUID = UUID(),
        method: String,
        url: String,
        headers: [String: String] = [:],
        bodyPreview: String = ""
    ) {
        self.id = id
        self.method = method
        self.url = url
        self.headers = headers
        self.bodyPreview = bodyPreview
    }
}

public struct ActionDecision: Sendable, Equatable {
    public let allow: Bool

    public init(allow: Bool) {
        self.allow = allow
    }

    public static let allowed = ActionDecision(allow: true)
    public static let denied = ActionDecision(allow: false)
}

public typealias ActionApprovalHandler = @Sendable (ActionRequest) async -> ActionDecision
