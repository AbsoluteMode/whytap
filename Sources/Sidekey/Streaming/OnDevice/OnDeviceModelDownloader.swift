import FluidAudio
import Foundation
import os.log

/// Downloads the on-device model's files with real byte progress.
///
/// FluidAudio's `DownloadUtils.downloadRepo` reports progress only when a
/// whole file lands: it passes its progress delegate to the async
/// `URLSession.download(for:)`, which never calls `didWriteData`. Recorded on
/// 2026-11-28: 23 files, one encoder weight file of about 445 MB of 483 MB,
/// so the bar sat at 4.9% for the whole big file and then jumped to 97%.
/// This downloader lists and selects exactly the files FluidAudio would (its
/// public registry, the model's required folders plus root .json/.txt
/// files), skips files already in place and fetches the rest with a
/// delegate-based download task, so every received chunk moves the bar.
/// Same host, same files, no other network traffic.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
struct OnDeviceModelDownloader: Sendable {
    struct RemoteFile: Equatable, Sendable {
        let path: String
        let size: Int64
    }

    typealias Progress = @Sendable (_ bytesDone: Int64, _ totalBytes: Int64) -> Void

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "on-device-speech")

    let model: OnDeviceSpeechModel

    /// Downloads into `parent/<repo folder>`; `progress` gets the bytes in
    /// place (files already on disk count from the first call) and the total.
    func download(to parent: URL, progress: @escaping Progress) async throws {
        let repoPath = parent.appendingPathComponent(model.repo.folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true)
        let files = try await listFiles()
        let total = files.reduce(Int64(0)) { $0 + max(0, $1.size) }
        var done: Int64 = 0
        var missing: [RemoteFile] = []
        for file in files {
            if FileManager.default.fileExists(atPath: repoPath.appendingPathComponent(file.path).path) {
                done += max(0, file.size)
            } else {
                missing.append(file)
            }
        }
        os_log("on-device download: files=%{public}d missing=%{public}d total_mb=%{public}d cached_mb=%{public}d",
               log: Self.log, type: .info, files.count, missing.count, Int(total / 1_000_000), Int(done / 1_000_000))
        progress(done, total)
        for file in missing {
            try Task.checkCancellation()
            let destination = repoPath.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if file.size == 0 {
                // Hugging Face answers 500 for empty files, as FluidAudio notes.
                FileManager.default.createFile(atPath: destination.path, contents: Data())
                continue
            }
            let base = done
            try await ByteProgressDownload.run(
                request: try Self.request(Self.url("\(model.repo.remotePath)/resolve/main/\(Self.encoded(file.path))")),
                destination: destination,
                onBytes: { written in progress(min(total, base + min(written, file.size)), total) }
            )
            done += file.size
            progress(done, total)
        }
    }

    /// FluidAudio's selection: folders of the model's required Core ML
    /// bundles, plus `.json` and `.txt` files outside them.
    func listFiles() async throws -> [RemoteFile] {
        let required = ModelNames.ASR.requiredModelsV3(precision: model.encoderPrecision)
        let patterns = required.map { "\($0)/" }
        var files: [RemoteFile] = []
        func list(_ path: String) async throws {
            let apiPath = path.isEmpty ? "tree/main" : "tree/main/\(path)"
            let url = try Self.url("api/models/\(model.repo.remotePath)/\(apiPath)")
            let (data, response) = try await DownloadUtils.fetchWithAuth(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw OnDeviceModelDownloadError.httpStatus(http.statusCode)
            }
            guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw OnDeviceModelDownloadError.invalidListing
            }
            for item in items {
                guard let itemPath = item["path"] as? String, let type = item["type"] as? String else { continue }
                if type == "directory" {
                    if patterns.contains(where: { itemPath.hasPrefix($0) || $0.hasPrefix(itemPath + "/") }) {
                        try await list(itemPath)
                    }
                } else if type == "file" {
                    let included = patterns.contains { itemPath.hasPrefix($0) }
                        || itemPath.hasSuffix(".json") || itemPath.hasSuffix(".txt")
                    if included { files.append(RemoteFile(path: itemPath, size: Int64(item["size"] as? Int ?? -1))) }
                }
            }
        }
        try await list("")
        return files
    }

    /// FluidAudio's `ModelRegistry` URLs (its name is shadowed by ours):
    /// the same base, overridable by the same environment variables.
    private static func url(_ path: String) throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["REGISTRY_URL"] ?? environment["MODEL_REGISTRY_URL"] ?? "https://huggingface.co"
        guard let url = URL(string: "\(base)/\(path)") else { throw OnDeviceModelDownloadError.invalidListing }
        return url
    }

    private static func encoded(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    /// FluidAudio's request: its timeout and an optional Hugging Face token
    /// from the environment.
    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 1800)
        let environment = ProcessInfo.processInfo.environment
        if let token = environment["HF_TOKEN"] ?? environment["HUGGING_FACE_HUB_TOKEN"]
            ?? environment["HUGGINGFACEHUB_API_TOKEN"] {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

enum OnDeviceModelDownloadError: Error, Equatable {
    case httpStatus(Int)
    case invalidListing
}

/// One file over a delegate-based download task: `didWriteData` reports
/// every chunk, unlike the async convenience API.
private final class ByteProgressDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onBytes: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var lastReport: TimeInterval = 0

    private init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    static func run(request: URLRequest, destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let download = ByteProgressDownload(destination: destination, onBytes: onBytes)
        let session = URLSession(configuration: DownloadUtils.sharedSession.configuration,
                                 delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                download.lock.lock()
                download.continuation = continuation
                download.lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // About ten reports a second are enough for a bar.
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let due = now - lastReport >= 0.1
        if due { lastReport = now }
        lock.unlock()
        if due { onBytes(totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw OnDeviceModelDownloadError.httpStatus(http.statusCode)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.lock(); moveError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = error ?? moveError
        lock.unlock()
        if let failure {
            continuation?.resume(throwing: (failure as? URLError)?.code == .cancelled ? CancellationError() : failure)
        } else {
            continuation?.resume()
        }
    }
}
