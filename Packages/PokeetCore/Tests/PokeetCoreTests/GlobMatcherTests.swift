import Testing
@testable import PokeetCore

struct GlobMatcherTests {
    @Test func basenamePatternMatchesInAnyDirectory() throws {
        let matcher = try GlobMatcher(pattern: "*.swift")

        #expect(matcher.matches("Sources/A.swift"))
        #expect(matcher.matches("A.swift"))
        #expect(!matcher.matches("Sources/A.md"))
    }

    @Test func recursivePatternMatchesNestedFiles() throws {
        let matcher = try GlobMatcher(pattern: "**/*.swift")

        #expect(matcher.matches("A.swift"))
        #expect(matcher.matches("Sources/Nested/A.swift"))
        #expect(!matcher.matches("Sources/A.md"))
    }

    @Test func anchoredPathPattern() throws {
        let matcher = try GlobMatcher(pattern: "src/**/*.swift")

        #expect(matcher.matches("src/A.swift"))
        #expect(matcher.matches("src/Nested/A.swift"))
        #expect(!matcher.matches("Sources/A.swift"))
    }

    @Test func questionMarkMatchesOneCharacter() throws {
        let matcher = try GlobMatcher(pattern: "A?.swift")

        #expect(matcher.matches("A1.swift"))
        #expect(!matcher.matches("A12.swift"))
    }
}
