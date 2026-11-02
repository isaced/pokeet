import Foundation

public enum GlobError: Error, Sendable, Equatable, LocalizedError {
    case invalidPattern(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let pattern):
            "Invalid glob pattern: \(pattern)"
        }
    }
}

public struct GlobMatcher: @unchecked Sendable {
    private let regex: NSRegularExpression
    private let matchBasename: Bool

    public init(pattern: String) throws {
        let normalized = pattern.replacingOccurrences(of: "\\", with: "/")
        matchBasename = !normalized.contains("/")

        do {
            regex = try NSRegularExpression(
                pattern: Self.makeRegex(normalized),
                options: []
            )
        } catch {
            throw GlobError.invalidPattern(pattern)
        }
    }

    public func matches(_ path: String) -> Bool {
        let candidate = matchBasename
            ? (path as NSString).lastPathComponent
            : path
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return regex.firstMatch(in: candidate, range: range) != nil
    }

    private static func makeRegex(_ pattern: String) -> String {
        let characters = Array(pattern)
        var result = "^"
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    if index + 2 < characters.count, characters[index + 2] == "/" {
                        result += "(?:.*/)?"
                        index += 3
                    } else {
                        result += ".*"
                        index += 2
                    }
                } else {
                    result += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                result += "[^/]"
                index += 1
            } else {
                result += NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }

        result += "$"
        return result
    }
}
