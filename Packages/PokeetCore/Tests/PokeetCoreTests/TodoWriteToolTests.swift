import Foundation
import Testing
@testable import PokeetCore

struct TodoWriteToolTests {
    @Test func writesChecklist() async throws {
        let output = try await write("""
        {"items":[
          {"content":"Read the parser"},
          {"content":"Add the guard","status":"in_progress"},
          {"content":"Run checks","status":"done"}
        ]}
        """)

        #expect(output.content.contains("1/3 done, 1 in progress"))
        #expect(output.content.contains("[ ] Read the parser"))
        #expect(output.content.contains("[~] Add the guard"))
        #expect(output.content.contains("[x] Run checks"))
        #expect(output.tasks?.count == 3)
        #expect(output.tasks?[1].status == .inProgress)
    }

    @Test func acceptsStatusAliases() async throws {
        let output = try await write("""
        {"items":[
          {"content":"a","status":"completed"},
          {"content":"b","status":"active"},
          {"content":"c","status":"skipped"}
        ]}
        """)

        #expect(output.tasks?.map(\.status) == [.done, .inProgress, .skipped])
    }

    @Test func emptyListClearsTasks() async throws {
        let output = try await write(#"{"items":[]}"#)
        #expect(output.tasks?.isEmpty == true)
        #expect(output.content.contains("cleared"))
    }

    @Test func rejectsInvalidInput() async throws {
        for payload in [
            #"{"items":[{"content":"   "}]}"#,
            #"{"items":[{"content":"x","status":"blocked"}]}"#,
            #"{"items":[{"content":""# + String(repeating: "x", count: 300) + #""}]}"#,
            #"{"items":["# + Array(repeating: #"{"content":"x"}"#, count: 21).joined(separator: ",") + #"]}"#
        ] {
            await #expect(throws: ToolError.self) {
                _ = try await write(payload)
            }
        }
    }

    @Test func formatsReminder() {
        let tasks = [
            TaskItem(title: "First"),
            TaskItem(title: "Second", status: .done)
        ]
        let reminder = TaskListFormatter.reminder(tasks)
        #expect(reminder.contains("[ ] First"))
        #expect(reminder.contains("[x] Second"))
        #expect(reminder.contains(TodoWriteTool.toolName))
    }

    @Test func restoredTasksFeedTheReminder() async throws {
        let directory = try TestDirectory()
        defer { directory.cleanup() }

        let session = AgentSession(
            client: ScriptedModelClient([ChatResponse(message: .assistant("ok"), finishReason: "stop")]),
            workspace: FileWorkspace(root: directory.url)
        )
        await session.setTasks([TaskItem(title: "Ship it", status: .inProgress)])

        let tasks = await session.taskList
        #expect(tasks.map(\.title) == ["Ship it"])
        #expect(tasks.map(\.status) == [.inProgress])
    }

    private func write(_ arguments: String) async throws -> ToolOutput {
        let directory = try TestDirectory()
        defer { directory.cleanup() }
        return try await TodoWriteTool().execute(
            arguments: Data(arguments.utf8),
            context: ToolContext(workspace: FileWorkspace(root: directory.url))
        )
    }
}
