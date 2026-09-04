import SwiftUI

// MARK: - Copy provider (ROO-261)

/// Localized copy for the super-assistant ("Make it yours") step.
///
/// The right-pane helper gallery localizes its card titles/descriptions
/// through `toolTile(for:)` — a screen-local layer on top of
/// `HoverToolRegistry`. The registry itself stays the single ENGLISH
/// source for the live hover panel and the Toolbox tab and is never
/// localized here. EN maps nothing on purpose (the registry IS the
/// English copy); any tool a language does not map falls back to the
/// registry strings. Brand/product nouns (Drop, Whytap, Fast, Smart,
/// Dynamic Island) stay English in both locales.
protocol OnboardingSuperAssistantCopy {
    /// Upright serif lead-in of the headline ("Make it ").
    var headlineLead: String { get }
    /// Italic serif tail of the headline ("yours.").
    var headlineTail: String { get }
    var subtitle: String { get }
    var back: String { get }
    var ccontinue: String { get }
    /// Localized copy for one helper tile in the gallery, or `nil` to
    /// fall back to the `HoverToolRegistry` (English) strings.
    func toolTile(for tool: HoverTool) -> OnboardingSuperAssistantToolTile?
}

/// One localized helper tile (title + description) for the gallery.
struct OnboardingSuperAssistantToolTile: Equatable {
    let title: String
    let description: String
}

struct OnboardingSuperAssistantCopyEN: OnboardingSuperAssistantCopy {
    let headlineLead = "Make it "
    let headlineTail = "yours."
    let subtitle = "A panel of helpers sits in the hover panel by the island — Drop modes, history, vocabulary, clipboard, and more. Switch on and rearrange the ones you want anytime in Settings."
    let back = "Back"
    let ccontinue = "Continue"

    func toolTile(for tool: HoverTool) -> OnboardingSuperAssistantToolTile? { nil }
}

struct OnboardingSuperAssistantCopyRU: OnboardingSuperAssistantCopy {
    let headlineLead = "Настройте "
    let headlineTail = "под себя."
    let subtitle = "Рядом с островом, в панели наведения, живёт набор помощников — режимы Drop, история, словарь, буфер обмена и другое. Включайте и переставляйте нужные в любой момент в настройках."
    let back = "Назад"
    let ccontinue = "Продолжить"

    func toolTile(for tool: HoverTool) -> OnboardingSuperAssistantToolTile? {
        switch tool {
        case .dropMode:
            return .init(title: "Режим Drop",
                         description: "Переключение между Fast- и Smart-транскрипцией")
        case .clipboard:
            return .init(title: "История",
                         description: "Единая история записей")
        case .vocab:
            return .init(title: "Словарь",
                         description: "Свой словарь и термины")
        case .caseVault:
            return .init(title: "Сниппеты",
                         description: "Хранение и вставка готовых фрагментов")
        case .filler:
            return .init(title: "Фразы",
                         description: "Быстрая вставка частых фраз")
        case .inputLang:
            return .init(title: "Язык ввода",
                         description: "Язык распознавания речи")
        case .outputLang:
            return .init(title: "Язык вывода",
                         description: "Язык перевода в Smart-режиме")
        default:
            // Tools that ever get showcased without a RU mapping fail
            // safe to the registry's English strings.
            return nil
        }
    }
}

private func onboardingSuperAssistantCopy(
    for language: OnboardingUILanguage
) -> OnboardingSuperAssistantCopy {
    switch language {
    case .en: return OnboardingSuperAssistantCopyEN()
    case .ru: return OnboardingSuperAssistantCopyRU()
    }
}

/// Super-assistant step — a passive showcase of what Whytap can do. The
/// hover-panel helpers are shown as a gallery ("here's what's available"),
/// not a picker: no selection, no checkboxes, no writing into the panel.
/// The panel keeps its defaults (`HoverLayoutStore.defaultSlots`); the user
/// arranges helpers later in Settings.
struct OnboardingSuperAssistantScreen: View {
    let onBack: () -> Void
    let onContinue: () -> Void

    @EnvironmentObject private var locale: OnboardingLocale
    private var copy: OnboardingSuperAssistantCopy {
        onboardingSuperAssistantCopy(for: locale.language)
    }

    /// Helper tools shown in the gallery, in display order.
    static let showcase: [HoverTool] = [
        .dropMode, .clipboard, .vocab, .caseVault, .filler, .inputLang, .outputLang
    ]

    /// Title/description a gallery card renders: the language's own tile
    /// copy when provided, otherwise the live `HoverToolRegistry` strings.
    static func tileStrings(
        for tool: HoverTool,
        copy: OnboardingSuperAssistantCopy
    ) -> (title: String, description: String) {
        let info = HoverToolRegistry.info(for: tool)
        let tile = copy.toolTile(for: tool)
        return (tile?.title ?? info.title, tile?.description ?? info.description)
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
                .background(OnboardingTheme.bg)
                .overlay(
                    Rectangle().fill(OnboardingTheme.border).frame(width: 0.5),
                    alignment: .trailing
                )
            rightPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                headline
                Text(copy.subtitle)
                    .font(OnboardingTheme.sans(14))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(EdgeInsets(top: 40, leading: 36, bottom: 22, trailing: 28))
    }

    private var headline: some View {
        (
            Text(copy.headlineLead).font(OnboardingTheme.serif(42, language: locale.language))
            + Text(copy.headlineTail).font(OnboardingTheme.serifItalic(42, language: locale.language))
        )
        .foregroundColor(OnboardingTheme.ink)
        .kerning(-0.6)
        .lineSpacing(-6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text(copy.back)
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Text(copy.ccontinue)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.bg)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(Capsule(style: .continuous).fill(OnboardingTheme.ink))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Right pane (helper gallery — showcase only)

    private var rightPane: some View {
        ZStack {
            OnboardingTheme.surface2
            ScrollView(showsIndicators: false) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    ForEach(Self.showcase, id: \.self) { tool in
                        helperCard(tool)
                    }
                }
                .padding(28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func helperCard(_ tool: HoverTool) -> some View {
        let info = HoverToolRegistry.info(for: tool)
        let strings = Self.tileStrings(for: tool, copy: copy)
        return VStack(alignment: .leading, spacing: 8) {
            Image(systemName: info.sfSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(OnboardingTheme.surface2)
                )
            Text(strings.title)
                .font(OnboardingTheme.sans(13, weight: .semibold))
                .foregroundColor(OnboardingTheme.ink)
            Text(strings.description)
                .font(OnboardingTheme.sans(11))
                .foregroundColor(OnboardingTheme.muted)
                .lineSpacing(1.5)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OnboardingTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 0.5)
        )
    }
}
