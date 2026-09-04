import Foundation

/// Resolves the total download size of (a subset of) a HuggingFace repository by
/// reading the repo tree, so download progress can be expressed as real
/// downloaded-bytes / total-bytes instead of the library's coarse file-count
/// fraction. See `ModelDownloadByteProgress`.
///
/// One cheap `tree?recursive=true` request per download (negligible next to a
/// multi-GB weights transfer) yields per-file sizes; the caller restricts which
/// files count via `matches`, since the model stores download only a subset of
/// some repos (specific Core ML bundles / weight precision).
struct HuggingFaceRepoSize: Sendable {
    /// One entry from the HF repo tree.
    struct Entry: Sendable, Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    /// Injectable tree fetch (repoId, revision) -> entries. Defaults to the live
    /// HF API. Returning `nil` means the tree could not be read.
    typealias TreeFetcher = @Sendable (_ repoID: String, _ revision: String) async -> [Entry]?

    private let fetchTree: TreeFetcher

    init(fetchTree: @escaping TreeFetcher = HuggingFaceRepoSize.liveTreeFetcher()) {
        self.fetchTree = fetchTree
    }

    /// Sum the byte size of every file whose repo-relative `path` satisfies
    /// `matches`. Returns `nil` when the tree can't be read or when no matching
    /// file reports a usable size (so the caller falls back to the library
    /// fraction rather than dividing by a bogus total).
    func totalBytes(
        repoID: String,
        revision: String = "main",
        matching matches: @escaping @Sendable (String) -> Bool
    ) async -> Int64? {
        guard let entries = await fetchTree(repoID, revision) else { return nil }
        var total: Int64 = 0
        var matchedAny = false
        for entry in entries where entry.type == "file" && matches(entry.path) {
            guard let size = entry.size, size > 0 else { continue }
            total += size
            matchedAny = true
        }
        return matchedAny ? total : nil
    }

    /// Live fetcher hitting the public HF tree API.
    /// `GET https://huggingface.co/api/models/{repo}/tree/{revision}?recursive=true`.
    static func liveTreeFetcher(
        session: URLSession = .shared,
        host: URL = URL(string: "https://huggingface.co")!
    ) -> TreeFetcher {
        { repoID, revision in
            var components = URLComponents(
                url: host
                    .appendingPathComponent("api")
                    .appendingPathComponent("models")
                    .appendingPathComponent(repoID)
                    .appendingPathComponent("tree")
                    .appendingPathComponent(revision),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [URLQueryItem(name: "recursive", value: "true")]
            guard let url = components?.url else { return nil }

            do {
                let (data, response) = try await session.data(from: url)
                guard
                    let http = response as? HTTPURLResponse,
                    (200..<300).contains(http.statusCode)
                else {
                    return nil
                }
                return try JSONDecoder().decode([Entry].self, from: data)
            } catch {
                // Best-effort: a failed listing just means "unknown total", and
                // the store keeps the library's fraction.
                return nil
            }
        }
    }
}
