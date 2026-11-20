import Foundation

/// Soniox's async file API (upload -> job -> poll -> transcript), shared by
/// meeting notes and Drop batch recovery.
enum SonioxFileAPI {
    static let baseURL = URL(string: "https://api.soniox.com/v1/")!
    /// Files take the async model; `stt-rt-*` is realtime only.
    static let asyncModel = ModelRegistry.sonioxRecordedModel

    static func request(path: String, method: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// The `id` of an uploaded file or a created job. It goes into request
    /// paths, so anything but a UUID reads as nil.
    static func resourceID(in data: Data) throws -> String? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = object?["id"] as? String, UUID(uuidString: id) != nil else { return nil }
        return id
    }
}
