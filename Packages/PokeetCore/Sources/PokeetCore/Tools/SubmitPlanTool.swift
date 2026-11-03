import Foundation

public struct SubmitPlanTool: AgentTool {
    public init() {}

    public var capabilities: Set<ToolCapability> { [.planning] }

    public var schema: ToolSchema {
        ToolSchema(
            name: "submit_plan",
            description: """
            Submit a structured implementation plan for user approval. Use this in Plan mode \
            when your investigation is complete. The user reviews the steps and decides whether \
            to execute the plan.
            """,
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Short plan title.")
                    ]),
                    "summary": .object([
                        "type": .string("string"),
                        "description": .string("Optional one-paragraph summary.")
                    ]),
                    "steps": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "title": .object([
                                    "type": .string("string"),
                                    "description": .string("What this step does.")
                                ]),
                                "detail": .object([
                                    "type": .string("string"),
                                    "description": .string("Optional implementation detail.")
                                ]),
                                "files": .object([
                                    "type": .string("array"),
                                    "items": .object([
                                        "type": .string("string")
                                    ]),
                                    "description": .string("Files this step is expected to touch.")
                                ])
                            ]),
                            "required": .array([.string("title")]),
                            "additionalProperties": .bool(false)
                        ])
                    ])
                ]),
                "required": .array([.string("title"), .string("steps")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    public func execute(arguments: Data, context: ToolContext) async throws -> ToolOutput {
        struct Arguments: Decodable {
            struct Step: Decodable {
                var title: String
                var detail: String?
                var files: [String]?
            }

            var title: String
            var summary: String?
            var steps: [Step]
        }

        let arguments = try decodeToolArguments(arguments, as: Arguments.self)
        let title = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw ToolError.invalidInput("Plan title is required.")
        }
        guard !arguments.steps.isEmpty else {
            throw ToolError.invalidInput("Plan must have at least one step.")
        }
        guard arguments.steps.count <= 20 else {
            throw ToolError.invalidInput("Plan can have at most 20 steps.")
        }

        let steps = try arguments.steps.map { step in
            let stepTitle = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !stepTitle.isEmpty else {
                throw ToolError.invalidInput("Every plan step needs a title.")
            }
            let files = (step.files ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let detail = step.detail?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentPlan.Step(
                title: stepTitle,
                detail: detail?.isEmpty == true ? nil : detail,
                files: files
            )
        }

        let summary = arguments.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plan = AgentPlan(
            title: title,
            summary: summary?.isEmpty == true ? nil : summary,
            steps: steps
        )
        return ToolOutput(content: "Plan submitted.", plan: plan)
    }
}
