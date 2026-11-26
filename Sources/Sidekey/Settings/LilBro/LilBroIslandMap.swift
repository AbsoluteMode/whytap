import Foundation

/// Every part of the island a person can see, and what turns it on, off or
/// changes it (REV 24). A part names the Settings rows that control it, or
/// says plainly that nothing in Settings does and what does instead, so
/// Lil Bro never answers "there is no such setting" about something on the
/// island (the music player is hidden with the eye, not in Settings).
///
/// `views` lists the SwiftUI views that draw the part. `LilBroServiceMapTests`
/// scans the island's source for views and fails when one belongs to no
/// part: a new island element must get its place here.
// WHY: .project-docs/decisions/2026-11-24-lil-bro-answers-from-whytap.md (REV 24)
enum LilBroIslandMap {
    struct Part: Equatable {
        let name: String
        /// What the person sees and when.
        let what: String
        /// How it is turned on, off or changed; for a part with no rows, what
        /// to do instead of looking in Settings.
        let control: String
        /// Row ids in `LilBroRow.catalog` that control it; empty when none does.
        let rows: [String]
        let views: [String]
    }

    static let parts: [Part] = [
        Part(
            name: "Island pill",
            what: "The black pill around the notch (or at the top of a display without one): the orb on the left, hints and status on the right. Hover it to open the drawer.",
            control: "Auto-hide island fades it into the notch after about 20 seconds of no use (hover or any shortcut brings it back); Show island on picks the display; Screenshot protection hides it from screenshots and screen shares. It cannot be removed: quitting Whytap removes it.",
            rows: ["other.autoHide", "other.showIslandOn", "other.screenshotProtection"],
            views: ["IslandView", "IslandCompactRow", "IslandWrapRow", "IslandOrbSlot", "IslandMarqueeText", "IslandInlineShortcut"]
        ),
        Part(
            name: "Eye: Hide Hover and Music",
            what: "While you hover the pill, an eye takes the orb's place on the left.",
            control: "Not in Settings. Click the eye to hide the hover drawer and the music player (it turns into a crossed-out eye); click it again (Show Hover and Music) to bring them back. While they are hidden the brightness keys go back to macOS.",
            rows: [],
            views: ["IslandHideButton"]
        ),
        Part(
            name: "Music (Now Playing)",
            what: "While a track plays in any app: a small wing with the track in the pill's right band, and on hover a player card with artwork, play/pause and skip.",
            control: "Always on; there is no music switch in Settings. To hide the player card, hover the pill and click the eye (Hide Hover and Music); the small wing stays while music plays and goes away when it stops.",
            rows: [],
            views: ["IslandMusicStripView", "IslandMusicTransportButton", "IslandMusicWingView"]
        ),
        Part(
            name: "Shortcut hints",
            what: "When nothing else is shown, the pill's right band takes turns showing the main shortcuts (Drop, Agent).",
            control: "Always on; they show the keys set in Hotkeys, so changing a shortcut changes its hint.",
            rows: ["hotkeys.dropVoice", "hotkeys.agentText", "hotkeys.agentVoice"],
            views: ["IslandPassiveHintsRolling", "IslandPassiveHintView"]
        ),
        Part(
            name: "Hover drawer and tools",
            what: "Hover the pill: Search all tools and your tool tiles; Option 1 to Option 5 open the first five. A tool opens its panel in the drawer.",
            control: "Your hover chooses and orders the tiles; All tools lists every tool and opens it. Hide the whole drawer with the eye.",
            rows: ["toolbox.yourHover", "toolbox.allTools"],
            views: [
                "IslandHoverBackButton", "IslandHoverBackSurface", "IslandHoverBackdropView", "IslandHoverFloatingLayer",
                "IslandHoverFloatingTile", "IslandHoverGlassControlsContainer", "IslandHoverGlassRim",
                "IslandHoverGlassSurfaceModifier", "IslandHoverHitTargetModifier", "IslandHoverPanelControl",
                "IslandHoverSearchResultsList", "IslandHoverTileFrameReporter", "IslandDetachedHoverPanelBackground",
                "IslandSoonBadge", "IslandToolActions",
            ]
        ),
        Part(
            name: "Drop Mode panel and badge",
            what: "The Drop Mode tool switches Fast and Smart; after a switch the pill shows the new mode for a moment.",
            control: "Drop's Mode row or the Drop Mode tool.",
            rows: ["drop.mode", "toolbox.dropMode"],
            views: ["IslandDropModeHoverPanel", "IslandDropModeStatusView", "IslandDropModeStatusActiveBadge"]
        ),
        Part(
            name: "Language panels",
            what: "Input Lang and Output Lang tools: flags for the language you speak and the language Smart writes in.",
            control: "The Input Lang and Output Lang tools, or Drop's Language you speak.",
            rows: ["toolbox.inputLang", "toolbox.outputLang", "drop.language"],
            views: ["IslandLanguageFlagChip", "IslandLanguageFlagCloud", "IslandLanguagePickerPanel", "IslandLanguagePlaceholder"]
        ),
        Part(
            name: "Vocab and Filler panels",
            what: "The words dictation spells right (Vocab) and the words it cuts (Filler), editable from the island.",
            control: "The Vocab and Filler tools or Drop's Vocab and Filler rows.",
            rows: ["toolbox.vocab", "toolbox.filler", "drop.vocab", "drop.filler"],
            views: ["IslandVocabularyChip", "IslandVocabularyEditorPanel", "IslandFillerChip", "IslandFillerEditorPanel"]
        ),
        Part(
            name: "Case panel",
            what: "Case keys and projects in the island: search, add a key, drag a key to another project, delete a project.",
            control: "The Case tool, or Case's Your keys.",
            rows: ["toolbox.caseVault", "case.yourKeys"],
            views: [
                "IslandCaseVaultPanel", "IslandCaseAddKeyRow", "IslandCaseIconButton", "IslandCaseProjectDeleteConfirmation",
                "IslandCaseProjectRow", "IslandCaseSecretRow", "CaseVaultEditField", "CaseVaultFieldFeedback",
            ]
        ),
        Part(
            name: "Notify panel",
            what: "What arrived from your notification sources, with Clear All.",
            control: "The Notify tool; Add your own connects another source.",
            rows: ["toolbox.notifs", "notify.inIsland", "notify.addYourOwn"],
            views: ["NotifyHoverPanel", "NotifyPanelRoot", "NotificationSourceIcon"]
        ),
        Part(
            name: "Brightness strip",
            what: "The Display tool's brightness slider, with a yellow Extra part above the normal maximum.",
            control: "The Display tool and its Hold brightness, Extra and Brightness keys rows.",
            rows: ["toolbox.brightness", "toolbox.holdBrightness", "toolbox.extraBrightness", "toolbox.brightnessKeys"],
            views: ["IslandBrightnessStrip"]
        ),
        Part(
            name: "Dictation wing",
            what: "While you dictate, the pill shows your words as you speak; if the text could not be typed, Couldn't deliver with Retry.",
            control: "Drop's rows: its shortcut, Mode, lowering other audio and stopping automatically.",
            rows: ["drop.dictate", "drop.mode", "drop.lowerOtherAudio", "drop.stopAutomatically"],
            views: ["IslandLiveTextTicker", "IslandPlainLiveText", "IslandDeliveryFailureView", "DeliveryFailureAction"]
        ),
        Part(
            name: "Agent wing and answer",
            what: "While the Agent works, a wing with what it is doing; then its answer under the island.",
            control: "Agent's switch, Close the answer and Allow file edits and commands.",
            rows: ["agent.switch", "agent.closeShortcut", "agent.allowActions"],
            views: ["IslandAgentWingView", "IslandAgentPulse", "IslandAgentAnswerPanelView"]
        ),
        Part(
            name: "Meeting offer and recording",
            what: "When a call starts: Take notes / Skip with a countdown; while recording: a timer, a waveform and Stop.",
            control: "Meeting Notes' switch turns the offer off; its shortcut starts or stops a recording.",
            rows: ["meetings.switch", "meetings.recordShortcut", "meetings.readyNotification"],
            views: ["IslandMeetingCountdownView", "IslandMeetingRecordingSlotView", "IslandMeetingRecordingStopButton", "IslandMeetingRecordingWaveform"]
        ),
        Part(
            name: "Notification pill",
            what: "A short pill when something arrives from a notification source or a meeting note is ready.",
            control: "Notify's sources and its Meeting notes row.",
            rows: ["notify.inIsland", "notify.meetingNotes"],
            views: ["IslandNotificationPill"]
        ),
        Part(
            name: "Update pill",
            what: "Update when a new version is out (Download / Skip, then Restart / Later), and Updated for a few seconds after it installs.",
            control: "No setting: nothing downloads until you click Download; Skip hides the pill.",
            rows: [],
            views: ["IslandUpdateAvailablePill", "IslandUpdatePillAction", "IslandJustUpdatedPill"]
        ),
        Part(
            name: "Case access request",
            what: "A coding tool asks for Case keys: choose the project and allow or refuse, and see which tools are connected.",
            control: "Case's Your keys and Integrations (Coding tools) change what each tool may use.",
            rows: ["case.yourKeys", "other.integrations"],
            views: [
                "IslandCaseAccessPanel", "CaseAccessInteractionOverlay", "CaseAccessProjectPicker", "CaseAccessSection",
                "CaseAppBrandIcon", "CaseClientChoice", "CaseConnectedAppButton", "CaseConnectedAppIcon",
                "IslandCaseClientPicker", "IslandCaseConnectedApps",
            ]
        ),
        Part(
            name: "Secure Input badge",
            what: "A dimmed app logo to the right of the island: that app holds Secure Input (usually a password field), so macOS keeps Whytap's shortcuts from working; it shakes when you press one.",
            control: "No setting: leave the password field or quit that app and the badge goes away.",
            rows: [],
            views: ["SecureInputHolderView"]
        ),
    ]

    /// The island section of the service map.
    static var lines: [String] {
        var out = [
            "## The island",
            "",
            "Everything on the island, and what turns each part on, off or changes it. \"Not in Settings\" or \"No setting\" means there is no row: say what to do instead, never that it does not exist.",
            "",
        ]
        for part in parts {
            out.append("### \(part.name)")
            out.append("\(part.what) \(part.control)" + (part.rows.isEmpty ? "" : " Rows: " + part.rows.joined(separator: ", ") + "."))
            out.append("")
        }
        return out
    }
}
