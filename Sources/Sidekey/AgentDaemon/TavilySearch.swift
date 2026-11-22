import Foundation

struct TavilySearch {
    static let keychainAccount = "byok.tavily.search_api_key"
    var http = NativeAgentHTTP()

    func validate(key: String) async throws {
        let request = try NativeAgentHTTP.request(url: URL(string: "https://api.tavily.com/usage")!, key: key)
        _ = try await http.json(request, limit: 128_000)
    }

    func search(query: String, key: String) async throws -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2000 else { throw NativeAgentError.message("Use a search query of 1–2000 characters.") }
        let request = try NativeAgentHTTP.request(url: URL(string: "https://api.tavily.com/search")!, key: key, body: [
            "query": query, "search_depth": "basic", "max_results": 5,
            "include_answer": false, "include_raw_content": false, "include_images": false,
            "auto_parameters": false
        ])
        let object = try await http.json(request, limit: 1_000_000)
        guard let results = object["results"] as? [[String: Any]] else { throw NativeAgentError.message("Tavily returned no search results.") }
        let bounded: [[String: String]] = results.prefix(5).compactMap { item in
            guard let raw = item["url"] as? String, let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return ["url": raw, "title": String((item["title"] as? String ?? "").prefix(300)),
                    "content": String((item["content"] as? String ?? "").prefix(3000))]
        }
        let data = try JSONSerialization.data(withJSONObject: ["results": bounded])
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class TavilySettings: ObservableObject {
    @Published var draftKey = "" { didSet { clearMessage() } }
    @Published private(set) var configured: Bool
    @Published private(set) var saving = false
    @Published private(set) var message: String?
    @Published private(set) var messageIsError = false
    private let keys: ProviderKeyStore
    private let search: TavilySearch

    init(keys: ProviderKeyStore = ProviderKeyStore(), search: TavilySearch = TavilySearch()) {
        self.keys = keys
        self.search = search
        configured = keys.read(account: TavilySearch.keychainAccount) != nil
    }

    func save() async {
        guard !saving else { return }
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { showMessage("Enter a Tavily API key.", error: true); return }
        saving = true; clearMessage()
        defer { saving = false }
        do {
            try await search.validate(key: key)
            try Task.checkCancellation()
            try keys.save(key, account: TavilySearch.keychainAccount)
            configured = true; draftKey = ""; showMessage("Tavily connected.")
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled else { return }
            showMessage(configured
                ? "Couldn’t replace the Tavily key. Check the key and connection; your saved key is unchanged."
                : "Couldn’t connect Tavily. Check the key and connection, then retry.", error: true)
        }
    }

    func remove() {
        guard !saving else { return }
        do {
            try keys.delete(account: TavilySearch.keychainAccount)
            configured = false; draftKey = ""; showMessage("Tavily disconnected.")
        } catch { showMessage("Couldn’t remove the key from Keychain. Try again.", error: true) }
    }

    func clearDraft() { draftKey = "" }

    private func clearMessage() { message = nil; messageIsError = false }
    private func showMessage(_ text: String, error: Bool = false) {
        messageIsError = error; message = text
    }
}
