import Foundation

enum OnboardingAudioResources {
    private static let subdirectory = "OnboardingAudio"

    static func welcomeVoiceURL() -> URL? {
        Bundle.main.url(
            forResource: "welcome-voice",
            withExtension: "mp3",
            subdirectory: subdirectory
        )
    }

    static func url(forSample name: String) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: "mp3",
            subdirectory: subdirectory
        )
    }
}
