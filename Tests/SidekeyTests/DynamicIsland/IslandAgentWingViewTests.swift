import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class IslandAgentWingViewTests: XCTestCase {
    /// The recording face is measured and rendered in `IslandAgentWingView`, so
    /// `IslandView` and `IslandPanel` share the same width contract. When the
    /// breathing provider mark is shown, the rendered row adds the mark + its
    /// gap and trades the leading inset down; the measurement widens by
    /// `recordingProviderMarkSlack`. Locking the formula (and its current
    /// value) keeps the two from drifting — a drift reads as a clipped
    /// transcript tail or dead trailing space in the live ticker.
    func test_providerMarkSlackMatchesRenderedMarkLayout() {
        XCTAssertEqual(
            IslandAgentWingView.recordingProviderMarkSlack,
            IslandAgentWingView.recordingMarkSide
                + IslandAgentWingView.recordingMarkSpacing
                + IslandAgentWingView.recordingMarkLeadingPadding
                - IslandAgentWingView.contentHorizontalPadding
        )
        XCTAssertEqual(IslandAgentWingView.recordingProviderMarkSlack, 21)
    }

    func test_recordingTranscriptUpdateDoesNotNotifyComposingFocusChange() {
        let model = WingHarnessModel(wing: .recording(transcript: "first words"))
        let recorder = FocusRecorder()
        let hosting = NSHostingController(
            rootView: WingHarness(model: model, recorder: recorder)
        )
        hosting.view.frame = NSRect(x: 0, y: 0, width: 260, height: 32)
        hosting.view.layoutSubtreeIfNeeded()
        drainRunLoop()

        XCTAssertEqual(recorder.values, [])

        model.wing = .recording(transcript: "second words")
        drainRunLoop()
        hosting.view.layoutSubtreeIfNeeded()

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
            faceWidth: 260,
            activityLabel: "thinking...",
            height: 32,
            onComposingFocusChange: recorder.record
        )
    }
}
