import Foundation

/// Builds a Google search-results URL for a spoken or typed query.
/// Returns `nil` for an empty / whitespace-only query so callers can
/// no-op instead of opening a blank Google page.
enum GoogleSearchURL {
    static func make(query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        // URLComponents percent-encodes the query value (spaces -> %20,
        // Unicode/Cyrillic -> UTF-8 %-escapes, reserved &/? escaped).
        return components?.url
    }
}
