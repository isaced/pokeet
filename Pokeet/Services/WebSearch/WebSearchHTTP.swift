import Foundation
import PokeetCore

/// HTTP details the search adapters share: status-code mapping inputs, error
/// text extraction and date parsing. Each provider owns its endpoint, body and
/// result mapping; everything else lives here so a new adapter stays small.
enum WebSearchHTTP {
    /// `Retry-After` is documented as seconds by Brave and Tavily. An HTTP-date
    /// is tolerated because some proxies send one anyway.
    static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces),
            !raw.isEmpty
        else { return nil }

        if let seconds = Int(raw) { return max(0, seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, Int(date.timeIntervalSinceNow.rounded()))
    }

    /// The provider's own explanation, when it sends one. Tavily uses
    /// `detail.error`, DeepSeek uses the OpenAI-style `error.message`, Exa uses
    /// a top-level `error` string.
    ///
    /// The text is shown to the model, so it is clipped and stripped of
    /// newlines rather than passed through verbatim.
    static func providerMessage(_ data: Data?) -> String? {
        guard let data, !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let raw: String? = {
            if let detail = object["detail"] as? [String: Any],
               let error = detail["error"] as? String {
                return error
            }
            if let error = object["error"] as? String {
                return error
            }
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            return object["message"] as? String
        }()

        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(200))
    }

    /// ISO 8601 (Brave `page_age`, DeepSeek `date`) and RFC 1123 (Tavily
    /// `published_date`) both show up; try each.
    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }

        let rfc1123 = DateFormatter()
        rfc1123.locale = Locale(identifier: "en_US_POSIX")
        rfc1123.timeZone = TimeZone(identifier: "GMT")
        rfc1123.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return rfc1123.date(from: trimmed)
    }
}
