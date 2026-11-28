import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
struct HotkeysSettingsView: View {
    @ObservedObject var preferences: HotkeyPreferences
    @State private var draft: HotkeyConfiguration
    @State private var saveError: String?
    /// Shared with the Toolbox Hotkey block: one recorder, Escape cancels.
    @StateObject private var recording = HotkeyRecordingSession<RecordingTarget>()
    private var recordingTarget: RecordingTarget? { recording.target }

    init(preferences: HotkeyPreferences? = nil) {
        let preferences = preferences ?? HotkeyPreferences.shared
        self.preferences = preferences
        _draft = State(initialValue: preferences.configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HotkeySettingRow(
                        iconName: "sparkles",
                        title: "Agent text",
                        detail: Self.rowDetail(
                            base: "Tap opens the text input panel.",
                            for: draft.agentTextShortcut
                        ),
                        gesture: .tap,
                        allowsGestureSwitch: false,
                        shortcutContents: shortcutContents(
                            for: .agentText,
                            fallback: draft.agentTextShortcut.contents
                        ),
                        isRecording: recordingTarget == .agentText,
                        hasConflict: hasConflict(for: .agentText),
                        onGestureChange: { _ in },
                        onRecord: { startRecording(.agentText) }
                    )

                    HotkeySettingRow(
                        iconName: "waveform",
                        title: "Agent voice",
                        detail: Self.rowDetail(
                            base: voiceDetail(for: draft.agentVoiceGesture),
                            for: draft.agentVoiceShortcut
                        ),
                        gesture: draft.agentVoiceGesture,
                        gestureTitle: Self.voiceGestureTitle(for: draft.agentVoiceGesture),
                        allowsGestureSwitch: true,
                        shortcutContents: shortcutContents(
                            for: .agentVoice,
                            fallback: draft.agentVoiceShortcut.contents
                        ),
                        isRecording: recordingTarget == .agentVoice,
                        hasConflict: hasConflict(for: .agentVoice),
                        onGestureChange: { draft.agentVoiceGesture = $0 },
                        onRecord: { startRecording(.agentVoice) }
                    )

                    HotkeySettingRow(
                        iconName: "magnifyingglass",
                        title: "Google text",
                        detail: Self.rowDetail(
                            base: "Tap opens a Google search box.",
                            for: draft.googleSearchTextShortcut
                        ),
                        gesture: .tap,
                        allowsGestureSwitch: false,
                        shortcutContents: shortcutContents(
                            for: .googleText,
                            fallback: draft.googleSearchTextShortcut.contents
                        ),
                        isRecording: recordingTarget == .googleText,
                        hasConflict: hasConflict(for: .googleText),
                        onGestureChange: { _ in },
                        onRecord: { startRecording(.googleText) }
                    )

                    HotkeySettingRow(
                        iconName: "magnifyingglass",
                        title: "Google voice",
                        detail: Self.rowDetail(
                            base: voiceDetail(for: draft.googleSearchVoiceGesture),
                            for: draft.googleSearchVoiceShortcut
                        ),
                        gesture: draft.googleSearchVoiceGesture,
                        gestureTitle: Self.voiceGestureTitle(for: draft.googleSearchVoiceGesture),
                        allowsGestureSwitch: true,
                        shortcutContents: shortcutContents(
                            for: .googleVoice,
                            fallback: draft.googleSearchVoiceShortcut.contents
                        ),
                        isRecording: recordingTarget == .googleVoice,
                        hasConflict: hasConflict(for: .googleVoice),
                        onGestureChange: { draft.googleSearchVoiceGesture = $0 },
                        onRecord: { startRecording(.googleVoice) }
                    )

                    // Drop is reassignable by recording a new key (bare Space →
                    // `.holdSpace`, B1). The gesture switch is live for combos
                    // and locked on Hold when the binding is Space (hold-only:
                    // a tap-Space is indistinguishable from typing a space, B3).
                    HotkeySettingRow(
                        iconName: "mic",
                        title: "Drop voice",
                        detail: Self.dropDetail(for: displayedDropGesture, shortcut: draft.dropVoiceShortcut),
                        gesture: displayedDropGesture,
                        gestureTitle: Self.voiceGestureTitle(for: displayedDropGesture),
                        allowsGestureSwitch: Self.dropGestureSwitchEnabled(shortcut: draft.dropVoiceShortcut),
                        shortcutContents: shortcutContents(
                            for: .dropVoice,
                            fallback: draft.dropVoiceShortcut.contents
                        ),
                        isRecording: recordingTarget == .dropVoice,
                        hasConflict: hasConflict(for: .dropVoice),
                        onGestureChange: { draft.dropVoiceGesture = $0 },
                        onRecord: { startRecording(.dropVoice) }
                    )

                    HotkeySettingRow(
                        iconName: "record.circle",
                        title: "Meeting record",
                        detail: Self.rowDetail(
                            base: "Start a meeting recording anytime; press again to stop.",
                            for: draft.meetingRecordShortcut
                        ),
                        gesture: .tap,
                        allowsGestureSwitch: false,
                        shortcutContents: shortcutContents(
                            for: .meetingRecord,
                            fallback: draft.meetingRecordShortcut.contents
                        ),
                        isRecording: recordingTarget == .meetingRecord,
                        hasConflict: hasConflict(for: .meetingRecord),
                        onGestureChange: { _ in },
                        onRecord: { startRecording(.meetingRecord) }
                    )

                    HotkeySettingRow(
                        iconName: "link",
                        title: "Links insert",
                        detail: Self.rowDetail(
                            base: "Paste the selected link URL into the focused app.",
                            for: draft.usefulLinksInsertShortcut
                        ),
                        gesture: .tap,
                        allowsGestureSwitch: false,
                        shortcutContents: shortcutContents(
                            for: .usefulLinksInsert,
                            fallback: draft.usefulLinksInsertShortcut.contents
                        ),
                        isRecording: recordingTarget == .usefulLinksInsert,
                        hasConflict: hasConflict(for: .usefulLinksInsert),
                        onGestureChange: { _ in },
                        onRecord: { startRecording(.usefulLinksInsert) }
                    )

                    HotkeySettingRow(
                        iconName: "arrow.up.right.square",
                        title: "Links open",
                        detail: Self.rowDetail(
                            base: "Open the selected link in the default browser.",
                            for: draft.usefulLinksOpenShortcut
                        ),
                        gesture: .tap,
                        allowsGestureSwitch: false,
                        shortcutContents: shortcutContents(
                            for: .usefulLinksOpen,
                            fallback: draft.usefulLinksOpenShortcut.contents
                        ),
                        isRecording: recordingTarget == .usefulLinksOpen,
                        hasConflict: hasConflict(for: .usefulLinksOpen),
                        onGestureChange: { _ in },
                        onRecord: { startRecording(.usefulLinksOpen) }
                    )

                    HotkeySettingRow(
                        iconName: "arrow.down",
                        title: "Links next",
                        detail: Self.rowDetail(
                            base: "Move the Agent useful-links selection to the next link.",
                            for: draft.usefulLinksNextShortcut
                        ),
                        gesture: .tap,
                        allowsGestureSwitch: false,
                        shortcutContents: shortcutContents(
                            for: .usefulLinksNext,
                            fallback: draft.usefulLinksNextShortcut.contents
                        ),
                        isRecording: recordingTarget == .usefulLinksNext,
                        hasConflict: hasConflict(for: .usefulLinksNext),
                        onGestureChange: { _ in },
                        onRecord: { startRecording(.usefulLinksNext) }
                    )

                    HotkeySettingRow(
                        iconName: "arrow.up",
                        title: "Links previous",
                        detail: Self.rowDetail(
                            base: "Move the Agent useful-links selection to the previous link.",
                            for: draft.usefulLinksPreviousShortcut
                        ),
                        gesture: .tap,
                        allowsGestureSwitch: false,
                        shortcutContents: shortcutContents(
                            for: .usefulLinksPrevious,
                            fallback: draft.usefulLinksPreviousShortcut.contents
                        ),
                        isRecording: recordingTarget == .usefulLinksPrevious,
                        hasConflict: hasConflict(for: .usefulLinksPrevious),
                        onGestureChange: { _ in },
                        onRecord: { startRecording(.usefulLinksPrevious) }
                    )

                    HotkeySettingRow(
                        iconName: "xmark.circle",
                        title: "Agent close",
                        detail: Self.rowDetail(
                            base: "Close the Agent response window.",
                            for: draft.agentCloseShortcut
                        ),
                        gesture: .tap,
                        allowsGestureSwitch: false,
                        shortcutContents: shortcutContents(
                            for: .agentClose,
                            fallback: draft.agentCloseShortcut.contents
                        ),
                        isRecording: recordingTarget == .agentClose,
                        hasConflict: hasConflict(for: .agentClose),
                        onGestureChange: { _ in },
                        onRecord: { startRecording(.agentClose) }
                    )

                    toolShortcutSection

                    conflictBlock
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            footerBlock
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .overlay(
                    Rectangle()
                        .fill(MacSettingsTheme.sep)
                        .frame(height: 0.5),
                    alignment: .top
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A change saved elsewhere (a confirmed whytap:// hotkey link) shows
        // here unless the user has unsaved edits, which stay theirs.
        .onChange(of: preferences.configuration) { old, new in
            if draft == old { draft = new }
            else { draft.screenshotArrowBindings = new.screenshotArrowBindings }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hotkeys")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
            Text("Change shortcuts, check conflicts, then save. Hints update after Save.")
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var conflictBlock: some View {
        let conflicts = activeConflicts
        if !conflicts.isEmpty || saveError != nil {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(conflicts) { conflict in
                    Label(conflict.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.orange)
                        .lineLimit(2)
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.orange)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(MacSettingsTheme.orange.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(MacSettingsTheme.orange.opacity(0.22), lineWidth: 1)
            )
        }
    }

    private var toolShortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
                .padding(.top, 12)
            Text("Shortcuts stay with the function, even when you move or remove its hover tile.")
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text2)
                .padding(.bottom, 4)
            ForEach(HoverTool.allCases, id: \.self) { tool in
                toolShortcutRow(tool)
            }
        }
    }

    private func toolShortcutRow(_ tool: HoverTool) -> some View {
        let target = RecordingTarget.tool(tool)
        let info = HoverToolRegistry.info(for: tool)
        let shortcut = draft.toolShortcuts[tool]
        return HotkeySettingRow(
            iconName: info.sfSymbol,
            title: tool == .meetingRecord ? "Record (additional shortcut)" : info.title,
            detail: tool.isComingSoon
                ? "\(CalendarAvailability.badge): \(CalendarAvailability.message) A shortcut saved here stays inactive."
                : (shortcut.map { Self.rowDetail(base: info.description, for: $0) } ?? info.description),
            gesture: .tap,
            allowsGestureSwitch: false,
            shortcutContents: shortcutContents(for: target, fallback: shortcut?.contents ?? []),
            isRecording: recordingTarget == target,
            hasConflict: hasConflict(for: target),
            onGestureChange: { _ in },
            onRecord: { startRecording(target) },
            registrationError: shortcut == preferences.toolShortcuts[tool]
                && preferences.unavailableToolShortcuts.contains(tool)
                ? "Shortcut unavailable. Check Accessibility or record another shortcut." : nil,
            onClear: shortcut == nil ? nil : {
                stopRecording()
                draft.toolShortcuts[tool] = nil
            }
        )
    }

    private func startRecording(_ target: RecordingTarget) {
        saveError = nil
        recording.start(target, current: shortcut(for: target)) { shortcut, target in
            assignShortcut(shortcut, to: target)
        }
    }

    private func stopRecording() {
        recording.stop()
    }

    private func shortcutContents(for target: RecordingTarget, fallback: [KeycapContent]) -> [KeycapContent] {
        recordingTarget == target ? recording.contents : fallback
    }

    private func assignShortcut(_ shortcut: HotkeyShortcut, to target: RecordingTarget) {
        // Gate: `.holdSpace` is only valid for Drop. If the recorder emits it
        // for another target (e.g. a bare-Space on Agent close), silently ignore
        // it — the previous binding stays and the recording session remains open
        // so the user can try again. This matches how unrecognised key events
        // return `nil` from the recorder: nothing changes, no error is shown.
        guard Self.allowsHoldSpace(target: target) || shortcut != .holdSpace else {
            return
        }
        switch target {
        case .agentText:
            draft.agentTextShortcut = shortcut
        case .agentVoice:
            draft.agentVoiceShortcut = shortcut
        case .googleText:
            draft.googleSearchTextShortcut = shortcut
        case .googleVoice:
            draft.googleSearchVoiceShortcut = shortcut
        case .dropVoice:
            draft.setDropShortcut(shortcut)
        case .meetingRecord:
            draft.meetingRecordShortcut = shortcut
        case .usefulLinksInsert:
            draft.usefulLinksInsertShortcut = shortcut
        case .usefulLinksOpen:
            draft.usefulLinksOpenShortcut = shortcut
        case .usefulLinksNext:
            draft.usefulLinksNextShortcut = shortcut
        case .usefulLinksPrevious:
            draft.usefulLinksPreviousShortcut = shortcut
        case .agentClose:
            draft.agentCloseShortcut = shortcut
        case .tool(let tool):
            draft.toolShortcuts[tool] = shortcut
        }
    }

    private func shortcut(for target: RecordingTarget) -> HotkeyShortcut? {
        switch target {
        case .agentText:
            return draft.agentTextShortcut
        case .agentVoice:
            return draft.agentVoiceShortcut
        case .googleText:
            return draft.googleSearchTextShortcut
        case .googleVoice:
            return draft.googleSearchVoiceShortcut
        case .dropVoice:
            return draft.dropVoiceShortcut
        case .meetingRecord:
            return draft.meetingRecordShortcut
        case .usefulLinksInsert:
            return draft.usefulLinksInsertShortcut
        case .usefulLinksOpen:
            return draft.usefulLinksOpenShortcut
        case .usefulLinksNext:
            return draft.usefulLinksNextShortcut
        case .usefulLinksPrevious:
            return draft.usefulLinksPreviousShortcut
        case .agentClose:
            return draft.agentCloseShortcut
        case .tool(let tool):
            return draft.toolShortcuts[tool]
        }
    }

    private func hasConflict(for target: RecordingTarget) -> Bool {
        // Match on the *physical-key* identity, not the full `HotkeyBinding`.
        // `conflicts` groups by `conflictKey` (combo / hold-Space ignore the
        // gesture) and reports only the first member's binding, so comparing
        // the whole binding — gesture included — would leave the other member
        // of a tap/hold combo conflict un-highlighted (Stage 1 review fix).
        guard let conflictKey = binding(for: target)?.conflictKey else { return false }
        return activeConflicts.contains { $0.binding.conflictKey == conflictKey }
    }

    private func binding(for target: RecordingTarget) -> HotkeyBinding? {
        switch target {
        case .agentText:
            return HotkeyBinding(gesture: .tap, key: draft.agentTextShortcut.bindingKey)
        case .agentVoice:
            return HotkeyBinding(gesture: draft.agentVoiceGesture, key: draft.agentVoiceShortcut.bindingKey)
        case .googleText:
            return HotkeyBinding(gesture: .tap, key: draft.googleSearchTextShortcut.bindingKey)
        case .googleVoice:
            return HotkeyBinding(gesture: draft.googleSearchVoiceGesture, key: draft.googleSearchVoiceShortcut.bindingKey)
        case .dropVoice:
            return HotkeyBinding(gesture: draft.dropVoiceGesture, key: draft.dropVoiceShortcut.bindingKey)
        case .meetingRecord:
            return HotkeyBinding(gesture: .tap, key: draft.meetingRecordShortcut.bindingKey)
        case .usefulLinksInsert:
            return HotkeyBinding(gesture: .tap, key: draft.usefulLinksInsertShortcut.bindingKey)
        case .usefulLinksOpen:
            return HotkeyBinding(gesture: .tap, key: draft.usefulLinksOpenShortcut.bindingKey)
        case .usefulLinksNext:
            return HotkeyBinding(gesture: .tap, key: draft.usefulLinksNextShortcut.bindingKey)
        case .usefulLinksPrevious:
            return HotkeyBinding(gesture: .tap, key: draft.usefulLinksPreviousShortcut.bindingKey)
        case .agentClose:
            return HotkeyBinding(gesture: .tap, key: draft.agentCloseShortcut.bindingKey)
        case .tool(let tool):
            return draft.toolShortcuts[tool].map { HotkeyBinding(gesture: .tap, key: $0.bindingKey) }
        }
    }

    private func voiceDetail(for gesture: HotkeyGesture) -> String {
        switch gesture {
        case .tap:
            return "Tap once to start recording, tap again to send it."
        case .hold:
            return "Hold starts recording; release sends it."
        }
    }

    // MARK: - B3 display & gating rules

    /// Drop's gesture as DISPLAYED: stale persisted `.holdSpace`+`.tap`
    /// (written by builds predating the hold-only normalization) must not
    /// render a locked switch labeled "Toggle" next to hold-only detail.
    /// Single source: `HotkeyConfiguration.normalizedDropGesture` — the same
    /// rule registration applies. The draft value itself is left untouched;
    /// it heals on the next `setDropShortcut`/Save.
    private var displayedDropGesture: HotkeyGesture {
        HotkeyConfiguration.normalizedDropGesture(
            shortcut: draft.dropVoiceShortcut,
            gesture: draft.dropVoiceGesture
        )
    }

    /// Drop's gesture switch is locked while the binding is Space: a tap-Space
    /// trigger would fire on every typed space, so Space is hold-only by rule.
    static func dropGestureSwitchEnabled(shortcut: HotkeyShortcut) -> Bool {
        shortcut != .holdSpace
    }

    /// Voice rows display `.tap` as "Toggle" (tap starts, tap stops) — for a
    /// one-shot action "Tap" is accurate, for voice capture it reads wrong.
    /// Delegates to `HotkeyGesture.voiceTitle` (single source of truth); kept
    /// as a static so existing call-sites and tests do not need re-pointing.
    static func voiceGestureTitle(for gesture: HotkeyGesture) -> String {
        gesture.voiceTitle
    }

    static func dropDetail(for gesture: HotkeyGesture, shortcut: HotkeyShortcut) -> String {
        if shortcut == .holdSpace {
            return "Hold starts recording; release stops and pastes. Space is hold-only — a tap is indistinguishable from typing a space."
        }
        var detail: String
        switch gesture {
        case .tap:
            detail = "Tap once to start recording, tap again to stop and paste."
        case .hold:
            detail = "Hold starts recording; release stops and pastes."
        }
        // Bare+tap Drop is Carbon-registered (no swallow) — the key is grabbed
        // globally, same caption as the non-Drop rows. Bare+hold rides the
        // CGEventTap swallow and keeps typing intact, so no warning there.
        if gesture == .tap, let caption = bareKeyCaption(for: shortcut) {
            detail += " " + caption
        }
        return detail
    }

    /// Caption warning shared by every row: produced when a binding is a bare
    /// printable combo (no modifier, on a key that types text). Registered
    /// through Carbon, such a key is grabbed globally and stops inserting its
    /// character — the user must see that before saving. Returns `nil` for
    /// modifier combos, `.modifier` keys, `.holdSpace` (its hold-only story
    /// lives in `dropDetail`), and non-typing bare keys (arrows, Home/End/
    /// Page Up/Page Down, F1–F20), which insert nothing a global grab could
    /// break.
    static func bareKeyCaption(for shortcut: HotkeyShortcut) -> String? {
        guard let combo = shortcut.combo,
              combo.modifiers == 0,
              !nonTypingBareKeyCodes.contains(combo.keyCode) else { return nil }
        return "While assigned, \(combo.keyTitle) stops typing its character."
    }

    /// Detail string for non-Drop rows: the base description plus
    /// `bareKeyCaption` when the row's CURRENT binding is a bare printable
    /// combo. Non-Drop rows register through Carbon, which grabs the key
    /// globally regardless of gesture — so the caption applies to ANY bare
    /// binding here. Drop assembles its own detail in `dropDetail` and is the
    /// one exception: bare+hold rides the CGEventTap swallow (typing
    /// preserved, no warning), bare+tap appends this same caption.
    static func rowDetail(base: String, for shortcut: HotkeyShortcut) -> String {
        guard let caption = bareKeyCaption(for: shortcut) else { return base }
        return base + " " + caption
    }

    /// Bare keys that do not insert or erase text when typed: the four
    /// arrows, the nav cluster (Home/End/Page Up/Page Down) and F1–F20.
    /// Grabbing them globally doesn't break typing, so the bare-key caption
    /// stays silent — "← stops typing its character" would be false, and the
    /// default Links bindings are bare arrows (the default config must not
    /// ship with four warnings out of the box). Delete and Forward Delete are
    /// deliberately NOT here: they erase text, so a global grab does break
    /// editing and the caption stays on.
    private static let nonTypingBareKeyCodes: Set<UInt32> = {
        var codes: Set<UInt32> = [
            CarbonHotkeyMonitor.leftArrowKeyCode,
            CarbonHotkeyMonitor.rightArrowKeyCode,
            CarbonHotkeyMonitor.upArrowKeyCode,
            CarbonHotkeyMonitor.downArrowKeyCode
        ]
        for navKey in [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown] {
            codes.insert(UInt32(navKey))
        }
        for fKey in [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20
        ] {
            codes.insert(UInt32(fKey))
        }
        return codes
    }()

    /// Whether `.holdSpace` is a valid recording result for `target`. Only the
    /// Drop row may bind Space as a hold-only trigger — all other rows record
    /// Space-based shortcuts through the standard combo path if at all.
    private static func allowsHoldSpace(target: RecordingTarget) -> Bool {
        target == .dropVoice
    }

    private enum RecordingTarget: Equatable {
        case agentText
        case agentVoice
        case googleText
        case googleVoice
        case dropVoice
        case meetingRecord
        case usefulLinksInsert
        case usefulLinksOpen
        case usefulLinksNext
        case usefulLinksPrevious
        case agentClose
        case tool(HoverTool)
    }

    private var footerBlock: some View {
        HStack(spacing: 10) {
            MacButton(title: "Reset to defaults", style: .default, isEnabled: draft != .defaults) {
                stopRecording()
                draft = .defaults
                saveError = nil
            }

            Spacer()

            MacButton(title: "Revert", style: .default, isEnabled: draft != preferences.configuration) {
                stopRecording()
                draft = preferences.configuration
                saveError = nil
            }

            MacButton(
                title: "Save",
                style: .primary,
                isEnabled: draft != preferences.configuration && activeConflicts.isEmpty
            ) {
                do {
                    try preferences.apply(draft)
                    saveError = nil
                    stopRecording()
                } catch {
                    saveError = "Resolve duplicate shortcuts before saving."
                }
            }
        }
    }

    private var activeConflicts: [HotkeyConflict] {
        draft.conflicts
    }
}

@MainActor
struct HotkeySettingRow: View {
    let iconName: String
    let title: String
    let detail: String
    let gesture: HotkeyGesture
    /// Display label for the gesture slot. `nil` falls back to `gesture.title`
    /// ("Tap"/"Hold"). Voice rows pass `voiceGestureTitle(for:)` so `.tap`
    /// renders as "Toggle" without changing the underlying model value.
    var gestureTitle: String? = nil
    let allowsGestureSwitch: Bool
    let shortcutContents: [KeycapContent]
    let isRecording: Bool
    let hasConflict: Bool
    let onGestureChange: (HotkeyGesture) -> Void
    let onRecord: () -> Void
    var registrationError: String? = nil
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(MacSettingsTheme.text2)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .lineLimit(2)
                if let registrationError {
                    Text(registrationError)
                        .font(.system(size: 11))
                        .foregroundStyle(MacSettingsTheme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                ShortcutGestureSlot(
                    title: gestureTitle ?? gesture.title,
                    rowTitle: title,
                    isSwitchable: allowsGestureSwitch,
                    hasConflict: hasConflict,
                    onTap: {
                        if allowsGestureSwitch {
                            onGestureChange(gesture == .tap ? .hold : .tap)
                        }
                    }
                )
                if shortcutContents.isEmpty && !isRecording {
                    Button("Record shortcut", action: onRecord)
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(MacSettingsTheme.accent)
                        .help("Press a shortcut, then release all keys. Escape cancels.")
                        .accessibilityLabel("Record shortcut for \(title)")
                } else {
                    // One element per row's keys: each cap alone read
                    // "Shortcut key", and the row label the stack used to
                    // carry was copied onto the mode button too, so automation
                    // found two "Drop voice shortcut" buttons and could press
                    // neither. WHY: .project-docs/decisions/2026-11-28-agent-all-hotkeys.md
                    HStack(spacing: 6) {
                        ForEach(Array(visibleShortcutContents.enumerated()), id: \.offset) { _, content in
                            ShortcutKeySlot(content: content, isRecording: isRecording,
                                            hasConflict: hasConflict, onTap: onRecord)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(title) shortcut")
                    .accessibilityValue(isRecording ? "Recording. Press a shortcut, then release all keys; Escape cancels."
                                        : Self.spokenKeys(shortcutContents))
                    .accessibilityHint("Records a new shortcut.")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onRecord() }
                }
                if let onClear {
                    Button(action: onClear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MacSettingsTheme.text2)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove shortcut")
                    .accessibilityLabel("Remove shortcut for \(title)")
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(MacSettingsTheme.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
                .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous))
    }

    /// The keys as one phrase for VoiceOver and automation ("Option M").
    static func spokenKeys(_ contents: [KeycapContent]) -> String {
        contents.isEmpty ? "Not set" : contents.map(\.spokenName).joined(separator: " ")
    }

    private var visibleShortcutContents: [KeycapContent?] {
        if shortcutContents.isEmpty {
            return [nil]
        }
        return shortcutContents.map(Optional.some)
    }
}

@MainActor
private struct ShortcutGestureSlot: View {
    /// Display label for the slot (e.g. "Hold", "Toggle"). The caller is
    /// responsible for mapping the model gesture to the desired display string
    /// via `HotkeysSettingsView.voiceGestureTitle(for:)` when needed.
    let title: String
    /// The row's action, so each row's mode button has its own name.
    let rowTitle: String
    let isSwitchable: Bool
    let hasConflict: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSwitchable ? MacSettingsTheme.text : MacSettingsTheme.text2)
                .frame(width: 52, height: 30)
                .background(slotBackground)
                .overlay(slotStroke)
        }
        .buttonStyle(.plain)
        .disabled(!isSwitchable)
        .accessibilityLabel("\(rowTitle) mode")
        .accessibilityValue(title)
        .accessibilityHint(isSwitchable ? "Switches between Hold and Toggle." : "")
    }

    private var slotBackground: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(isSwitchable ? MacSettingsTheme.controlBg : MacSettingsTheme.segBg)
    }

    private var slotStroke: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
                hasConflict ? MacSettingsTheme.red.opacity(0.82) : MacSettingsTheme.sepStrong,
                lineWidth: hasConflict ? 1.2 : 1
            )
    }
}

@MainActor
struct ShortcutKeySlot: View {
    let content: KeycapContent?
    let isRecording: Bool
    let hasConflict: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(slotFill)
                    .overlay(slotStroke)
                if let content {
                    KeycapView(content: content)
                }
            }
            .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shortcut key")
    }

    private var slotFill: Color {
        if hasConflict {
            return MacSettingsTheme.red.opacity(0.12)
        }
        return isRecording ? MacSettingsTheme.accent.opacity(0.10) : Color.clear
    }

    private var slotStroke: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
                hasConflict ? MacSettingsTheme.red.opacity(0.88)
                    : MacSettingsTheme.accent.opacity(isRecording ? 0.55 : 0.0),
                style: StrokeStyle(
                    lineWidth: hasConflict ? 1.2 : 1,
                    dash: isRecording && !hasConflict ? [4, 3] : []
                )
            )
    }
}
