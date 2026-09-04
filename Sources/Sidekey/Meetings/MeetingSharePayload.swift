import Foundation

struct MeetingSharePayload: Equatable {
    let markdown: String
    let attachmentFileName: String

    init?(markdown: String) {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        self.markdown = trimmed
        self.attachmentFileName = Self.attachmentFileName(for: trimmed)
    }

    private static func attachmentFileName(for markdown: String) -> String {
        let title = firstHeading(in: markdown) ?? "Meeting notes"
        let sanitized = sanitizeFileStem(title)
        return "\(sanitized.isEmpty ? "Meeting notes" : sanitized).md"
    }

    private static func firstHeading(in markdown: String) -> String? {
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#") else { continue }

            let title = line.drop(while: { $0 == "#" })
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return nil
    }

    private static func sanitizeFileStem(_ value: String) -> String {
        let separators = CharacterSet(charactersIn: "-_")
        let mapped = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) || separators.contains(scalar) {
                return String(scalar)
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return " "
            }
            return " "
        }.joined()

        let collapsed = mapped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MeetingShareAttachmentWriter {
    static func writeMarkdownAttachment(
        for payload: MeetingSharePayload,
        in directory: URL = defaultDirectory()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(payload.attachmentFileName)
        try payload.markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func defaultDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-meeting-shares", isDirectory: true)
    }
}
