import SwiftUI

struct SearchResultsView: View {
    let block: SearchResultsBlock
    let sources: [Source]

    init(block: SearchResultsBlock, sources: [Source] = []) {
        self.block = block
        self.sources = sources
    }

    var body: some View {
        AgentBlockContainer {
            RendererTitle(
                title: block.title ?? "Search results",
                subtitle: block.subtitle
            )

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(block.results.enumerated()), id: \.offset) { index, result in
                    row(for: result)
                    if index < block.results.count - 1 {
                        Divider().padding(.vertical, 7)
                    }
                }
            }

            if let actions = block.actions {
                AgentActionButtonRow(actions: actions)
            }
        }
    }

    private func row(for result: SearchResultsBlock.Result) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
            if let snippet = result.snippet {
                Text(snippet)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                if let provider = providerLabel(for: result) {
                    Text(provider)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                if let url = result.url {
                    Text(url.agentDisplayString)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func providerLabel(for result: SearchResultsBlock.Result) -> String? {
        guard let sourceId = result.sourceId,
              let source = sources.first(where: { $0.id == sourceId }) else {
            return result.sourceId
        }
        return source.provider ?? source.title
    }
}

