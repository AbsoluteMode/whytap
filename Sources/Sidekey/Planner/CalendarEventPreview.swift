import AppKit
import SwiftUI

// WHY: .project-docs/decisions/2026-11-21-calendar-event-details.md
/// What a day-grid block shows for its height, by priority: title, time,
/// description, attendees. Anything cut or left out earns the hover preview.
struct CalendarEventBlockPlan: Equatable {
    static let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let metaFont = NSFont.systemFont(ofSize: 10)
    static let titleLineHeight = NSLayoutManager().defaultLineHeight(for: titleFont)
    static let metaLineHeight = NSLayoutManager().defaultLineHeight(for: metaFont)
    /// Above and below the lines of a multi-line block.
    static let verticalPadding: CGFloat = 2
    /// Description lines that come before the attendee line; spare room adds more.
    static let firstNoteLines = 3
    /// Text room in an all-day chip: 220 pt minus paddings, logo and gaps.
    static let chipTextWidth: CGFloat = 182
    /// Lines may overhang the padding by this much.
    private static let tolerance: CGFloat = 0.5

    var oneLine = true
    var titleLines = 1
    var noteLines = 0
    var showsAttendees = false
    var needsPreview = true

    static func lines(_ text: String, font: NSFont, width: CGFloat) -> Int {
        guard !text.isEmpty else { return 0 }
        guard width > 0 else { return Int.max }
        let height = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        return max(1, Int((height / NSLayoutManager().defaultLineHeight(for: font) - 0.05).rounded(.up)))
    }

    static func fitsOneLine(_ text: String, font: NSFont, width: CGFloat) -> Bool {
        (text as NSString).size(withAttributes: [.font: font]).width <= width
    }

    /// - Parameters:
    ///   - meta: "11:00 – 12:00 · Work", the time line of a multi-line block.
    ///   - notes: the description as plain text.
    ///   - attendeeSummary: "Anna, Boris +3", or nil when nobody else attends.
    static func make(height: CGFloat, textWidth: CGFloat, title: String, meta: String, notes: String,
                     attendeeSummary: String?, hasAttendees: Bool, hasLocation: Bool) -> CalendarEventBlockPlan {
        var spare = height - verticalPadding * 2 - titleLineHeight - metaLineHeight
        // Too short for a time line: logo, title and start time share one line.
        guard spare + tolerance >= 0 else { return CalendarEventBlockPlan() }
        func take(_ line: CGFloat) -> Bool {
            guard spare + tolerance >= line else { return false }
            spare -= line
            return true
        }
        var plan = CalendarEventBlockPlan(oneLine: false)
        let titleNeed = lines(title, font: titleFont, width: textWidth)
        let notesNeed = lines(notes, font: metaFont, width: textWidth)
        if titleNeed > 1, take(titleLineHeight) { plan.titleLines = 2 }
        while plan.noteLines < min(notesNeed, firstNoteLines), take(metaLineHeight) { plan.noteLines += 1 }
        if attendeeSummary != nil, take(metaLineHeight) { plan.showsAttendees = true }
        while plan.noteLines < notesNeed, take(metaLineHeight) { plan.noteLines += 1 }
        // The block names only some attendees, without responses; location is never in it.
        plan.needsPreview = titleNeed > plan.titleLines || notesNeed > plan.noteLines
            || !fitsOneLine(meta, font: metaFont, width: textWidth) || hasAttendees || hasLocation
        return plan
    }

    /// An all-day chip shows the title and calendar on one line and nothing else.
    static func chipNeedsPreview(title: String, source: String, hasDetails: Bool) -> Bool {
        let used = (title as NSString).size(withAttributes: [.font: titleFont]).width + 5
            + (source as NSString).size(withAttributes: [.font: metaFont]).width
        return hasDetails || used > chipTextWidth
    }
}

/// Everything about an event, prepared for the preview bubble.
struct CalendarEventPreviewContent: Equatable {
    let id: String
    let title: String
    /// "Tuesday, 21 October · 11:00 – 12:00", or "… · All day".
    let when: String
    /// Calendar and account, "Work · anna@gmail.com".
    let calendar: String
    let source: CalendarEventSource?
    let location: String?
    /// What a click on the event does: "Join meeting", "Open in Outlook & Teams".
    let action: String?
    /// The meeting link without its query, which can hold a passcode.
    let link: String?
    let notes: String?
    let attendees: [PlannerEventAttendee]

    static func linkText(_ url: URL) -> String {
        let path = url.path == "/" ? "" : url.path
        return (url.host ?? url.absoluteString) + path
    }
}

enum CalendarEventPreviewPolicy {
    static let bubbleWidth = HistoryHoverPreviewPolicy.bubbleWidth
    /// Attendees listed by name; the rest are counted.
    static let listedAttendees = 12

    /// Beside the event, lifted so the bubble's bottom stays inside the island area.
    static func bubbleTop(eventTop: CGFloat, bubbleHeight: CGFloat, areaHeight: CGFloat) -> CGFloat {
        max(0, min(eventTop, areaHeight - bubbleHeight))
    }
}

struct CalendarEventPreviewAnchor: Equatable {
    let content: CalendarEventPreviewContent
    /// Visible part of the hovered block in the island hover-zone coordinate space.
    let rowFrame: CGRect
}

/// The hovered event's preview. Leaving an event hides it after a short delay
/// that entering the next event cancels, so moving across adjacent events
/// never flashes an empty frame.
@MainActor
final class CalendarEventPreviewState: ObservableObject {
    static let shared = CalendarEventPreviewState()
    @Published private(set) var anchor: CalendarEventPreviewAnchor?
    private let hideDelay: Duration
    private var pendingHide: Task<Void, Never>?

    init(hideDelay: Duration = .milliseconds(120)) { self.hideDelay = hideDelay }

    func show(_ content: CalendarEventPreviewContent, frame: CGRect) {
        // WHY: .project-docs/decisions/2026-11-21-calendar-soon.md
        // A closed ("Soon") Calendar never shows event details.
        guard CalendarAvailability.isOpen else { clear(); return }
        pendingHide?.cancel(); pendingHide = nil
        let next = CalendarEventPreviewAnchor(content: content, rowFrame: frame)
        if anchor != next { anchor = next }
    }

    func hide(_ id: String) {
        guard anchor?.content.id == id else { return }
        pendingHide?.cancel()
        let delay = hideDelay
        pendingHide = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.anchor?.content.id == id else { return }
            self.anchor = nil
        }
    }

    func clear() {
        pendingHide?.cancel(); pendingHide = nil
        anchor = nil
    }
}

/// Non-interactive bubble left of the drawer, styled like the To-do and
/// History previews. A click on the event itself joins or opens it.
struct CalendarEventPreviewBubble: View {
    let content: CalendarEventPreviewContent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        details
            .padding(HistoryHoverPreviewPolicy.contentPadding)
            .background {
                // Over other apps, white text needs the same contrast on any window behind it.
                shape.fill(Color(white: 0.14))
                    .overlay(shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
            }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                CalendarSourceLogoView(source: content.source, size: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95)).fixedSize(horizontal: false, vertical: true)
                    Text(content.when).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.75))
                    Text(content.calendar).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                }
            }
            if let location = content.location {
                row("mappin.and.ellipse", Text(location)).lineLimit(3)
            }
            if let action = content.action {
                row(content.link == nil ? "arrow.up.right.square" : "video",
                    Text(action).fontWeight(.semibold) + Text(" · click the event").foregroundColor(.white.opacity(0.6)))
                if let link = content.link {
                    Text(link).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1).truncationMode(.middle).padding(.leading, 18)
                }
            }
            if let notes = content.notes {
                Text(notes).font(.system(size: 11)).foregroundStyle(.white.opacity(0.88))
                    .lineLimit(10).fixedSize(horizontal: false, vertical: true)
            }
            if !content.attendees.isEmpty { attendees }
        }
        .frame(width: CalendarEventPreviewPolicy.bubbleWidth - HistoryHoverPreviewPolicy.contentPadding * 2,
               alignment: .topLeading)
    }

    private func row(_ symbol: String, _ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).frame(width: 12)
            text.font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white.opacity(0.88))
    }

    private var attendees: some View {
        let listed = content.attendees.prefix(CalendarEventPreviewPolicy.listedAttendees)
        let rest = content.attendees.count - listed.count
        return VStack(alignment: .leading, spacing: 3) {
            Text(content.attendees.count == 1 ? "1 attendee" : "\(content.attendees.count) attendees")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            ForEach(Array(listed.enumerated()), id: \.offset) { _, person in
                HStack(spacing: 5) {
                    status(person.status)
                    Text(person.displayName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                    if person.isCurrentUser { Text("you").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)) }
                    if person.isOrganizer { Text("organizer").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)) }
                }
            }
            if rest > 0 {
                Text("+\(rest) more").font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private func status(_ status: PlannerEventAttendee.Status?) -> some View {
        let (symbol, color): (String, Color) = switch status {
        case .accepted: ("checkmark.circle.fill", .green)
        case .declined: ("xmark.circle.fill", Color(red: 1, green: 0.42, blue: 0.4))
        case .tentative: ("questionmark.circle.fill", .orange)
        case .pending, nil: ("circle", .white.opacity(0.5))
        }
        return Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(color).frame(width: 12)
            .accessibilityLabel(status?.rawValue ?? "no response")
    }
}
