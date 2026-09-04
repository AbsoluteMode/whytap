import AppKit
import Foundation

/// Async favicon resolver for Useful Links chips whose provider is unknown
/// and host detection failed. Uses Google's S2 favicon proxy because it
/// works for any HTTP origin without requiring direct fetches from the
/// target domain (avoids CORS preflights, captive portals, and the slow
/// "favicon.ico discovery dance").
///
/// Caching: the underlying `URLSession` uses `URLCache.shared`, which is
/// memory + disk by default in a Mac app sandbox. We configure the request
/// with a 7-day `cachePolicy` hint so the response stays warm across
/// launches even when Google's `Cache-Control` headers say something
/// shorter — favicon images barely change and offline-reading the same
/// chip a week later should still resolve.
///
/// Deduplication: one in-flight `Task` per URL host, so a Pill 2 that
/// surfaces three links to the same domain only makes one network round
/// trip and the three chips share the result.
@MainActor
final class FaviconService {
    /// Shared instance — favicon lookups are app-global, not panel-scoped.
    static let shared = FaviconService()

    /// Round-trip cap. Above this the chip stays on its globe fallback
    /// instead of waiting forever for an unreachable proxy.
    static let requestTimeout: TimeInterval = 4

    /// Cap on disk cache for the favicon-specific URLSession. 5 MB holds
    /// ~5000 favicons at typical PNG sizes — far more than a single user
    /// will ever surface in chips.
    private static let cacheCapacityBytes = 5 * 1024 * 1024

    private let session: URLSession
    private var inflight: [URL: Task<NSImage?, Never>] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Dedicated config so the URLCache used by favicons does not
            // collide with the app's main API client cache (different
            // size budget, different invalidation rhythm).
            let cache = URLCache(
                memoryCapacity: Self.cacheCapacityBytes,
                diskCapacity: Self.cacheCapacityBytes,
                diskPath: "favicon-cache"
            )
            let config = URLSessionConfiguration.default
            config.urlCache = cache
            config.requestCachePolicy = .returnCacheDataElseLoad
            config.timeoutIntervalForRequest = Self.requestTimeout
            config.timeoutIntervalForResource = Self.requestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    /// Returns an icon for the host of `url`, or `nil` on any failure.
    /// `nil` means "let the chip stay on its globe fallback" — callers
    /// must not throw, must not show an error state.
    func icon(forURL url: URL) async -> NSImage? {
        guard let endpoint = Self.s2Endpoint(for: url) else {
            return nil
        }

        if let existing = inflight[endpoint] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [session] in
            let request = URLRequest(
                url: endpoint,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: Self.requestTimeout
            )
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let image = NSImage(data: data) else {
                    return nil
                }
                return image
            } catch {
                return nil
            }
        }
        inflight[endpoint] = task
        let image = await task.value
        inflight[endpoint] = nil
        return image
    }

    /// Builds the Google S2 favicon endpoint for `url`. Public so tests
    /// can pin the exact URL shape (and so a future swap to a different
    /// proxy stays a one-line change). `nonisolated` because it's a pure
    /// function over `URLComponents` — no actor state touched.
    nonisolated static func s2Endpoint(for url: URL) -> URL? {
        guard let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.google.com"
        components.path = "/s2/favicons"
        components.queryItems = [
            URLQueryItem(name: "domain", value: host),
            URLQueryItem(name: "sz", value: "64")
        ]
        return components.url
    }
}
