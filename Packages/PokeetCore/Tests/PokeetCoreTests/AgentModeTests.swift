import Foundation
import Testing
@testable import PokeetCore

struct AgentModeTests {
    @Test func planAllowsOnlyReadCapabilities() {
        #expect(AgentMode.plan.allows([.readFiles]))
        #expect(AgentMode.plan.allows([.gitRead]))
        #expect(AgentMode.plan.allows([.network]))
        #expect(!AgentMode.plan.allows([.writeFiles]))
        #expect(!AgentMode.plan.allows([.readFiles, .writeFiles]))
        #expect(!AgentMode.plan.allowedCapabilities.contains(.writeFiles))
    }

    @Test func otherModesAllowEveryCapability() {
        for mode in [AgentMode.ask, .auto, .bypass] {
            #expect(mode.allows(Set(ToolCapability.allCases)), "\(mode) should allow all tools")
        }
    }

    @Test func approvalPolicies() {
        #expect(AgentMode.plan.approvalPolicy == .deny)
        #expect(AgentMode.ask.approvalPolicy == .review)
        #expect(AgentMode.auto.approvalPolicy == .autoApplySafe)
        #expect(AgentMode.bypass.approvalPolicy == .autoApplyAll)
    }

    @Test func onlyAskHasEmptyPromptGuidance() {
        #expect(AgentMode.ask.promptGuidance.isEmpty)
        for mode in [AgentMode.plan, .auto, .bypass] {
            #expect(!mode.promptGuidance.isEmpty)
        }
    }

    @Test func codableRoundtrip() throws {
        for mode in AgentMode.allCases {
            let data = try JSONEncoder().encode(mode)
            #expect(try JSONDecoder().decode(AgentMode.self, from: data) == mode)
        }
    }
}
