import SwiftUI

/// What the Features screens read besides the two Settings view models: the
/// switches the host owns, Drop's mode, the speech model on this Mac and the
/// hotkeys. The Settings window passes its live values; tests and offscreen
/// previews pass a Mac in another state (a fresh install, an Intel Mac).
@MainActor
struct FeaturesEnvironment {
    var dropMode: () -> TranscriptionMode
    var agentOn: () -> Bool
    var meetingsOn: () -> Bool
    var googleOn: () -> Bool
    /// False on an Intel Mac: the on-device model is never offered there.
    var supportsOnDevice: Bool
    var onDevice: OnDeviceSpeechModelController
    var hotkeys: HotkeyPreferences

    init(dropMode: @escaping () -> TranscriptionMode = { .fast },
         agentOn: @escaping () -> Bool = { false },
         meetingsOn: @escaping () -> Bool = { false },
         googleOn: @escaping () -> Bool = { false },
         supportsOnDevice: Bool = OnDeviceSpeechModelStore.isSupportedHost,
         onDevice: OnDeviceSpeechModelController? = nil,
         hotkeys: HotkeyPreferences? = nil) {
        self.dropMode = dropMode
        self.agentOn = agentOn
        self.meetingsOn = meetingsOn
        self.googleOn = googleOn
        self.supportsOnDevice = supportsOnDevice
        self.onDevice = onDevice ?? .shared
        self.hotkeys = hotkeys ?? .shared
    }
}

extension FeatureSetupSnapshot {
    /// The Mac as it is now, read from the same view models the older tabs
    /// show: a feature's status here and its row there cannot disagree.
    @MainActor
    static func live(models: APIAndModelsViewModel, permissions: PermissionsSettingsViewModel,
                     environment: FeaturesEnvironment) -> FeatureSetupSnapshot {
        var statuses: [AIFeature: ModelRowStatus] = [:]
        for row in models.rows { statuses[row.feature] = row.status }
        // "Choose a model" only where the list would not be empty.
        let selectable = Set(AIFeature.activeCases.filter { feature in
            statuses[feature, default: .notSet] != .notSet
                || models.sections(for: feature).contains { !$0.options.isEmpty || $0.acceptsModelName }
        })
        return FeatureSetupSnapshot(
            dropMode: environment.dropMode(),
            models: statuses,
            selectableModels: selectable,
            subtitlesKeyPresent: models.audioTranslate.isActive,
            onDevice: environment.supportsOnDevice ? .available(environment.onDevice.status) : .unsupported,
            keyboardReady: permissions.keyboardReady,
            keyboardNeedsRestart: permissions.keyboardNeedsRestart,
            microphoneGranted: permissions.snapshot.microphoneGranted,
            screenRecordingGranted: permissions.screenRecordingGranted,
            screenNeedsRestart: permissions.screenNeedsRestart,
            dropShortcut: permissions.dropHotkeyStatus,
            agentOn: environment.agentOn(),
            meetingsOn: environment.meetingsOn(),
            googleOn: environment.googleOn()
        )
    }
}
