import Foundation

enum AppCategory: String {
    case markdown
    case slackFlavored
    case plain
}

enum InsertActionType: String {
    case paste
    case replace
}

struct InsertVariant: Equatable {
    let id: String
    let label: String
    let text: String
    let actionType: InsertActionType
}

struct ClientInsertFormatter {
    func detect(from bundleID: String?) -> AppCategory {
        guard let bundleID else {
            return .plain
        }

        let normalized = bundleID.lowercased()
        if normalized.contains("slack") || normalized.contains("tinyspeck") {
            return .slackFlavored
        }

        if normalized.contains("notion")
            || normalized.contains("linear")
            || normalized.contains("cursor")
            || normalized.contains("vscode")
            || normalized.contains("visualstudio")
            || normalized.contains("microsoft.vscode")
            || normalized.contains("todesktop.230313mzl4w4u92") {
            return .markdown
        }

        return .plain
    }

    func variants(
        for block: UIBlock,
        targetApp: AppCategory,
        isEditable: Bool,
        hasSelection: Bool
    ) -> [InsertVariant] {
        let variants: [InsertVariant]
        switch block {
        case .textAnswer(let block):
            variants = textAnswerVariants(for: block)
        case .entityCard(let block):
            variants = entityCardVariants(for: block, targetApp: targetApp)
        case .entityList(let block):
            variants = entityListVariants(for: block, targetApp: targetApp)
        case .metricCard(let block):
            variants = metricCardVariants(for: block)
        case .searchResults(let block):
            variants = searchResultsVariants(for: block, targetApp: targetApp)
        case .usefulLinks(let block):
            variants = usefulLinksVariants(for: block, targetApp: targetApp)
        case .stateEmpty, .stateError, .statePermission, .usefulActions:
            // useful.actions insert variants land in Task 2 (per-item
            // insertText). Task 1 keeps it inert alongside the state.* blocks.
            variants = []
        }

        return variants.addingReplaceSelectionVariant(
            isEditable: isEditable,
            hasSelection: hasSelection
        )
    }

    private func textAnswerVariants(for block: TextAnswerBlock) -> [InsertVariant] {
        var builder = InsertVariantBuilder()
        builder.add(id: "full_text", label: "Full text", text: block.body)
        builder.add(id: "title_only", label: "Title only", text: block.title)
        return builder.variants
    }

    private func entityCardVariants(
        for block: EntityCardBlock,
        targetApp: AppCategory
    ) -> [InsertVariant] {
        let title = block.name
        let url = block.url ?? firstActionURL(in: block.actions)
        var builder = InsertVariantBuilder()

        if let url {
            addPrimaryLinkVariant(
                to: &builder,
                title: title,
                url: url,
                targetApp: targetApp
            )
            builder.add(id: "url_only", label: "URL only", text: url.absoluteString)
            builder.add(id: "title_only", label: "Title only", text: title)
            builder.add(
                id: "markdown_link",
                label: "Markdown link",
                text: markdownLink(title: title, url: url)
            )
            builder.add(
                id: "full_plain_text",
                label: "Full plain text",
                text: joinedLines([title, block.description, url.absoluteString])
            )
        } else {
            builder.add(
                id: "full_plain_text",
                label: "Full plain text",
                text: joinedLines([title, block.description])
            )
            builder.add(id: "title_only", label: "Title only", text: title)
        }

        return builder.variants
    }

    private func entityListVariants(
        for block: EntityListBlock,
        targetApp: AppCategory
    ) -> [InsertVariant] {
        guard !block.items.isEmpty else {
            return []
        }

        var builder = InsertVariantBuilder()
        builder.add(
            id: "formatted_list",
            label: "Formatted list",
            text: formattedList(
                block.items.map {
                    LinkableItem(title: $0.title, subtitle: $0.subtitle, url: $0.url)
                },
                targetApp: targetApp
            )
        )
        builder.add(
            id: "titles_only",
            label: "Titles only",
            text: block.items.map(\.title).joined(separator: "\n")
        )
        builder.add(
            id: "urls_only",
            label: "URLs only",
            text: block.items.compactMap { $0.url?.absoluteString }.joined(separator: "\n")
        )
        builder.add(
            id: "markdown_list",
            label: "Markdown list",
            text: markdownList(
                block.items.map {
                    LinkableItem(title: $0.title, subtitle: $0.subtitle, url: $0.url)
                }
            )
        )
        builder.add(
            id: "full_plain_text",
            label: "Full plain text",
            text: plainList(
                block.items.map {
                    LinkableItem(title: $0.title, subtitle: $0.subtitle, url: $0.url)
                }
            )
        )
        return builder.variants
    }

    private func metricCardVariants(for block: MetricCardBlock) -> [InsertVariant] {
        let value = joinedInline([block.value, block.unit])
        let summaryPrefix = block.title ?? block.label
        var builder = InsertVariantBuilder()
        builder.add(
            id: "metric_summary",
            label: "Metric summary",
            text: joinedInline(["\(summaryPrefix):", block.label == summaryPrefix ? nil : block.label, value])
        )
        builder.add(id: "value_only", label: "Value only", text: value)
        builder.add(
            id: "full_plain_text",
            label: "Full plain text",
            text: joinedLines([
                block.title,
                joinedInline([block.label, value]),
                block.trend.map { "Trend: \($0)" }
            ])
        )
        return builder.variants
    }

    private func searchResultsVariants(
        for block: SearchResultsBlock,
        targetApp: AppCategory
    ) -> [InsertVariant] {
        guard !block.results.isEmpty else {
            return []
        }

        let items = block.results.map {
            LinkableItem(title: $0.title, subtitle: $0.snippet, url: $0.url)
        }
        var builder = InsertVariantBuilder()
        builder.add(
            id: "formatted_results",
            label: "Formatted results",
            text: formattedList(items, targetApp: targetApp)
        )
        builder.add(
            id: "titles_only",
            label: "Titles only",
            text: block.results.map(\.title).joined(separator: "\n")
        )
        builder.add(
            id: "urls_only",
            label: "URLs only",
            text: block.results.compactMap { $0.url?.absoluteString }.joined(separator: "\n")
        )
        builder.add(id: "markdown_list", label: "Markdown list", text: markdownList(items))
        builder.add(id: "full_plain_text", label: "Full plain text", text: plainList(items))
        return builder.variants
    }

    private func usefulLinksVariants(
        for block: UsefulLinksBlock,
        targetApp: AppCategory
    ) -> [InsertVariant] {
        guard !block.links.isEmpty else {
            return []
        }

        // Useful Links are link-first by spec — each entry carries a
        // description and a URL. Reuse the LinkableItem pipeline so the
        // markdown / slack / plain variants stay consistent with how
        // entity lists and search results render.
        let items = block.links.map {
            LinkableItem(title: $0.description, subtitle: nil, url: $0.url)
        }
        var builder = InsertVariantBuilder()
        builder.add(
            id: "formatted_links",
            label: "Formatted links",
            text: formattedList(items, targetApp: targetApp)
        )
        builder.add(
            id: "urls_only",
            label: "URLs only",
            text: block.links.map { $0.url.absoluteString }.joined(separator: "\n")
        )
        builder.add(
            id: "descriptions_only",
            label: "Descriptions only",
            text: block.links.map(\.description).joined(separator: "\n")
        )
        builder.add(id: "markdown_list", label: "Markdown list", text: markdownList(items))
        builder.add(id: "full_plain_text", label: "Full plain text", text: plainList(items))
        return builder.variants
    }

    private func addPrimaryLinkVariant(
        to builder: inout InsertVariantBuilder,
        title: String,
        url: URL,
        targetApp: AppCategory
    ) {
        switch targetApp {
        case .markdown:
            builder.add(id: "markdown_link", label: "Markdown link", text: markdownLink(title: title, url: url))
        case .slackFlavored:
            builder.add(id: "slack_link", label: "Slack link", text: slackLink(title: title, url: url))
        case .plain:
            builder.add(id: "title_and_url", label: "Title and URL", text: plainLink(title: title, url: url))
        }
    }

    private func formattedList(_ items: [LinkableItem], targetApp: AppCategory) -> String {
        switch targetApp {
        case .markdown:
            return markdownList(items)
        case .slackFlavored:
            return items.map { "- \(slackText(for: $0))" }.joined(separator: "\n")
        case .plain:
            return plainList(items)
        }
    }

    private func markdownList(_ items: [LinkableItem]) -> String {
        items.map { "- \(markdownText(for: $0))" }.joined(separator: "\n")
    }

    private func plainList(_ items: [LinkableItem]) -> String {
        items.map { "- \(plainText(for: $0))" }.joined(separator: "\n")
    }

    private func markdownText(for item: LinkableItem) -> String {
        let title = item.title
        let lead = item.url.map { markdownLink(title: title, url: $0) } ?? title
        return joinedInline([lead, item.subtitle])
    }

    private func slackText(for item: LinkableItem) -> String {
        let title = item.title
        let lead = item.url.map { slackLink(title: title, url: $0) } ?? title
        return joinedInline([lead, item.subtitle])
    }

    private func plainText(for item: LinkableItem) -> String {
        joinedInline([item.title, item.subtitle, item.url?.absoluteString])
    }

    private func markdownLink(title: String, url: URL) -> String {
        "[\(title)](\(url.absoluteString))"
    }

    private func slackLink(title: String, url: URL) -> String {
        "<\(url.absoluteString)|\(title)>"
    }

    private func plainLink(title: String, url: URL) -> String {
        "\(title) - \(url.absoluteString)"
    }

    private func firstActionURL(in actions: [UIAction]?) -> URL? {
        actions?.first { $0.url != nil }?.url
    }
}

private struct LinkableItem {
    let title: String
    let subtitle: String?
    let url: URL?
}

private struct InsertVariantBuilder {
    private(set) var variants: [InsertVariant] = []
    private var seenIDs: Set<String> = []

    mutating func add(
        id: String,
        label: String,
        text: String?,
        actionType: InsertActionType = .paste
    ) {
        guard
            let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty,
            !seenIDs.contains(id)
        else {
            return
        }

        variants.append(InsertVariant(
            id: id,
            label: label,
            text: text,
            actionType: actionType
        ))
        seenIDs.insert(id)
    }
}

private extension Array where Element == InsertVariant {
    func addingReplaceSelectionVariant(
        isEditable: Bool,
        hasSelection: Bool
    ) -> [InsertVariant] {
        guard isEditable, hasSelection, let primary = first else {
            return self
        }

        return self + [
            InsertVariant(
                id: "replace_selection",
                label: "Replace selection",
                text: primary.text,
                actionType: .replace
            )
        ]
    }
}

private func joinedLines(_ values: [String?]) -> String {
    values
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private func joinedInline(_ values: [String?]) -> String {
    values
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}
