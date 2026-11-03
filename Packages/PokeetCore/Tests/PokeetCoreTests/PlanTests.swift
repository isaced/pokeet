import Foundation
import Testing
@testable import PokeetCore

struct PlanTests {
    @Test func submitPlanToolBuildsStructuredPlan() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let output = try await SubmitPlanTool().execute(
            arguments: Data(#"{"title":"Ship it","summary":"Small change","steps":[{"title":"Edit README","detail":"Add usage","files":["README.md"]}]}"#.utf8),
            context: ToolContext(workspace: FileWorkspace(root: directory.url))
        )

        #expect(output.plan?.title == "Ship it")
        #expect(output.plan?.summary == "Small change")
        #expect(output.plan?.steps.count == 1)
        #expect(output.plan?.steps.first?.title == "Edit README")
        #expect(output.plan?.steps.first?.files == ["README.md"])
    }

    @Test func submitPlanToolRejectsEmptySteps() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        do {
            _ = try await SubmitPlanTool().execute(
                arguments: Data(#"{"title":"Empty","steps":[]}"#.utf8),
                context: ToolContext(workspace: FileWorkspace(root: directory.url))
            )
            Issue.record("Expected an invalid input error")
        } catch is ToolError {
        }
    }

    @Test func planProgressParsesAndStripsDoneTags() {
        let parsed = PlanProgress.parse("Step one\n[DONE:1]\nStep two\n[DONE:2]")

        #expect(parsed.completedSteps == [1, 2])
        #expect(parsed.text == "Step one\n\nStep two")
    }

    @Test func planCompletionCountsDoneSteps() {
        let plan = AgentPlan(
            title: "Plan",
            steps: [
                AgentPlan.Step(title: "One", status: .done),
                AgentPlan.Step(title: "Two", status: .pending)
            ]
        )

        #expect(plan.completedStepCount == 1)
        #expect(!plan.isComplete)
    }
}
