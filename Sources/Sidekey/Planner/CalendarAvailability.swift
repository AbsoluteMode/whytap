import Foundation

/// The one switch that opens or closes Calendar for users.
///
/// Calendar is shown with a "Soon" badge while it is closed: its tile, search
/// row, Toolbox pane and Integrations card are visible but inert, no hotkey or
/// `whytap://` link opens it, and nothing asks macOS for calendar access, signs
/// in to a provider or reads events. The feature code is untouched; stored
/// connections and settings stay on disk (and in backups) and work again when
/// the switch is opened.
///
/// To open Calendar again, change `shipped` to `true`, nothing else.
// WHY: .project-docs/decisions/2026-11-21-calendar-soon.md
enum CalendarAvailability {
    /// ← the single switch. `false` = "Soon".
    static let shipped = false

    /// Tests that exercise the Calendar code itself open it for their duration
    /// and restore it in tearDown. Never set outside tests.
    nonisolated(unsafe) static var testOverride: Bool?

    static var isOpen: Bool { testOverride ?? shipped }

    /// The plaque shown wherever Calendar is listed while it is closed.
    static let badge = "Soon"

    /// One sentence for the places that explain why nothing happens.
    static let message = "Calendar is coming soon."

    /// The reason to refuse a connection, refresh or open; nil when Calendar is open.
    static var blockReason: String? { isOpen ? nil : message }
}

extension HoverTool {
    /// A tool that is listed (with a "Soon" badge) but cannot be used yet.
    var isComingSoon: Bool { self == .calendar && !CalendarAvailability.isOpen }

    /// The badge text for a coming-soon tool, nil for a usable one.
    var comingSoonBadge: String? { isComingSoon ? CalendarAvailability.badge : nil }
}
