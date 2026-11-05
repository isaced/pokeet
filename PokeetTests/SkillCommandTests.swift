import PokeetCore
import XCTest
@testable import Pokeet

/// The composer's half of `/skill:<name>`: what the user has typed, and what the list inserts.
/// Pure string work, so the interesting cases are testable without a running chat.
final class SkillCommandTests: XCTestCase {
    private func skill(_ name: String, description: String = "A skill.") -> Skill {
        Skill(
            name: name,
            description: description,
            location: ".agents/skills/\(name)/SKILL.md",
            directory: ".agents/skills/\(name)",
            source: .project,
            fileURL: URL(fileURLWithPath: "/tmp/\(name)/SKILL.md")
        )
    }

    func testABareSlashAsksForEverything() {
        XCTAssertEqual(SkillCommand.query(in: "/"), "")
        XCTAssertEqual(SkillCommand.query(in: "/skill"), "")
        XCTAssertEqual(SkillCommand.query(in: "/skill:"), "")
    }

    func testTheTypedNameIsTheQuery() {
        XCTAssertEqual(SkillCommand.query(in: "/skill:pdf"), "pdf")
        XCTAssertEqual(SkillCommand.query(in: "/skill:PDF-tools"), "PDF-tools")
    }

    func testStartedArgumentsEndTheSuggestion() {
        XCTAssertNil(SkillCommand.query(in: "/skill:pdf extract the report"))
        XCTAssertNil(SkillCommand.query(in: "/skill:pdf "))
    }

    func testPlainMessagesAreNotCommands() {
        XCTAssertNil(SkillCommand.query(in: "hello"))
        XCTAssertNil(SkillCommand.query(in: " /skill:pdf"))
        XCTAssertNil(SkillCommand.query(in: "/skills:pdf"))
        XCTAssertNil(SkillCommand.query(in: "line\n/skill:pdf"))
        XCTAssertNil(SkillCommand.query(in: "/other command"))
    }

    func testMatchingFiltersByPrefixAndKeepsOrder() {
        let skills = [
            skill("pdf-tools"),
            skill("release"),
            skill("pdf-forms")
        ]

        XCTAssertEqual(
            SkillCommand.matching(skills, query: "pdf").map(\.name),
            ["pdf-forms", "pdf-tools"]
        )
        XCTAssertEqual(SkillCommand.matching(skills, query: "").count, 3)
        XCTAssertTrue(SkillCommand.matching(skills, query: "zzz").isEmpty)
    }

    func testMatchingIsCapped() {
        let skills = (0..<20).map { skill("skill-\($0)") }

        XCTAssertEqual(SkillCommand.matching(skills, query: "").count, SkillCommand.maxSuggestions)
    }

    func testInsertingASkillKeepsArgumentsAlreadyTyped() {
        XCTAssertEqual(
            SkillCommand.apply(skill("pdf-tools"), to: "/skill:pd extract the report"),
            "/skill:pdf-tools extract the report"
        )
        XCTAssertEqual(
            SkillCommand.apply(skill("pdf-tools"), to: "/skill:"),
            "/skill:pdf-tools "
        )
        XCTAssertEqual(
            SkillCommand.apply(skill("pdf-tools"), to: "ignored"),
            "/skill:pdf-tools "
        )
    }
}
