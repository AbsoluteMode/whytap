import AppKit
import SwiftUI

struct AgentBlockContainer<Content: View>: View {
    let accent: Color
    let content: Content

    init(accent: Color = Color.primary.opacity(0.12), @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(accent, lineWidth: 1)
        )
    }
}

struct MarkdownBodyText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            let items = MarkdownRenderItem.group(MarkdownBlockParser.parse(text))
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                view(for: item)
            }
        }
        .font(.system(size: 12))
        .foregroundColor(.primary)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for item: MarkdownRenderItem) -> some View {
        switch item {
        case .textRun(let blocks):
            // Consecutive paragraph + heading blocks become a single
            // `Text(AttributedString)` so the user can drag-select
            // across paragraph boundaries (SwiftUI's text selection
            // does not span sibling `Text` views — Maxim's bug).
            Text(MarkdownAttributedRun.attributedString(for: blocks))
        case .block(let block):
            view(for: block)
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: MarkdownAttributedRun.headingSize(for: level), weight: .semibold))
                .padding(.top, level <= 2 ? 2 : 0)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.system(size: 12, weight: .semibold))
                        inlineText(item)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                        inlineText(item)
                    }
                }
            }
        case .codeBlock(_, let code):
            CodeBlockView(code: code)
        case .table(let headers, let rows):
            MarkdownTableView(headers: headers, rows: rows)
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 7) {
                Rectangle()
                    .fill(Color.primary.opacity(0.20))
                    .frame(width: 3)
                inlineText(text)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func inlineText(_ text: String) -> Text {
        Text(.init(text))
    }
}

/// Rendering unit produced by `MarkdownRenderItem.group(_:)`.
///
/// Consecutive paragraph + heading blocks collapse into a single
/// `.textRun` so the renderer can hand them to one `Text(AttributedString)`.
/// SwiftUI text selection does not span sibling `Text` views, so without
/// this grouping the user couldn't drag-select from one paragraph into
/// the next — which is exactly the bug Maxim reported.
///
/// Non-text blocks (lists, code, table, blockquote) keep their custom
/// view trees and stay as standalone `.block` items. Selection across
/// the boundary between a textRun and one of those blocks is the
/// accepted compromise: their renderers (e.g. `CodeBlockView`,
/// `MarkdownTableView`) need to be separate views and cannot fuse into
/// a single `Text`.
enum MarkdownRenderItem: Equatable {
    case textRun([MarkdownBlock])
    case block(MarkdownBlock)

    /// Pure function: walks the parsed block stream and groups
    /// consecutive paragraph + heading blocks into one run.
    ///
    /// Contract:
    /// - Input order is preserved (no reordering, no de-dup).
    /// - Two adjacent text-shaped blocks always end up in the same run.
    /// - A non-text block always interrupts a run.
    /// - Empty input → empty output.
    static func group(_ blocks: [MarkdownBlock]) -> [MarkdownRenderItem] {
        var items: [MarkdownRenderItem] = []
        var buffer: [MarkdownBlock] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            items.append(.textRun(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        for block in blocks {
            if block.isTextShaped {
                buffer.append(block)
            } else {
                flush()
                items.append(.block(block))
            }
        }
        flush()
        return items
    }
}

private extension MarkdownBlock {
    /// Whether this block participates in a fused text run.
    /// paragraph + heading + ordered/unordered lists all fuse into one
    /// `Text(AttributedString)` so drag-select traverses them — Maxim's
    /// canonical "vstuplenie-paragraph + bulleted list" answer shape was
    /// the second regression in the original fix. Code blocks, tables
    /// and blockquotes keep their dedicated views (custom layouts that
    /// can't merge into a `Text`).
    var isTextShaped: Bool {
        switch self {
        case .paragraph, .heading, .unorderedList, .orderedList:
            return true
        case .codeBlock, .table, .blockquote:
            return false
        }
    }
}

/// Builds the `AttributedString` consumed by a fused text run.
///
/// One `Text(AttributedString)` per run is what unlocks drag-select +
/// Cmd+C across paragraph boundaries. Each block contributes its
/// inline-markdown-parsed `AttributedString`; we join them with a blank
/// line so the visual rhythm matches the previous per-block layout
/// (`VStack(spacing: 7)` between standalone paragraphs).
///
/// Heading styling is applied as a per-run attribute (font + weight)
/// instead of a view modifier — that way a heading inside a fused run
/// still looks like a heading, and the run as a whole is still a single
/// `Text` so selection traverses it.
///
/// Inline markdown (`**bold**`, `*italic*`, `[text](url)`, `` `code` ``)
/// goes through `AttributedString(markdown:options:)` with
/// `.inlineOnlyPreservingWhitespace` so block-level constructs like `#`
/// or `>` (which we already parsed into our own block enum) don't get
/// double-processed. If markdown parsing throws (malformed inline
/// syntax), we fall back to the literal string so the user still sees
/// their content instead of an empty render.
enum MarkdownAttributedRun {
    /// Visual gap between blocks inside a fused run.
    ///
    /// `\n\n` (two newlines = one blank line) ran ~24pt taller than the
    /// previous `VStack(spacing: 7)` layout for three paragraphs at the
    /// canonical 320pt width — the empty line was renting a full line
    /// height (~12pt font + 2pt lineSpacing) plus its own line break.
    ///
    /// A single `\n` keeps paragraphs adjacent with one normal line gap
    /// (12pt font + 2pt lineSpacing ≈ 14pt), which lands within ~25% of
    /// the previous per-block layout while still letting drag-select
    /// span the run. The tighter spacing is the accepted cost of the
    /// fused-run approach — Maxim's brief explicitly weighed paragraph
    /// spacing against selection-across-paragraphs and chose the latter.
    private static let blockSeparator = "\n"

    static func attributedString(for blocks: [MarkdownBlock]) -> AttributedString {
        var result = AttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(AttributedString(blockSeparator))
            }
            result.append(attributedString(for: block))
        }
        return result
    }

    static func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1:
            return 16
        case 2:
            return 14
        default:
            return 13
        }
    }

    private static func attributedString(for block: MarkdownBlock) -> AttributedString {
        switch block {
        case .paragraph(let text):
            return parseInline(text)
        case .heading(let level, let text):
            var attributed = parseInline(text)
            attributed.font = .system(size: headingSize(for: level), weight: .semibold)
            return attributed
        case .unorderedList(let items):
            return listAttributedString(items: items, marker: { _ in unorderedListMarker })
        case .orderedList(let items):
            return listAttributedString(items: items, marker: { index in "\(index + 1)." })
        case .codeBlock, .table, .blockquote:
            // Defensive fallback. `MarkdownRenderItem.group` only emits
            // text-shaped blocks (paragraph + heading + lists) inside a
            // textRun, so these branches are unreachable from production
            // code. If a future change expands the run, we degrade to
            // plain inline text instead of crashing.
            return AttributedString(plainText(for: block))
        }
    }

    /// `•` (U+2022) followed by two spaces — gives a small optical
    /// indent between the marker and the item body. We can't use
    /// `NSParagraphStyle.headIndent` to align wrapped continuation
    /// under the body's first character because SwiftUI's
    /// `Text(AttributedString)` only renders attributes from the
    /// `SwiftUIAttributes` scope, which does NOT include
    /// `paragraphStyle`. The wrap of a long list item therefore starts
    /// back at column 0 — an accepted visual trade-off (Maxim weighed
    /// selection-across-list against pixel-perfect indent and chose
    /// selection; see CONCERNS in the PR description).
    private static let unorderedListMarker = "\u{2022}"

    /// Renders one list block as an `AttributedString` with the items
    /// stacked vertically. Each item gets:
    ///
    /// * its marker (`•` for unordered, `n.` for ordered) prefixed by
    ///   two spaces of optical indent
    /// * inline-markdown-parsed body so `**bold**`, `*italic*`,
    ///   `[link](url)` and `` `code` `` inside an item still render
    /// * `\n` between items so a single list lays out as N lines
    ///   inside the fused `Text(AttributedString)`
    ///
    /// Why no `NSParagraphStyle`: SwiftUI's `Text(AttributedString)`
    /// only renders attributes from the `SwiftUIAttributes` scope
    /// (font, foregroundColor, etc.). `paragraphStyle` belongs to the
    /// AppKit scope and is silently dropped by `Text`, so attaching it
    /// gives no visual change — it only inflates the attribute
    /// container at cost without benefit. We accept the cosmetic
    /// regression on long-item wrap (line 2 of a long item starts at
    /// column 0 instead of hanging under the body) in exchange for
    /// drag-select working across the paragraph→list boundary, which
    /// is Maxim's higher-priority requirement.
    private static func listAttributedString(
        items: [String],
        marker: (Int) -> String
    ) -> AttributedString {
        var result = AttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                result.append(AttributedString("\n"))
            }
            result.append(AttributedString("\(marker(index))  "))
            result.append(parseInline(item))
        }
        return result
    }

    private static func parseInline(_ text: String) -> AttributedString {
        // `inlineOnlyPreservingWhitespace` keeps `**bold**`, `*italic*`,
        // `[text](url)` and `` `code` `` while ignoring block-level
        // markdown (`#`, `>`, list markers) — those are already handled
        // by our own block parser.
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return attributed
        }
        return AttributedString(text)
    }

    private static func plainText(for block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let text), .heading(_, let text), .blockquote(let text):
            return text
        case .unorderedList(let items), .orderedList(let items):
            return items.joined(separator: "\n")
        case .codeBlock(_, let code):
            return code
        case .table(let headers, let rows):
            let headerLine = headers.joined(separator: " | ")
            let rowLines = rows.map { $0.joined(separator: " | ") }
            return ([headerLine] + rowLines).joined(separator: "\n")
        }
    }
}

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([String])
    case codeBlock(language: String?, code: String)
    case table(headers: [String], rows: [[String]])
    case blockquote(String)
}

enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            if isBlank(lines[index]) {
                index += 1
                continue
            }

            if let code = codeBlock(from: lines, startingAt: index) {
                blocks.append(.codeBlock(language: code.language, code: code.code))
                index = code.nextIndex
                continue
            }

            if let heading = heading(from: lines[index]) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let table = table(from: lines, startingAt: index) {
                blocks.append(.table(headers: table.headers, rows: table.rows))
                index = table.nextIndex
                continue
            }

            if let list = unorderedList(from: lines, startingAt: index) {
                blocks.append(.unorderedList(list.items))
                index = list.nextIndex
                continue
            }

            if let list = orderedList(from: lines, startingAt: index) {
                blocks.append(.orderedList(list.items))
                index = list.nextIndex
                continue
            }

            if let quote = blockquote(from: lines, startingAt: index) {
                blocks.append(.blockquote(quote.text))
                index = quote.nextIndex
                continue
            }

            let paragraph = paragraph(from: lines, startingAt: index)
            blocks.append(.paragraph(paragraph.text))
            index = paragraph.nextIndex
        }

        return blocks
    }

    private static func codeBlock(
        from lines: [String],
        startingAt index: Int
    ) -> (language: String?, code: String, nextIndex: Int)? {
        let opening = lines[index].trimmingCharacters(in: .whitespaces)
        guard opening.hasPrefix("```") else { return nil }

        let language = String(opening.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        var codeLines: [String] = []
        var cursor = index + 1

        while cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                return (
                    language: language.isEmpty ? nil : language,
                    code: codeLines.joined(separator: "\n"),
                    nextIndex: cursor + 1
                )
            }
            codeLines.append(lines[cursor])
            cursor += 1
        }

        return (
            language: language.isEmpty ? nil : language,
            code: codeLines.joined(separator: "\n"),
            nextIndex: cursor
        )
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        var level = 0

        for character in trimmed {
            if character == "#" {
                level += 1
            } else {
                break
            }
        }

        guard (1...6).contains(level) else { return nil }
        let textStart = trimmed.index(trimmed.startIndex, offsetBy: level)
        guard textStart < trimmed.endIndex, trimmed[textStart] == " " else { return nil }

        let text = trimmed[textStart...].trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func table(
        from lines: [String],
        startingAt index: Int
    ) -> (headers: [String], rows: [[String]], nextIndex: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headers = tableCells(from: lines[index])
        let delimiter = tableCells(from: lines[index + 1])
        guard !headers.isEmpty, isTableDelimiter(delimiter) else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let cells = tableCells(from: lines[cursor])
            guard !cells.isEmpty else { break }
            rows.append(cells)
            cursor += 1
        }

        return (headers, rows, cursor)
    }

    private static func unorderedList(
        from lines: [String],
        startingAt index: Int
    ) -> (items: [String], nextIndex: Int)? {
        var items: [String] = []
        var cursor = index

        while cursor < lines.count {
            guard let item = unorderedListItem(from: lines[cursor]) else { break }
            items.append(item)
            cursor += 1
        }

        return items.isEmpty ? nil : (items, cursor)
    }

    private static func orderedList(
        from lines: [String],
        startingAt index: Int
    ) -> (items: [String], nextIndex: Int)? {
        var items: [String] = []
        var cursor = index

        while cursor < lines.count {
            guard let item = orderedListItem(from: lines[cursor]) else { break }
            items.append(item)
            cursor += 1
        }

        return items.isEmpty ? nil : (items, cursor)
    }

    private static func blockquote(
        from lines: [String],
        startingAt index: Int
    ) -> (text: String, nextIndex: Int)? {
        var quotedLines: [String] = []
        var cursor = index

        while cursor < lines.count {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            quotedLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            cursor += 1
        }

        return quotedLines.isEmpty ? nil : (quotedLines.joined(separator: "\n"), cursor)
    }

    private static func paragraph(
        from lines: [String],
        startingAt index: Int
    ) -> (text: String, nextIndex: Int) {
        var paragraphLines: [String] = []
        var cursor = index

        while cursor < lines.count {
            if isBlank(lines[cursor]) || startsBlock(lines, at: cursor) {
                break
            }
            paragraphLines.append(lines[cursor].trimmingCharacters(in: .whitespaces))
            cursor += 1
        }

        return (paragraphLines.joined(separator: " "), cursor)
    }

    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        codeBlock(from: lines, startingAt: index) != nil
            || heading(from: lines[index]) != nil
            || table(from: lines, startingAt: index) != nil
            || unorderedListItem(from: lines[index]) != nil
            || orderedListItem(from: lines[index]) != nil
            || lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">")
    }

    private static func unorderedListItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func orderedListItem(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let number = trimmed[..<dotIndex]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let textStart = trimmed.index(after: dotIndex)
        guard textStart < trimmed.endIndex, trimmed[textStart] == " " else { return nil }
        return String(trimmed[trimmed.index(after: textStart)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func tableCells(from line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return [] }

        if trimmed.first == "|" {
            trimmed.removeFirst()
        }
        if trimmed.last == "|" {
            trimmed.removeLast()
        }

        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableDelimiter(_ cells: [String]) -> Bool {
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let normalized = cell
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ":", with: "")
            return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
        }
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Renders a parsed markdown table with cell-wrap and globally consistent
/// column widths.
///
/// The previous implementation wrapped the table in
/// `ScrollView(.horizontal)` around a `Grid`. With no horizontal bound the
/// `Text(.init(...))` cells never wrapped, and long content pushed the
/// table off-screen. Worse, when Sonnet emitted rows with subtly different
/// cell counts (escaped pipes, ragged data) `Grid` aligned by column
/// index but each row still implied its own intrinsic width, which made
/// the table read as a stack of unrelated rows.
///
/// The current renderer is driven by a custom `Layout`. It receives the
/// bounded width proposal from its parent, computes one width vector for
/// the whole table via `MarkdownTableColumnLayout.columnWidths`, and
/// applies the same vector to every row. Cells are plain `Text` views
/// with `fixedSize(horizontal: false, vertical: true)` — once their
/// horizontal bound is honoured by `place(at:proposal:)`, they wrap
/// vertically as needed and the layout reports the table's natural
/// height back to the parent `VStack`.
private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        MarkdownTableLayout(headers: headers, rows: rows) {
            ForEach(0..<cellTexts.count, id: \.self) { index in
                let position = cellTexts[index]
                Text(.init(position.text))
                    .font(.system(size: 11, weight: position.isHeader ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, MarkdownTableColumnLayout.cellHorizontalPadding)
                    .padding(.vertical, MarkdownTableColumnLayout.cellVerticalPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(position.isHeader
                        ? Color.primary.opacity(0.08)
                        : Color.primary.opacity(0.03))
                    .border(Color.primary.opacity(0.10), width: 0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    /// Flat list of cells in row-major order, tagged with header flag.
    /// The custom `Layout` walks these in lockstep with the rendered
    /// subviews, so the array order is the contract.
    private var cellTexts: [CellPosition] {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return [] }
        var output: [CellPosition] = []
        output.reserveCapacity((rows.count + 1) * columnCount)
        for column in 0..<columnCount {
            let text = column < headers.count ? headers[column] : ""
            output.append(CellPosition(text: text, isHeader: true))
        }
        for row in rows {
            for column in 0..<columnCount {
                let text = column < row.count ? row[column] : ""
                output.append(CellPosition(text: text, isHeader: false))
            }
        }
        return output
    }
}

private struct CellPosition: Equatable {
    let text: String
    let isHeader: Bool
}

/// Custom `Layout` that places markdown-table cells in a row-major grid
/// using globally-aligned column widths. `MarkdownTableLayout` accepts
/// the same `(headers, rows)` the parent view uses so the column-width
/// vector and the cell order stay in sync.
private struct MarkdownTableLayout: Layout {
    let headers: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    private var rowCount: Int {
        // Header row + data rows.
        1 + rows.count
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? subviews.reduce(into: CGFloat.zero) { acc, sub in
            acc += sub.sizeThatFits(.unspecified).width
        }
        let columns = columnCount
        guard columns > 0, !subviews.isEmpty else {
            return CGSize(width: width, height: 0)
        }

        let widths = MarkdownTableColumnLayout.columnWidths(
            headers: headers,
            rows: rows,
            available: width
        )

        let height = totalHeight(forSubviews: subviews, widths: widths)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let columns = columnCount
        guard columns > 0, !subviews.isEmpty else { return }

        let widths = MarkdownTableColumnLayout.columnWidths(
            headers: headers,
            rows: rows,
            available: bounds.width
        )

        var rowOrigins: [CGFloat] = [bounds.minY]
        for row in 0..<rowCount {
            let height = rowHeight(at: row, subviews: subviews, widths: widths)
            rowOrigins.append((rowOrigins.last ?? bounds.minY) + height)
        }

        for row in 0..<rowCount {
            let height = rowOrigins[row + 1] - rowOrigins[row]
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { return }
                var x = bounds.minX
                for k in 0..<column {
                    x += widths[k]
                }
                let subviewProposal = ProposedViewSize(width: widths[column], height: height)
                subviews[index].place(
                    at: CGPoint(x: x, y: rowOrigins[row]),
                    anchor: .topLeading,
                    proposal: subviewProposal
                )
            }
        }
    }

    private func totalHeight(forSubviews subviews: Subviews, widths: [CGFloat]) -> CGFloat {
        (0..<rowCount).reduce(CGFloat.zero) { acc, row in
            acc + rowHeight(at: row, subviews: subviews, widths: widths)
        }
    }

    /// A row takes the height of its tallest cell. Each cell measures
    /// itself with its column width as the horizontal proposal so wrap
    /// lands inside the actual width the cell will be placed at.
    private func rowHeight(at row: Int, subviews: Subviews, widths: [CGFloat]) -> CGFloat {
        let columns = columnCount
        var maxHeight: CGFloat = 0
        for column in 0..<columns {
            let index = row * columns + column
            guard index < subviews.count else { continue }
            let measurement = subviews[index].sizeThatFits(
                ProposedViewSize(width: widths[column], height: nil)
            )
            maxHeight = max(maxHeight, measurement.height)
        }
        return maxHeight
    }
}

/// Pure-logic column-width allocator. Lives outside `MarkdownTableView`
/// so the math is testable without spinning up a hosting view.
///
/// Contract:
///
/// - Returns one width per column. Column count = `max(headers.count,
///   widest-row.count)`. Rows with fewer cells than the header are padded
///   with empty strings during weighting.
/// - The returned widths always sum to `available` (within rounding), so
///   the table fills the panel edge-to-edge.
/// - Each width is at least `minColumnWidth` so cells never collapse to
///   a hairline. If `available < columnCount * minColumnWidth` the
///   widths fall below the floor but stay positive and equal, since
///   forcing the floor would push the table off-screen.
/// - Weights are proportional to the **longest** content per column
///   (character count, capped to avoid one giant cell starving its
///   neighbours). The same vector is applied to every row, which is the
///   whole point of the helper — Maxim flagged "each row sizes its own
///   columns" as the regression we are fixing.
enum MarkdownTableColumnLayout {
    static let minColumnWidth: CGFloat = 56
    static let cellHorizontalPadding: CGFloat = 7
    static let cellVerticalPadding: CGFloat = 5

    /// Character count cap per cell. Without it a single long cell would
    /// monopolise the row and pin its neighbours at the floor, which
    /// reads as worse than a balanced 2-line wrap. Tuned against typical
    /// Sonnet outputs (~24-char travel-itinerary headers).
    private static let weightCap: Int = 40

    static func columnWidths(
        headers: [String],
        rows: [[String]],
        available: CGFloat
    ) -> [CGFloat] {
        let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0, available > 0 else { return [] }

        // Per-column "weight" expressed in capped character count.
        // Header and every row contribute; we take the max. The cap
        // prevents one extreme outlier from starving the rest of the
        // table when the column is so wide that other cells would
        // collapse below the floor.
        let weights: [Int] = (0..<columnCount).map { column in
            let headerChars = column < headers.count ? headers[column].count : 0
            let rowChars = rows.map { row in
                column < row.count ? row[column].count : 0
            }.max() ?? 0
            return max(1, min(weightCap, max(headerChars, rowChars)))
        }

        // Floor budget: columns must total at least this when laid out
        // at the minimum width. If `available` is bigger than the floor
        // budget we keep the floor (every column ≥ minColumnWidth) and
        // distribute the surplus proportionally to the weights. If
        // `available` is too small for the floor we fall back to a pure
        // proportional shrink so the table still fills its container
        // without overflowing.
        let floorBudget = CGFloat(columnCount) * minColumnWidth

        if available >= floorBudget {
            let surplus = available - floorBudget
            let totalWeight = max(1, weights.reduce(0, +))
            let widths = weights.map { weight in
                minColumnWidth + surplus * CGFloat(weight) / CGFloat(totalWeight)
            }
            return normalise(widths: widths, target: available)
        } else {
            let totalWeight = max(1, weights.reduce(0, +))
            let proportional = weights.map { weight in
                available * CGFloat(weight) / CGFloat(totalWeight)
            }
            return normalise(widths: proportional, target: available)
        }
    }

    /// Forces the widths to sum exactly to `target` (rounding-stable).
    /// We absorb the rounding into the widest column so visual deltas
    /// are imperceptible.
    private static func normalise(widths: [CGFloat], target: CGFloat) -> [CGFloat] {
        let sum = widths.reduce(0, +)
        guard sum > 0 else { return widths }
        var scaled = widths.map { $0 * target / sum }
        let drift = target - scaled.reduce(0, +)
        if let widestIndex = scaled.indices.max(by: { scaled[$0] < scaled[$1] }) {
            scaled[widestIndex] += drift
        }
        return scaled
    }
}

/// Fenced code block renderer. Wraps the canonical horizontal-scroll
/// monospaced text view with a top-right copy affordance so Sonnet's
/// streamed snippets become one-click-copyable.
///
/// The button is a plain SF Symbol (`doc.on.doc`) that swaps to a green
/// checkmark for ~1s after a successful copy, then returns to the copy
/// glyph. Hover state is implicit via `.buttonStyle(.plain)` — AppKit
/// renders a subtle highlight under the cursor.
///
/// Copy writes the *unmodified* code (preserving leading whitespace) to
/// `NSPasteboard.general` via `CodeBlockCopyAction`. No
/// `ClipboardSuppression` here because this is an intentional user
/// action — same logic as the "Copy entire response" button: the user
/// wants the copy in their clipboard history so they can paste it
/// elsewhere.
struct CodeBlockView: View {
    let code: String
    /// Factory for the pasteboard the copy action targets. Production
    /// resolves to `NSPasteboard.general`; tests inject an isolated
    /// pasteboard so the suite never pollutes the developer's clipboard.
    var pasteboard: () -> NSPasteboard = { NSPasteboard.general }

    @State private var didCopy: Bool = false
    /// Generation counter so a rapid second click resets the
    /// checkmark-revert timer instead of letting the stale Task flip the
    /// icon back early.
    @State private var copyGeneration: UInt64 = 0

    private static let checkmarkHoldSeconds: Double = 1.0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                // Right padding leaves room for the floating copy
                // affordance so the longest line never collides with
                // the icon. Width tracks the icon (16pt) + 8pt panel
                // inset + 4pt breathing room.
                .padding(.trailing, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            copyButton
                .padding(.top, 4)
                .padding(.trailing, 4)
        }
    }

    private var copyButton: some View {
        Button(action: performCopy) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(didCopy
                    ? Color.green.opacity(0.85)
                    : Color.primary.opacity(0.55))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(didCopy ? "Copied" : "Copy code")
        .accessibilityHint("Copies the code block to the clipboard")
    }

    private func performCopy() {
        CodeBlockCopyAction.copy(code, into: pasteboard())
        copyGeneration &+= 1
        let token = copyGeneration
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.checkmarkHoldSeconds * 1_000_000_000)
            )
            // A newer copy click would have bumped the generation —
            // don't flip the icon back if we're stale.
            guard copyGeneration == token else { return }
            didCopy = false
        }
    }
}

/// Pure-logic copy action for fenced code blocks. Lives outside
/// `CodeBlockView` so the contract is testable without spinning up a
/// hosting view. Splits the SwiftUI side from the AppKit pasteboard
/// side, which keeps the tests fast and the production path obvious.
///
/// The action clears the pasteboard before writing so a stale type
/// from a prior copy (RTF / image / file URL) cannot bleed into the
/// subsequent paste. `setString` writes only the `.string` type — the
/// caller's downstream paste decides how to interpret it.
enum CodeBlockCopyAction {
    static func copy(_ code: String, into pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
    }
}

struct RendererTitle: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SourceAnnotationView: View {
    let sourceIds: [String]?
    let sources: [Source]

    var body: some View {
        if let sourceIds, !sourceIds.isEmpty {
            Text("Sources: \(sourceLabels(for: sourceIds).joined(separator: ", "))")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
    }

    private func sourceLabels(for ids: [String]) -> [String] {
        ids.map { id in
            if let source = sources.first(where: { $0.id == id }) {
                if let provider = source.provider, !provider.isEmpty {
                    return "\(source.title) · \(provider)"
                }
                return source.title
            }
            return id
        }
    }
}

struct AgentActionButtonRow: View {
    let actions: [UIAction]

    var body: some View {
        if !actions.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    AgentActionButton(action: action)
                }
            }
        }
    }
}

struct AgentActionButton: View {
    let action: UIAction

    var body: some View {
        Group {
            if action.variant == .primary {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }

    private var button: some View {
        Button(action: perform) {
            Text(action.label)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func perform() {
        switch action.type {
        case .open, .connect:
            if let url = action.url {
                NSWorkspace.shared.open(url)
            }
        case .copy:
            if let text = action.payloadText {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case .retry:
            break
        }
    }
}

extension UIAction {
    var payloadText: String? {
        guard let payload else { return nil }
        if case .object(let object) = payload, case .string(let text)? = object["text"] {
            return text
        }
        if case .string(let text) = payload {
            return text
        }
        return nil
    }
}

extension AnyCodable {
    var displayString: String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(value)
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.displayString).joined(separator: ", ")
        case .object(let values):
            return values
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.displayString)" }
                .joined(separator: ", ")
        }
    }
}

extension URL {
    var agentDisplayString: String {
        if let host, !host.isEmpty {
            return host
        }
        return absoluteString
    }
}
