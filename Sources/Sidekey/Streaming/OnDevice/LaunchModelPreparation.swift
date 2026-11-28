import Foundation

/// Launch-time model preparations run one after another, dictation first.
/// The on-device speech model and Shot's Vision recognizer both compile in
/// the system's Neural Engine compiler after a new build is installed; run
/// together, the speech model was ready only when Vision was done too.
// WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
enum LaunchModelPreparation {
    @discardableResult
    static func start(speech: Task<Void, Never>?,
                      then ocr: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            await speech?.value
            await ocr()
        }
    }
}
