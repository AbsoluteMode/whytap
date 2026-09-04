import SwiftUI

/// Native renderer for a meeting protocol. Takes parsed `[NoteBlock]` and
/// lays them out as a calm, centered reading column styled with the shared
/// Settings tokens — the same look as every other Settings surface, no web
/// chrome. Read-only by design (notes are LLM summaries).
@MainActor
struct MeetingNoteView: View {

    let blocks: [NoteBlock]

    // Local palette derived from the shared theme.
    private let headingColor = MacSettingsTheme.text
    private let bodyColor = Color.white.opacity(0.82)
    private let markerColor = Color.white.opacity(0.40)

    private static let columnWidth: CGFloat = 680

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    row(for: block)
                }
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 96)
        }
        .tint(MacSettingsTheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func row(for block: NoteBlock) -> some View {
        switch block {
        case let .heading(level, text):
            heading(text, level: level)
        case let .paragraph(text):
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(bodyColor)
                .lineSpacing(4)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .bullet(text):
            listRow(marker: Text("•"), text: text)
        case let .numbered(index, text):
            listRow(marker: Text("\(index).").monospacedDigit(), text: text)
        case let .checkbox(checked, text):
            checkboxRow(checked: checked, text: text)
        case .divider:
            Rectangle()
                .fill(MacSettingsTheme.sep)
                .frame(height: 1)
                .padding(.vertical, 14)
        }
    }

    private func heading(_ text: AttributedString, level: Int) -> some View {
        let size: CGFloat
        let weight: Font.Weight
        let topPad: CGFloat
        let bottomPad: CGFloat
        switch level {
        case 1: size = 26; weight = .bold; topPad = 4; bottomPad = 6
        case 2: size = 18; weight = .semibold; topPad = 22; bottomPad = 2
        default: size = 15.5; weight = .semibold; topPad = 14; bottomPad = 1
        }
        return Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(headingColor)
            .padding(.top, topPad)
            .padding(.bottom, bottomPad)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(marker: Text, text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker
                .font(.system(size: 15))
                .foregroundStyle(markerColor)
                .frame(minWidth: 16, alignment: .trailing)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(bodyColor)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func checkboxRow(checked: Bool, text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(checked ? MacSettingsTheme.accent : markerColor)
                .frame(minWidth: 16, alignment: .center)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(checked ? bodyColor.opacity(0.7) : bodyColor)
                .strikethrough(checked, color: bodyColor.opacity(0.5))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
