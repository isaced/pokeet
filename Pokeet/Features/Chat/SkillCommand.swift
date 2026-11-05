import Foundation
import PokeetCore

/// The composer's half of `/skill:<name> [args]`.
///
/// Only a leading command means anything to the agent (`AgentSession` expands the first token
/// of the message), so suggestions stop as soon as arguments begin — offering a list next to
/// half-typed prose would be noise.
enum SkillCommand {
    static let prefix = "/skill:"
    static let maxSuggestions = 6

    /// What the user has typed for the skill name, or nil when the input is not a command
    /// prefix. Empty means "show everything".
    static func query(in input: String) -> String? {
        guard !input.contains(where: \.isNewline) else { return nil }
        guard input.hasPrefix("/") else { return nil }

        let token = input.prefix { !$0.isWhitespace }
        // A space after the token means arguments have started.
        guard token.count == input.count else { return nil }

        if token == "/" || token == "/skill" { return "" }
        guard token.hasPrefix(prefix) else { return nil }
        return String(token.dropFirst(prefix.count))
    }

    static func matching(_ skills: [Skill], query: String) -> [Skill] {
        let needle = query.lowercased()
        return skills
            .filter { needle.isEmpty || $0.name.lowercased().hasPrefix(needle) }
            .sorted { $0.name < $1.name }
            .prefix(maxSuggestions)
            .map { $0 }
    }

    /// Rewrites the command and keeps whatever arguments follow it, so completing a name does
    /// not throw away a sentence the user already typed.
    static func apply(_ skill: Skill, to input: String) -> String {
        let parts = input.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let arguments = parts.count > 1
            ? String(parts[1]).trimmingCharacters(in: .whitespaces)
            : ""
        return arguments.isEmpty
            ? "\(prefix)\(skill.name) "
            : "\(prefix)\(skill.name) \(arguments)"
    }
}
