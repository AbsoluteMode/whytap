import SwiftUI

/// Reuses the standalone translator, including cancellation, provider errors and
/// the update activity guard. Merely selecting the tool never starts capture.
@MainActor
struct ToolboxTranslationPane: View {
    let mode: TranslationWindowController.Mode
    let deps: ToolboxDeps
    let openFeature: (AIFeature) -> Void
    @StateObject private var presentation = TranslationWindowController.Presentation()
    @State private var controller: TranslationWindowController?
    @State private var embeddingID: UUID?

    var body: some View {
        Group {
            if let controller {
                TranslationView(text: controller.text, subtitles: controller.subtitles,
                                presentation: presentation,
                                openSettings: { feature in
                                    controller.endEmbedding(embeddingID)
                                    // The containing Settings window owns navigation.
                                    openFeature(feature)
                                }, embedded: true)
            } else {
                Text("Translation is unavailable. Reopen Settings to reconnect the tool.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            presentation.mode = mode
            controller = deps.translationController()
            embeddingID = controller?.beginEmbedding()
        }
        .onDisappear { if let embeddingID { controller?.endEmbedding(embeddingID) } }
    }

}

@MainActor
struct ToolboxRecordingPane: View {
    @ObservedObject private var state = AppState.shared
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(state.meetingRecordingActive
                  ? (state.meetingRecordingPaused ? "Recording paused" : "Recording meeting")
                  : "Ready to take meeting notes",
                  systemImage: state.meetingRecordingActive ? "record.circle.fill" : "mic")
                .foregroundStyle(state.meetingRecordingActive ? Color.red : Color.secondary)
            if state.meetingRecordingActive {
                Text(Duration.seconds(state.meetingRecordingDuration).formatted(.time(pattern: .minuteSecond)))
                    .font(.system(.title2, design: .monospaced))
            }
            Text("Record your microphone and system audio. Processing uses your Meeting routes in API & Models.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(state.meetingRecordingActive ? "Stop recording" : "Start recording", action: toggle)
                .buttonStyle(.borderedProminent)
                .tint(state.meetingRecordingActive ? .red : .blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct ToolboxHistoryPane: View {
    let deps: ToolboxDeps
    @State private var mode: HistoryStripMode = .clipboard
    @State private var cards: [HistoryStripCard] = []

    var body: some View {
        HistoryHoverView(mode: $mode, cards: cards, targetAppName: nil,
                         onSelectMode: { mode = $0 }, onCopy: deps.copyHistoryCard,
                         onPreviewAnchorChange: { _, _ in }, onPaste: { _ in },
                         allowsKeyboardPaste: false)
            .task(id: mode) {
                cards = []
                let loaded = await deps.historyCards(mode)
                guard !Task.isCancelled else { return }
                cards = loaded
            }
    }
}
