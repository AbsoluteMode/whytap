import AppKit
import SwiftUI

/// Browsing never changes the cost filter. Only choosing a day commits it.
// WHY: .project-docs/decisions/2026-10-20-feature-costs.md
struct AIUsageCalendarMonth {
    let calendar: Calendar
    let latest: Date
    private(set) var start: Date

    init(date: Date, latest: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        self.latest = calendar.startOfDay(for: latest)
        start = calendar.dateInterval(of: .month, for: min(date, latest))!.start
    }
    var year: Int { calendar.component(.year, from: start) }
    var month: Int { calendar.component(.month, from: start) }
    var lastYear: Int { calendar.component(.year, from: latest) }
    var months: [Int] { Array(calendar.range(of: .month, in: .year, for: start)!) }
    var days: [Date] {
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -offset, to: start)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: first)! }
    }
    func allows(_ day: Date) -> Bool {
        calendar.startOfDay(for: day) <= latest && calendar.component(.era, from: day) == calendar.component(.era, from: latest)
    }
    mutating func show(year: Int, month: Int) {
        guard (1...lastYear).contains(year),
              let proposed = calendar.date(from: DateComponents(era: calendar.component(.era, from: latest), year: year, month: month, day: 1)) else { return }
        start = calendar.dateInterval(of: .month, for: min(proposed, latest))!.start
    }
    func shifted(_ value: Int) -> Date? {
        guard let next = calendar.date(byAdding: .month, value: value, to: start), allows(next) else { return nil }
        return next
    }
    mutating func show(_ date: Date) { start = calendar.dateInterval(of: .month, for: min(date, latest))!.start }
}

@MainActor
struct AIUsageDateCalendar: View {
    let title: String
    @Binding var date: Date
    let latest: Date
    let close: () -> Void
    @State private var visible: AIUsageCalendarMonth
    @FocusState private var focusedDay: Date?
    @FocusState private var focusedAction: String?

    init(title: String, date: Binding<Date>, latest: Date, close: @escaping () -> Void,
         calendar: Calendar = .current) {
        self.title = title; _date = date; self.latest = latest; self.close = close
        _visible = State(initialValue: AIUsageCalendarMonth(date: date.wrappedValue, latest: latest, calendar: calendar))
    }
    private var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = visible.calendar
        formatter.locale = visible.calendar.locale ?? .current
        return formatter
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                navigation("chevron.left", label: "Previous month", offset: -1)
                AIUsageCalendarMonthSelector(items: visible.months.map { month in
                    .init(value: month, title: formatter.standaloneMonthSymbols[month - 1],
                          enabled: visible.year < visible.lastYear || month <= visible.calendar.component(.month, from: visible.latest))
                }, selection: visible.month) { visible.show(year: visible.year, month: $0) }
                    .frame(width: 114, height: 30)
                    .modifier(CalendarHoverFeedback())
                AIUsageCalendarYear(year: visible.year, latest: visible.lastYear) { visible.show(year: $0, month: visible.month) }
                    .frame(width: 80, height: 30)
                    .modifier(CalendarHoverFeedback())
                navigation("chevron.right", label: "Next month", offset: 1)
            }
            let weekdays = formatter.shortStandaloneWeekdaySymbols!
            HStack(spacing: 2) {
                ForEach(0..<7) { index in
                    Text(weekdays[(visible.calendar.firstWeekday - 1 + index) % 7])
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(MacSettingsTheme.text2)
                        .frame(maxWidth: .infinity)
                }
            }.accessibilityHidden(true)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(visible.days, id: \.self) { day in
                    // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
                    Button { date = day; close() } label: {
                        Text("\(visible.calendar.component(.day, from: day))")
                            .font(.system(size: 13, weight: visible.calendar.isDate(day, inSameDayAs: date) ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(AIUsageCalendarButtonStyle(selected: visible.calendar.isDate(day, inSameDayAs: date),
                                                  inMonth: visible.calendar.isDate(day, equalTo: visible.start, toGranularity: .month)))
                    .focused($focusedDay, equals: day)
                    .onKeyPress(.return) { date = day; close(); return .handled }
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(focusedDay == day ? (visible.calendar.isDate(day, inSameDayAs: date) ? MacSettingsTheme.text : MacSettingsTheme.accent) : .clear, lineWidth: 1.5) }
                    .disabled(!visible.allows(day))
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(visible.calendar.isDate(day, inSameDayAs: date) ? .isSelected : [])
                }
            }
            .onMoveCommand { direction in
                guard let focusedDay else { return }
                let offset: Int
                switch direction { case .left: offset = -1; case .right: offset = 1
                case .up: offset = -7; case .down: offset = 7; @unknown default: return }
                if let next = visible.calendar.date(byAdding: .day, value: offset, to: focusedDay), visible.allows(next) {
                    visible.show(next); self.focusedDay = next
                }
            }
            HStack {
                // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
                Button { date = visible.latest; close() } label: { Text("Today").padding(.horizontal, 12).frame(height: 30).background(MacSettingsTheme.controlBg, in: RoundedRectangle(cornerRadius: 6)) }
                    .buttonStyle(AIUsageCalendarButtonStyle(selected: false, inMonth: true)).focused($focusedAction, equals: "today")
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(focusedAction == "today" ? MacSettingsTheme.accent : .clear, lineWidth: 1.5) }
                Spacer()
                // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
                Button(action: close) { Text("Done").padding(.horizontal, 12).frame(height: 30) }
                    .buttonStyle(AIUsageCalendarButtonStyle(selected: true, inMonth: true)).focused($focusedAction, equals: "done")
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(focusedAction == "done" ? MacSettingsTheme.text : .clear, lineWidth: 1.5) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12).frame(width: 310)
        .foregroundStyle(MacSettingsTheme.text)
        .accessibilityElement(children: .contain).accessibilityLabel("\(title) date")
        .onExitCommand(perform: close)
    }
    private func navigation(_ image: String, label: String, offset: Int) -> some View {
        // lilBro-exempt: inside a sheet or popover opened from a row that reports itself; Lil Bro leads to that row
        Button { if let next = visible.shifted(offset) { visible.show(next) } } label: {
            Image(systemName: image).font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 30)
        }
        .buttonStyle(AIUsageCalendarButtonStyle(selected: false, inMonth: true))
        .disabled(visible.shifted(offset) == nil).focused($focusedAction, equals: label)
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(focusedAction == label ? MacSettingsTheme.accent : .clear, lineWidth: 1.5) }
        .accessibilityLabel(label).help(label)
    }
}

private struct CalendarHoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(enabled && (hovered || focused) ? MacSettingsTheme.accent.opacity(focused ? 1 : 0.6) : .clear, lineWidth: 1) }
            .focused($focused).onHover { hovered = $0 }
    }
}

struct AIUsageCalendarButtonStyle: ButtonStyle {
    let selected: Bool
    let inMonth: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : (inMonth ? MacSettingsTheme.text : MacSettingsTheme.text2))
            .background {
                RoundedRectangle(cornerRadius: 6).fill(selected ? MacSettingsTheme.accentFill :
                    (enabled && (hovered || configuration.isPressed) ? MacSettingsTheme.text.opacity(configuration.isPressed ? 0.2 : 0.1) : .clear))
            }
            .overlay { RoundedRectangle(cornerRadius: 6).fill(MacSettingsTheme.text.opacity(enabled ? (configuration.isPressed ? 0.08 : (hovered ? 0.04 : 0)) : 0)) }
            .opacity(enabled ? 1 : 0.35).contentShape(Rectangle()).onHover { hovered = $0 }
    }
}

/// Recent years are one click away; typing supports any earlier year without
/// a menu containing thousands of entries. AppKit retains editing/Tab behavior.
@MainActor
struct AIUsageCalendarYear: NSViewRepresentable {
    let year: Int
    let latest: Int
    let select: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let field = NSComboBox()
        field.isEditable = true; field.completes = false
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.numberOfVisibleItems = 10
        field.setAccessibilityLabel("Year")
        field.setAccessibilityHelp("Choose or type a year from 1 to \(latest)")
        field.delegate = context.coordinator
        field.target = context.coordinator; field.action = #selector(Coordinator.commit(_:))
        field.addItems(withObjectValues: (max(1, latest - 99)...latest).reversed().map(String.init))
        return field
    }
    func updateNSView(_ field: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil { field.stringValue = String(year) }
    }
    @MainActor
    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: AIUsageCalendarYear
        init(_ parent: AIUsageCalendarYear) { self.parent = parent }
        @objc func commit(_ field: NSComboBox) {
            guard let value = Int(field.stringValue), (1...parent.latest).contains(value) else {
                field.stringValue = String(parent.year); return
            }
            parent.select(value)
        }
        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSComboBox,
                  let value = field.objectValueOfSelectedItem as? String, let year = Int(value) else { return }
            parent.select(year)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSComboBox { commit(field) }
        }
    }
}

/// A native popup exposes its real highlight state, unlike the shared plain
/// SwiftUI Menu path. Keep this change local to the Costs calendar.
@MainActor
struct AIUsageCalendarMonthSelector: NSViewRepresentable {
    struct Item {
        let value: Int
        let title: String
        let enabled: Bool
    }
    let items: [Item]
    let selection: Int
    let select: (Int) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> AIUsageCalendarMonthButton {
        let button = AIUsageCalendarMonthButton(frame: .zero, pullsDown: false)
        configure(button, coordinator: context.coordinator)
        return button
    }
    func updateNSView(_ button: AIUsageCalendarMonthButton, context: Context) {
        context.coordinator.parent = self
        configure(button, coordinator: context.coordinator)
    }
    func configure(_ button: AIUsageCalendarMonthButton, coordinator: Coordinator) {
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.bezelStyle = .rounded
        button.autoenablesItems = false
        button.isEnabled = enabled
        if button.itemTitles != items.map(\.title) {
            button.removeAllItems()
            button.addItems(withTitles: items.map(\.title))
        }
        for (index, item) in items.enumerated() {
            button.item(at: index)?.tag = item.value
            button.item(at: index)?.isEnabled = item.enabled
        }
        button.selectItem(withTag: selection)
        button.target = coordinator; button.action = #selector(Coordinator.choose(_:))
        button.setAccessibilityLabel("Month")
    }
    @MainActor
    final class Coordinator: NSObject {
        var parent: AIUsageCalendarMonthSelector
        init(_ parent: AIUsageCalendarMonthSelector) { self.parent = parent }
        @objc func choose(_ button: NSPopUpButton) {
            guard button.isEnabled, let item = button.selectedItem, item.isEnabled else { return }
            parent.select(item.tag)
        }
    }
}

@MainActor
final class AIUsageCalendarMonthButton: NSPopUpButton {
    override func highlight(_ flag: Bool) { super.highlight(flag && isEnabled) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isEnabled, isHighlighted else { return }
        NSColor.labelColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: MacPopupMetrics.radius, yRadius: MacPopupMetrics.radius).fill()
    }
}
