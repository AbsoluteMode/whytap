import XCTest
@testable import Sidekey

/// The real model, opt-in: downloads Parakeet (about 470 MB) into the folder
/// named by `WHYTAP_ON_DEVICE_E2E` and transcribes every `.wav` found there
/// (16 kHz mono PCM16). Skipped in an ordinary run, which loads no model and
/// touches no network.
final class OnDeviceSpeechEndToEndTests: XCTestCase {
    func test_download_load_and_transcribe_with_the_real_model() async throws {
        guard let path = ProcessInfo.processInfo.environment["WHYTAP_ON_DEVICE_E2E"], !path.isEmpty else {
            throw XCTSkip("Set WHYTAP_ON_DEVICE_E2E to a folder with .wav files to run the real model")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let store = OnDeviceSpeechModelStore(rootDirectory: folder.appendingPathComponent("models", isDirectory: true))

        let downloadStarted = Date()
        try await store.download(progress: nil)
        let status = await store.status()
        XCTAssertEqual(status, .ready)
        print("E2E download+load \(String(format: "%.1f", Date().timeIntervalSince(downloadStarted))) s")

        let transcriber = OnDeviceBatchTranscriber(readiness: .ready, decoder: ParakeetSpeechDecoder(store: store))
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no .wav files in \(path)")
        for file in files {
            let language = file.deletingPathExtension().lastPathComponent.hasPrefix("en") ? "en" : "ru"
            let started = Date()
            let text = try await transcriber.transcribe(audio: Data(contentsOf: file), language: language)
            print("E2E \(file.lastPathComponent) \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(text)")
            XCTAssertFalse(text.isEmpty, file.lastPathComponent)
        }

        try await store.delete()
        let after = await store.status()
        XCTAssertEqual(after, .notDownloaded)
    }
}
