import SwiftUI

struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    private static let previewRowCount = 8
    @Environment(\.islandAnswerHitBridge) private var answerHitBridge
    @Environment(\.isEnabled) private var isEnabled
    @State private var width: CGFloat = 0
    @State private var expanded = false
    @State private var disclosureID = UUID()
    @FocusState private var disclosureFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let style = MarkdownTableStyle.choose(headers: headers, rows: rows, width: width)
            tableRows(rows.prefix(Self.previewRowCount), style: style, showHeader: true)
            if rows.count > Self.previewRowCount {
                disclosure
                if expanded {
                    tableRows(rows.dropFirst(Self.previewRowCount), style: style, showHeader: false)
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    @ViewBuilder
    private func tableRows(_ slice: ArraySlice<[String]>, style: MarkdownTableStyle, showHeader: Bool) -> some View {
        switch style {
        case .grid(let columnWidths):
            VStack(alignment: .leading, spacing: 0) {
                if showHeader {
                    gridRow(headers, columnWidths: columnWidths, isHeader: true)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(slice.indices, id: \.self) { index in
                    if showHeader || index > slice.startIndex {
                        Divider()
                    }
                    gridRow(rows[index], columnWidths: columnWidths, isHeader: false)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(rowLabel(rows[index], index: index))
                }
            }
        case .records:
            VStack(alignment: .leading, spacing: 5) {
                if slice.isEmpty && showHeader {
                    Text(MarkdownAttributedRun.parseInline(headers.joined(separator: " · ")))
                }
                ForEach(slice.indices, id: \.self) { index in
                    record(rows[index], index: index)
                }
            }
        }
    }

    private func gridRow(_ cells: [String], columnWidths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(columnWidths.indices, id: \.self) { column in
                Text(MarkdownAttributedRun.parseInline(cells.indices.contains(column) ? cells[column] : ""))
                    .fontWeight(isHeader ? .semibold : .regular)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MarkdownTableColumnLayout.cellHorizontalPadding)
                    .padding(.vertical, MarkdownTableColumnLayout.cellVerticalPadding)
                    .frame(width: columnWidths[column], alignment: .topLeading)
            }
        }
    }

    private func record(_ row: [String], index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MarkdownAttributedRun.parseInline(rowTitle(row, index: index)))
                .fontWeight(.semibold)
            ForEach(row.indices.dropFirst(), id: \.self) { column in
                let label = String(MarkdownAttributedRun.parseInline(columnLabel(column)).characters)
                Text(verbatim: label + " · ").foregroundColor(.secondary)
                + Text(MarkdownAttributedRun.parseInline(row[column]))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowLabel(row, index: index))
    }

    private func rowTitle(_ row: [String], index: Int) -> String {
        if let title = row.first, !title.isEmpty { return title }
        return "Row \(index + 1)"
    }

    private func columnLabel(_ column: Int) -> String {
        if headers.indices.contains(column), !headers[column].isEmpty { return headers[column] }
        return "Column \(column + 1)"
    }

    private func rowLabel(_ row: [String], index: Int) -> String {
        let fields = row.indices.dropFirst().filter { !row[$0].isEmpty }.map { column in
            columnLabel(column) + ": " + row[column]
        }
        let parts = [rowTitle(row, index: index)] + fields
        return parts.map { String(MarkdownAttributedRun.parseInline($0).characters) }.joined(separator: ", ")
    }

    @ViewBuilder
    private var disclosure: some View {
        if let answerHitBridge, isEnabled {
            disclosureButton.islandHoverHitTarget(
                bridge: answerHitBridge, id: .init(tableDisclosure: disclosureID),
                context: "", action: toggleRows
            )
        } else {
            disclosureButton
        }
    }

    private var disclosureButton: some View {
        Button(action: toggleRows) {
            Label(
                expanded ? "Show fewer rows" : "\(rows.count - Self.previewRowCount) more rows",
                systemImage: expanded ? "chevron.up" : "chevron.down"
            )
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(MarkdownTableDisclosureStyle(focused: disclosureFocused))
        .focused($disclosureFocused)
    }

    private func toggleRows() {
        expanded.toggle()
    }
}

private struct MarkdownTableDisclosureStyle: ButtonStyle {
    let focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandHoverNativePressed) private var nativePressed
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        let pressed = nativePressed || configuration.isPressed
        configuration.label
            .background(shape.fill(Color.primary.opacity(
                isEnabled ? (pressed ? 0.20 : hovered ? 0.13 : 0.06) : 0.03
            )))
            .overlay(shape.strokeBorder(focused && isEnabled ? Color.primary : .clear, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }
}
