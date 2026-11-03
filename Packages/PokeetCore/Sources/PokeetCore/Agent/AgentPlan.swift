import Foundation

public struct AgentPlan: Codable, Sendable, Equatable, Identifiable {
    /// A plan step is a task: the same shape the running todo list uses.
    public typealias Step = TaskItem

    public let id: UUID
    public var title: String
    public var summary: String?
    public var steps: [Step]

    public init(
        id: UUID = UUID(),
        title: String,
        summary: String? = nil,
        steps: [Step]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.steps = steps
    }

    public var completedStepCount: Int {
        steps.filter { $0.status == .done }.count
    }

    public var isComplete: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.status == .done || $0.status == .skipped }
    }

    public static func fallback(from text: String) -> AgentPlan {
        AgentPlan(title: "Plan", summary: text, steps: [])
    }
}

public enum PlanProgress {
    public struct Parsed: Sendable, Equatable {
        public let text: String
        public let completedSteps: Set<Int>

        public init(text: String, completedSteps: Set<Int>) {
            self.text = text
            self.completedSteps = completedSteps
        }
    }

    private static let donePattern = try! NSRegularExpression(
        pattern: "\\[DONE:(\\d+)\\]",
        options: []
    )

    public static func parse(_ text: String) -> Parsed {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = donePattern.matches(in: text, options: [], range: range)
        var completed = Set<Int>()
        for match in matches {
            guard let stepRange = Range(match.range(at: 1), in: text),
                  let step = Int(text[stepRange])
            else {
                continue
            }
            completed.insert(step)
        }
        let cleaned = donePattern
            .stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(text: cleaned, completedSteps: completed)
    }
}
