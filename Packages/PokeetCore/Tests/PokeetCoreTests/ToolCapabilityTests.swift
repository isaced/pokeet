import Testing
@testable import PokeetCore

struct ToolCapabilityTests {
    @Test func standardToolsDeclareCapabilities() {
        let registry = ToolRegistry.standard

        let writeTools = Set(
            registry.tools
                .filter { $0.capabilities.contains(.writeFiles) }
                .map(\.schema.name)
        )
        #expect(writeTools == ["write_file", "edit_file", "delete_file", "move_file"])

        let readTools = Set(
            registry.tools
                .filter { $0.capabilities.contains(.readFiles) }
                .map(\.schema.name)
        )
        #expect(readTools == ["list_files", "read_file", "grep", "find", "file_info", "read_image"])

        let gitTools = Set(
            registry.tools
                .filter { $0.capabilities.contains(.gitRead) }
                .map(\.schema.name)
        )
        #expect(gitTools == ["git_status", "git_diff", "git_log", "git_show"])

        let networkTools = Set(
            registry.tools
                .filter { $0.capabilities.contains(.network) }
                .map(\.schema.name)
        )
        #expect(networkTools == ["http_request"])

        let planningTools = Set(
            registry.tools
                .filter { $0.capabilities.contains(.planning) }
                .map(\.schema.name)
        )
        #expect(planningTools == ["submit_plan"])

        let taskTools = Set(
            registry.tools
                .filter { $0.capabilities.contains(.tasks) }
                .map(\.schema.name)
        )
        #expect(taskTools == ["todo_write"])

        let scriptTools = Set(
            registry.tools
                .filter { $0.capabilities.contains(.runScript) }
                .map(\.schema.name)
        )
        #expect(scriptTools == ["run_script"])
    }

    @Test func planModeFiltersWriteTools() {
        let names = Set(ToolRegistry.standard.filtered(for: .plan).schemas.map(\.name))

        #expect(!names.contains("write_file"))
        #expect(!names.contains("edit_file"))
        #expect(!names.contains("delete_file"))
        #expect(!names.contains("move_file"))
        #expect(names.contains("list_files"))
        #expect(names.contains("read_file"))
        #expect(names.contains("grep"))
        #expect(names.contains("find"))
        #expect(names.contains("file_info"))
        #expect(names.contains("git_status"))
        #expect(names.contains("git_diff"))
        #expect(names.contains("git_log"))
        #expect(names.contains("git_show"))
        #expect(names.contains("http_request"))
        #expect(names.contains("submit_plan"))
        #expect(!names.contains("run_script"))
        #expect(names.contains("todo_write"))
    }

    @Test func nonPlanModesExcludePlanningTools() {
        let expected = Set(ToolRegistry.standard.schemas.map(\.name))
            .subtracting(["submit_plan"])
        for mode in [AgentMode.ask, .auto, .bypass] {
            let names = Set(ToolRegistry.standard.filtered(for: mode).schemas.map(\.name))
            #expect(names == expected)
            #expect(!names.contains("submit_plan"))
        }
    }
}
