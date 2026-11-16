import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class IslandAgentWingViewTests: XCTestCase {
    func test_recordingTranscriptUpdateDoesNotNotifyComposingFocusChange() {
        let model = WingHarnessModel(wing: .recording(transcript: ""))
        let recorder = FocusRecorder()
        let hosting = NSHostingController(
            rootView: WingHarness(model: model, recorder: recorder)
        )
        hosting.view.frame = NSRect(x: 0, y: 0, width: 260, height: 32)
        hosting.view.layoutSubtreeIfNeeded()
        drainRunLoop()

        XCTAssertEqual(recorder.values, [])

        for text in ["first words", "first words while listening", "corrected words"] {
            model.wing = .recording(transcript: text)
            drainRunLoop()
            hosting.view.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(
            recorder.values,
            [],
            "Live transcript deltas must not spam the panel's keyboard-focus callback; only face changes should."
        )
    }

    private func drainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}

@MainActor
private final class WingHarnessModel: ObservableObject {
    @Published var wing: IslandAgentFlowStore.Wing

    init(wing: IslandAgentFlowStore.Wing) {
        self.wing = wing
    }
}

@MainActor
private final class FocusRecorder {
    private(set) var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }
}

private struct WingHarness: View {
    @ObservedObject var model: WingHarnessModel
    let recorder: FocusRecorder

    var body: some View {
        IslandAgentWingView(
            wing: model.wing,
            faceWidth: model.wing == .recording(transcript: "")
                ? IslandAgentWingView.recordingFaceWidth(textWidth: 0, providerMarkVisible: false)
                : IslandFrameLayout.agentWingRecordingWidth,
            activityLabel: "thinking...",
            height: 32,
            onComposingFocusChange: recorder.record
        )
    }
}
