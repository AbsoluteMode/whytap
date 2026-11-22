import Foundation

/// Markdown block structure of a text, as far as citation cleanup needs it:
/// which lines are code (fenced with ``` or ~~~, or indented) and where each
/// leaf block starts, so inline delimiters never pair across blocks.
///
/// Block quotes and list items are followed as CommonMark 0.31.2 does,
/// simplified: a fence opens or closes only at up to three columns past its
/// container's content margin; four or more columns start indented code
/// (never inside a paragraph); a blank line ends a quote; a line indented
/// less than an item's content ends the item, and so does a blank line right
/// after an empty item's marker; a closed container ends the fence or code
/// inside it; a paragraph's lazy continuation keeps its containers; ATX
/// headings, setext underlines and thematic breaks end a paragraph. HTML
/// blocks are not recognised. Tabs advance to the next multiple of four.
/// Lines end at LF, CRLF or CR.
/// WHY: .project-docs/decisions/2026-11-22-openai-agent-probe-responses.md
enum MarkdownCodeLines {
    struct Structure {
        /// Code lines, line terminators excluded.
        var code: [NSRange] = []
        /// UTF-16 locations where a line starts a new leaf block (anything
        /// but a paragraph's continuation line).
        var blockStarts: [Int] = []
    }

    private enum Container { case quote, list(content: Int, empty: Bool) }
    private enum Leaf: Equatable { case none, paragraph, indented, other, fence(char: unichar, length: Int) }

    private static let space: unichar = 0x20, tab: unichar = 0x09, quoteMark: unichar = 0x3E
    private static let backtick: unichar = 0x60, tilde: unichar = 0x7E, hash: unichar = 0x23
    private static let dash: unichar = 0x2D, plus: unichar = 0x2B, star: unichar = 0x2A
    private static let underscore: unichar = 0x5F, equals: unichar = 0x3D

    static func structure(of string: NSString) -> Structure {
        var result = Structure()
        var containers: [Container] = []
        var leaf = Leaf.none
        for line in lines(of: string) {
            let end = NSMaxRange(line)
            func char(_ index: Int) -> unichar { index < end ? string.character(at: index) : 0 }
            /// Skips spaces and tabs from `index` at column `column`.
            func skip(_ index: Int, _ column: Int) -> (index: Int, column: Int) {
                var index = index, column = column
                while index < end {
                    let current = char(index)
                    if current == space { column += 1 } else if current == tab { column += 4 - column % 4 } else { break }
                    index += 1
                }
                return (index, column)
            }
            func restIsBlank(_ index: Int) -> Bool { skip(index, 0).index == end }
            // The last character of the line that cannot be part of a thematic
            // break of each mark, found once so nested containers stay linear.
            var lastForeign: [unichar: Int] = [:]
            for cursor in line.location..<end {
                let current = string.character(at: cursor)
                guard current != space, current != tab else { continue }
                for mark in [dash, star, underscore] where current != mark { lastForeign[mark] = cursor }
            }
            /// The position and margin after a `>` and its optional space.
            func afterQuote(_ index: Int, _ column: Int) -> (index: Int, column: Int, margin: Int) {
                let next = index + 1, nextColumn = column + 1
                if char(next) == space { return (next + 1, nextColumn + 1, nextColumn + 1) }
                if char(next) == tab { return (next, nextColumn, nextColumn + 1) }
                return (next, nextColumn, nextColumn)
            }
            func run(_ index: Int, of mark: unichar) -> Int {
                var cursor = index
                while cursor < end, char(cursor) == mark { cursor += 1 }
                return cursor - index
            }
            func fenceRun(_ index: Int) -> (char: unichar, length: Int)? {
                let first = char(index)
                guard first == backtick || first == tilde else { return nil }
                let length = run(index, of: first)
                return length >= 3 ? (first, length) : nil
            }
            func opensFence(_ index: Int) -> (char: unichar, length: Int)? {
                guard let fence = fenceRun(index) else { return nil }
                // A backtick fence's info string has no backtick.
                var cursor = index + fence.length
                while fence.char == backtick, cursor < end {
                    if char(cursor) == backtick { return nil }
                    cursor += 1
                }
                return fence
            }
            func isThematicBreak(_ index: Int) -> Bool {
                let mark = char(index)
                guard mark == dash || mark == star || mark == underscore,
                      lastForeign[mark].map({ $0 < index }) ?? true else { return false }
                var count = 0, cursor = index
                while cursor < end {
                    let current = char(cursor)
                    if current == mark { count += 1 } else if current != space, current != tab { return false }
                    cursor += 1
                }
                return count >= 3
            }
            func isHeading(_ index: Int) -> Bool {
                let level = run(index, of: hash)
                guard (1...6).contains(level) else { return false }
                let after = char(index + level)
                return index + level == end || after == space || after == tab
            }
            func isSetextUnderline(_ index: Int) -> Bool {
                let mark = char(index)
                guard mark == equals || mark == dash else { return false }
                return restIsBlank(index + run(index, of: mark))
            }
            /// A list marker at `index`: where it ends, its content margin and
            /// whether the item starts empty.
            func listMarker(_ index: Int, _ column: Int, interrupting: Bool) -> (index: Int, column: Int, content: Int, empty: Bool)? {
                var cursor = index, number = 0, ordered = false
                let first = char(cursor)
                if first == dash || first == plus || first == star {
                    cursor += 1
                } else {
                    while cursor < end, cursor - index < 9, (0x30...0x39).contains(char(cursor)) {
                        number = number * 10 + Int(char(cursor) - 0x30)
                        cursor += 1
                    }
                    guard cursor > index, char(cursor) == 0x2E || char(cursor) == 0x29 else { return nil }
                    cursor += 1
                    ordered = true
                }
                let markerColumn = column + (cursor - index)
                let after = skip(cursor, markerColumn)
                if after.index == end { return interrupting ? nil : (cursor, markerColumn, markerColumn + 1, true) }
                guard after.column > markerColumn, !(interrupting && ordered && number != 1) else { return nil }
                let content = after.column - markerColumn >= 5 ? markerColumn + 1 : after.column
                return (cursor, markerColumn, content, false)
            }

            // Continue the open containers.
            let leafBefore = leaf, depthBefore = containers.count
            var index = line.location, column = 0, margin = 0, matched = 0
            for container in containers {
                let next = skip(index, column)
                if case let .list(content, empty) = container {
                    let blank = next.index == end
                    guard blank ? !empty : next.column >= content else { break }
                    margin = content
                } else {
                    guard next.index < end, char(next.index) == quoteMark, next.column - margin <= 3 else { break }
                    (index, column, margin) = afterQuote(next.index, next.column)
                }
                matched += 1
            }
            var start = skip(index, column)
            var blank = start.index == end
            let allMatched = matched == containers.count
            var opened = false
            defer {
                if !blank {
                    for position in containers.indices {
                        if case let .list(content, true) = containers[position] { containers[position] = .list(content: content, empty: false) }
                    }
                }
                let continuation = leafBefore == .paragraph && leaf == .paragraph && !opened && containers.count == depthBefore
                if !continuation { result.blockStarts.append(line.location) }
            }

            if allMatched, case let .fence(char, length) = leaf {
                result.code.append(line)
                if start.column - margin <= 3, let fence = fenceRun(start.index), fence.char == char, fence.length >= length,
                   restIsBlank(start.index + fence.length) {
                    leaf = .none
                }
                continue
            }
            if allMatched, leaf == .indented, blank || start.column - margin >= 4 {
                if !blank { result.code.append(line) }
                continue
            }
            if !allMatched {
                let relative = start.column - margin
                let startsBlock = relative <= 3 && (char(start.index) == quoteMark || opensFence(start.index) != nil
                    || isThematicBreak(start.index) || isHeading(start.index)
                    || listMarker(start.index, start.column, interrupting: false) != nil)
                if leaf == .paragraph, !blank, !startsBlock { continue } // Lazy continuation.
                containers.removeLast(containers.count - matched)
                leaf = .none
            }

            // Open new containers.
            while !blank, start.column - margin <= 3, !isThematicBreak(start.index) {
                if char(start.index) == quoteMark {
                    containers.append(.quote)
                    (index, column, margin) = afterQuote(start.index, start.column)
                } else if let marker = listMarker(start.index, start.column, interrupting: leaf == .paragraph) {
                    containers.append(.list(content: marker.content, empty: marker.empty))
                    (index, column, margin) = (marker.index, marker.column, marker.content)
                } else {
                    break
                }
                opened = true
                leaf = .none
                start = skip(index, column)
                blank = start.index == end
            }

            // The leaf block.
            let relative = start.column - margin
            if blank {
                if leaf == .paragraph || leaf == .other { leaf = .none }
            } else if relative >= 4, leaf != .paragraph {
                leaf = .indented
                result.code.append(line)
            } else if relative <= 3, let fence = opensFence(start.index) {
                leaf = .fence(char: fence.char, length: fence.length)
                result.code.append(line)
            } else if relative <= 3, isHeading(start.index) || isThematicBreak(start.index)
                        || (leaf == .paragraph && allMatched && !opened && isSetextUnderline(start.index)) {
                leaf = .other
            } else {
                leaf = .paragraph
            }
        }
        return result
    }

    /// Line content ranges; a line ends at LF, CRLF or CR.
    private static func lines(of string: NSString) -> [NSRange] {
        var lines: [NSRange] = []
        var start = 0
        let length = string.length
        while true {
            var end = start
            while end < length, string.character(at: end) != 0x0A, string.character(at: end) != 0x0D { end += 1 }
            lines.append(NSRange(location: start, length: end - start))
            guard end < length else { return lines }
            start = string.character(at: end) == 0x0D && end + 1 < length && string.character(at: end + 1) == 0x0A ? end + 2 : end + 1
        }
    }
}
