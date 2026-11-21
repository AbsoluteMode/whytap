import SwiftUI

struct MarkdownCalloutView: View {
    let kind: MarkdownCalloutKind
    let text: String

    @Environment(\.locale) private var locale

    private var title: String {
        let russian = locale.language.languageCode?.identifier == "ru"
        switch kind {
        case .note: return russian ? "Примечание" : "Note"
        case .warning: return russian ? "Предупреждение" : "Warning"
        }
    }

    var body: some View {
        let accent: Color = kind == .warning ? .orange : .blue
        AgentBlockContainer(accent: accent.opacity(0.45)) {
            Label(title, systemImage: kind == .warning ? "exclamationmark.triangle" : "info.circle")
                .fontWeight(.semibold)
                .labelStyle(.titleAndIcon)
            if !text.isEmpty {
                Text(MarkdownAttributedRun.parseInline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}
