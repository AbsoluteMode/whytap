import Foundation

/// Where a Smart take goes, as far as formatting is concerned: the name the
/// editor model is told, and whether Whytap converts the result on paste.
///
/// Switched off for now by `isMarkdownEnabled`: Smart writes plain text
/// everywhere. The description below is what the switch turns back on.
///
/// There is no per-app list of Markdown rules. The model gets the destination's
/// name in one line and decides itself whether that app shows Markdown and
/// which. The only apps named in code are the ones the paste mechanics need:
/// Slack and Telegram, where Whytap turns Markdown into rich clipboard text.
/// Never infer a destination from transcript text, window titles or screen prose.
// WHY: .project-docs/decisions/2026-11-24-smart-markdown-off.md
struct SmartFormattingProfile: Sendable, Equatable {
    /// Name given to the model. `nil`: no destination line, plain text only.
    let destination: String?
    /// Whytap converts the editor's Markdown to RTF + HTML for this paste.
    let usesRichPaste: Bool

    /// The one switch. Off since 2026-11-24: the maintainer removed Markdown
    /// from Smart for now, after the live model put backticks into apps that
    /// show no Markdown (a terminal among them). While it is off every take
    /// is `plain`: no destination line, no rich paste, no Accessibility read.
    /// Everything below stays in place so that it can be turned back on here.
    // WHY: .project-docs/decisions/2026-11-24-smart-markdown-off.md
    static let isMarkdownEnabled = false

    static let plain = Self(destination: nil, usesRichPaste: false)
    static let slack = Self(destination: "Slack", usesRichPaste: true)
    static let telegram = Self(destination: "Telegram", usesRichPaste: true)

    /// An app known only by its display name. An empty name is `plain`.
    static func app(_ name: String?) -> Self {
        guard let name = cleanName(name) else { return .plain }
        return Self(destination: name, usesRichPaste: false)
    }

    /// The editor may emit Markdown: protect code spans and URLs from the
    /// local filler pass.
    var allowsMarkdown: Bool { destination != nil }

    /// The one line that replaces the plain-text rule of the system prompt.
    /// Its wording was measured on the live model; see the decision.
    var instructions: String? {
        guard let destination else { return nil }
        if usesRichPaste {
            // Describes Whytap's own converter (SmartRichTextPaste), not the app.
            return "Это сообщение предназначается для приложения «\(destination)». Можешь использовать Markdown для структурирования текста: Whytap сам превратит его в форматированный текст при вставке. Он понимает **жирный**, *курсив*, ~~зачёркнутый~~, `код`, блоки кода и ссылки [текст](URL); заголовки, таблицы и цитаты останутся символами."
        }
        return "Это сообщение предназначается для приложения «\(destination)». Если ты знаешь, что это приложение показывает Markdown, используй особенности его Markdown для структурирования текста: имена файлов, параметров и команд оформляй как `код`, сохраняя символы внутри точно, остальное оформление применяй по смыслу, а не ради украшения. Если приложение Markdown не показывает или ты его не знаешь, не используй никакой разметки, кроме простых списков."
    }

    static func resolve(
        bundleID: String?, appName: String?, documentURL: URL?, focusedRole: String?,
        markdownEnabled: Bool = SmartFormattingProfile.isMarkdownEnabled
    ) -> Self {
        guard markdownEnabled else { return .plain }
        // Single-line fields include search, issue titles, addresses and names:
        // no markup there, whatever the app.
        // A role that could not be read (slow Accessibility) does not hide the
        // app's name: the guard works only when the field is known.
        if focusedRole == "AXTextField" || focusedRole == "AXComboBox" || focusedRole == "AXSecureTextField" { return .plain }
        // No process identity: the take goes into one of Whytap's own editors
        // (AutoPasteEngine.currentDropTarget) or the target is unknown.
        guard let id = bundleID?.lowercased() else { return .plain }
        if let rich = richPasteSite(documentURL) { return rich }
        if id == "com.tinyspeck.slackmacgap" { return .slack }
        if ["ru.keepcoder.telegram", "org.telegram.desktop", "org.telegram.telegram"].contains(id) { return .telegram }
        return .app(appName)
    }

    /// Slack and Telegram in a browser paste rich text like their apps. The
    /// exact host of the containing document decides, never a lookalike.
    private static func richPasteSite(_ documentURL: URL?) -> Self? {
        guard let documentURL, documentURL.scheme?.lowercased() == "https", documentURL.user == nil,
              let host = documentURL.host?.lowercased() else { return nil }
        if host == "app.slack.com" { return .slack }
        if host == "web.telegram.org" { return .telegram }
        return nil
    }

    /// The name enters Whytap's instructions, so it is one short line without
    /// control characters or the quotes that delimit it.
    private static func cleanName(_ name: String?) -> String? {
        guard let name else { return nil }
        let scalars = name.unicodeScalars.map { scalar -> Character in
            // Cc and line separators only: format characters (ZWJ, ZWNJ) are
            // part of real names in some scripts.
            scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
                || scalar == "«" || scalar == "»" ? " " : Character(scalar)
        }
        let words = String(scalars).split(whereSeparator: \.isWhitespace)
        let cleaned = String(words.joined(separator: " ").prefix(60)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }
}
