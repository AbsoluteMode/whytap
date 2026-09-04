import AppKit
import Combine
import Foundation
import SwiftUI

/// SwiftUI body for the meeting pill — the compact `.suggesting` bar below
/// Dynamic Island and the Stage 4 `.recording` / `.paused` card with the
/// audio-reactive waveform + timer + Pause / Stop controls.
///
/// **English copy only** per the 2026-05-19 design decision. Earlier Stage 3
/// shipped a Russian "Запиши встречу?" placeholder; the Stage 4 prototype at
/// `docs/design/meeting-pill-prototype.swift` is the canonical visual target.
///
/// **Decision-timer source of truth:** `MeetingNudgeView`. The view owns the
/// drain so it can pause while the user hovers Take notes or Skip.
struct MeetingPillView: View {
    @ObservedObject var controller: MeetingPillController

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .hidden:
            Color.clear
        case .suggesting(let meetingId, let deadline):
            MeetingNudgeHostView(
                meetingId: meetingId,
                duration: max(1, deadline.timeIntervalSinceNow),
                onAction: handleNudgeAction
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .suggestingReconnect(let meetingId, _, let gapSeconds, let deadline):
            MeetingNudgeHostView(
                meetingId: meetingId,
                duration: max(1, deadline.timeIntervalSinceNow),
                reconnectGapSeconds: gapSeconds,
                onAction: handleNudgeAction
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .recording(_, let audioLevel, let duration):
            ZStack {
                AmbientBackground()
                MeetingRecordingPillView(
                    audioLevel: audioLevel,
                    duration: duration,
                    isPaused: false,
                    onPauseToggle: { controller.pause() },
                    onStop: { controller.stopRecording() }
                )
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        case .paused(_, let audioLevel, let duration):
            ZStack {
                AmbientBackground()
                MeetingRecordingPillView(
                    audioLevel: audioLevel,
                    duration: duration,
                    isPaused: true,
                    onPauseToggle: { controller.resume() },
                    onStop: { controller.stopRecording() }
                )
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func handleNudgeAction(_ action: MeetingNudgeAction) {
        switch action {
        case .takeNotes:
            Task { await controller._testTapAccept() }
        case .reconnect:
            Task { await controller._testTapReconnect() }
        case .skip:
            Task { await controller._testTapDismiss() }
        case .timedOut:
            controller._testSuggestionTimedOut()
        }
    }
}

// MARK: - Ambient warm background

/// Dark warm radial gradients used by the recording card host. The
/// suggesting state now renders as a compact Dynamic Island-adjacent row.
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.03, blue: 0.03)
            RadialGradient(
                colors: [Color(red: 1, green: 0.43, blue: 0.20).opacity(0.28), .clear],
                center: .bottom, startRadius: 0, endRadius: 600
            )
            RadialGradient(
                colors: [Color(red: 1, green: 0.55, blue: 0.31).opacity(0.08), .clear],
                center: .center, startRadius: 0, endRadius: 500
            )
        }
    }
}

// MARK: - Panel host

/// Borderless top-center NSPanel hosting `MeetingPillView`. Follows the
/// same conventions as `CopiedToastPanel`: `.statusBar` level so it
/// floats above the Dock, `ignoresMouseEvents = false` (the pill needs
/// to receive button clicks), `nonactivatingPanel` so showing it does
/// not steal focus from the user's meeting app.
@MainActor
final class MeetingPillPanel: NSPanel {

    /// Stage 4 recording footprint. Width 640pt comes from the design
    /// prototype (RecordingCard pins `frame(width: 640)`). Height 240pt
    /// fits the recording card: attached tab + timer + waveform.
    static let recordingPanelSize = NSSize(width: 700, height: 240)

    /// Backwards-compatible alias used by older tests for the recording
    /// panel geometry.
    static let panelSize = recordingPanelSize

    /// Visible nudge footprint from `MeetingNudgeView`. Its width tracks
    /// the Dynamic Island width on the selected screen so Retina scaling
    /// does not turn the meeting prompt into a giant strip.
    static let suggestionNudgeHeight: CGFloat = 32
    static let suggestionNudgeTopCornerRadius: CGFloat = 0
    static let suggestionGapBelowIsland: CGFloat = 0

    /// Vertical inset below the menu bar. 60pt clears the menu bar
    /// (24pt + 4pt) plus the system menu's drop-down zone (~32pt) so
    /// the pill never overlaps an open Apple/File/Edit menu.
    static let topInset: CGFloat = 60

    /// Sits above the menu-bar band so the suggestion row can live just
    /// below the Dynamic Island at the top of the physical screen.
    static let windowLevel: NSWindow.Level = .screenSaver

    /// Top-center frame on the given visible rect. The math is pure
    /// so unit tests can exercise it without a real `NSScreen`. Origin
    /// in Cocoa coords (y-up); the pill's `maxY` sits exactly
    /// `topInset` below `visible.maxY`.
    static func topCenterFrame(
        on visible: NSRect,
        pillSize: NSSize
    ) -> NSRect {
        let originX = visible.midX - pillSize.width / 2
        let originY = visible.maxY - topInset - pillSize.height
        return NSRect(
            x: originX,
            y: originY,
            width: pillSize.width,
            height: pillSize.height
        )
    }

    static func suggestionFrame(
        frame: NSRect,
        visibleFrame: NSRect,
        safeAreaTopInset: CGFloat,
        auxiliaryTopLeftArea: NSRect?,
        auxiliaryTopRightArea: NSRect?
    ) -> NSRect {
        let islandFrame = IslandFrameLayout.islandFrame(
            frame: frame,
            visibleFrame: visibleFrame,
            safeAreaTopInset: safeAreaTopInset,
            auxiliaryTopLeftArea: auxiliaryTopLeftArea,
            auxiliaryTopRightArea: auxiliaryTopRightArea
        )

        let panelSize = suggestionPanelSize(forIslandFrame: islandFrame)

        return NSRect(
            x: islandFrame.midX - panelSize.width / 2,
            y: islandFrame.minY - suggestionGapBelowIsland - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    static func suggestionNudgeSize(forIslandFrame islandFrame: NSRect) -> NSSize {
        NSSize(width: islandFrame.width, height: suggestionNudgeHeight)
    }

    static func suggestionPanelSize(forIslandFrame islandFrame: NSRect) -> NSSize {
        suggestionNudgeSize(forIslandFrame: islandFrame)
    }

    static func suggestionFrame(on screen: IslandScreenDescriptor) -> NSRect {
        suggestionFrame(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaTopInset,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    static func topCenterFrame(
        on screen: IslandScreenDescriptor,
        pillSize: NSSize
    ) -> NSRect {
        topCenterFrame(on: screen.visibleFrame, pillSize: pillSize)
    }

    private let controller: MeetingPillController
    private var cancellables = Set<AnyCancellable>()

    init(controller: MeetingPillController) {
        self.controller = controller

        let initialScreen = IslandScreenResolver.currentDescriptor()
        let initialFrame = Self.topCenterFrame(
            on: initialScreen,
            pillSize: Self.recordingPanelSize
        )

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = Self.windowLevel
        self.collectionBehavior = [
            // High-level (.screenSaver) overlay must opt in to foreign apps'
            // full-screen Spaces, else it vanishes over e.g. Dia fullscreen.
            // WHY: docs/decisions/2026-06-24-overlay-foreign-fullscreen.md
            .canJoinAllApplications,
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        // Pill needs to receive button clicks. Hit-testing is restricted
        // to the visible card contents via the SwiftUI background being
        // transparent outside the inner card.
        self.ignoresMouseEvents = false
        self.isMovable = false
        self.hidesOnDeactivate = false

        let host = NSHostingView(rootView: MeetingPillView(controller: controller))
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = host

        // Mirror the state -> visibility hook from CopiedToastPanel.
        // Recording / paused chrome now lives in the Dynamic Island's
        // right band; the panel remains hidden for those states.
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newState in
                guard let self else { return }
                self.applyState(newState)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: IslandScreenResolver.selectionDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        frameRect
    }

    @objc private func handleScreenChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            IslandScreenCache.shared.rebuild()
            self.refreshFrame(for: self.controller.state)
        }
    }

    private func refreshFrame(for state: MeetingPillState) {
        let screen = IslandScreenResolver.currentDescriptor()

        let targetFrame: NSRect
        switch state {
        case .suggesting, .suggestingReconnect:
            targetFrame = Self.suggestionFrame(on: screen)
        case .hidden, .recording, .paused:
            targetFrame = Self.topCenterFrame(
                on: screen,
                pillSize: Self.recordingPanelSize
            )
        }
        setFrame(targetFrame, display: true, animate: false)
        contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
    }

    private func applyState(_ newState: MeetingPillState) {
        switch newState {
        case .hidden, .recording, .paused:
            hasShadow = Self.hasWindowShadow(for: newState)
            orderOut(nil)
        case .suggesting, .suggestingReconnect:
            hasShadow = Self.hasWindowShadow(for: newState)
            refreshFrame(for: newState)
            orderFrontRegardless()
        }
    }

    static func hasWindowShadow(for state: MeetingPillState) -> Bool {
        switch state {
        case .hidden, .suggesting, .suggestingReconnect, .recording, .paused:
            false
        }
    }
}
