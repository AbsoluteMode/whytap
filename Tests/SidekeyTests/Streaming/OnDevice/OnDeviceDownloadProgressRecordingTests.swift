import FluidAudio
import XCTest
@testable import Sidekey

/// Opt-in: drives the real model download into a scratch folder and writes
/// every progress callback with its time, phase and the bytes on disk, so the
/// progress the user sees can be compared with what actually arrived.
/// Set WHYTAP_ON_DEVICE_DOWNLOAD_LOG to a file path; the scratch folder is
/// removed afterwards. Downloads about 470 MB from Hugging Face.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
final class OnDeviceDownloadProgressRecordingTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    }

    func test_record_the_real_download_progress() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHYTAP_ON_DEVICE_DOWNLOAD_LOG"], !path.isEmpty else {
            throw XCTSkip("Set WHYTAP_ON_DEVICE_DOWNLOAD_LOG to record the real download's progress callbacks")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("whytap-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let model = OnDeviceSpeechModel.parakeetTdtV3
        let log = Log()
        let started = Date()
        let repoPath = scratch.appendingPathComponent(model.repo.folderName, isDirectory: true)
        func bytesOnDisk() -> Int64 {
            guard let walker = FileManager.default.enumerator(at: repoPath, includingPropertiesForKeys: [.fileSizeKey])
            else { return 0 }
            var total: Int64 = 0
            for case let url as URL in walker {
                total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return total
        }
        log.add("t_s\traw\tphase\tbytes_on_disk")
        try await DownloadUtils.downloadRepo(
            model.repo, to: scratch, variant: model.encoderPrecision.rawValue,
            progressHandler: { progress in
                let phase: String
                switch progress.phase {
                case .listing: phase = "listing"
                case .downloading(let done, let total): phase = "downloading \(done)/\(total)"
                case .compiling(let name): phase = "compiling \(name)"
                }
                log.add(String(format: "%.2f\t%.4f\t%@\t%lld",
                               Date().timeIntervalSince(started), progress.fractionCompleted, phase, bytesOnDisk()))
            }
        )
        log.add(String(format: "%.2f\tdone\t-\t%lld", Date().timeIntervalSince(started), bytesOnDisk()))
        try log.lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The same for Whytap's own downloader: a clean download, then again
    /// after removing the largest file (the rest are cached).
    func test_record_the_byte_progress_of_our_downloader() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHYTAP_ON_DEVICE_DOWNLOAD_LOG"], !path.isEmpty else {
            throw XCTSkip("Set WHYTAP_ON_DEVICE_DOWNLOAD_LOG to record the real download's progress callbacks")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("whytap-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let downloader = OnDeviceModelDownloader(model: .parakeetTdtV3)
        let log = Log()
        for run in ["clean", "cached"] {
            if run == "cached" {
                let repo = scratch.appendingPathComponent(OnDeviceSpeechModel.parakeetTdtV3.repo.folderName)
                let files = try await downloader.listFiles()
                let largest = try XCTUnwrap(files.max { $0.size < $1.size })
                try FileManager.default.removeItem(at: repo.appendingPathComponent(largest.path))
            }
            let started = Date()
            try await downloader.download(to: scratch) { done, total in
                log.add(String(format: "%@\t%.2f\t%lld\t%lld", run, Date().timeIntervalSince(started), done, total))
            }
        }
        XCTAssertTrue(OnDeviceSpeechModelStore.modelFilesExist(.parakeetTdtV3, root: scratch))
        try log.lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
