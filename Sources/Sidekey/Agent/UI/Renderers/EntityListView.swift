import SwiftUI

struct EntityListView: View {
    let block: EntityListBlock

    var body: some View {
        AgentBlockContainer {
            RendererTitle(
                title: block.title ?? "\(block.items.count) items",
                subtitle: block.subtitle ?? block.entityType?.rawValue
            )

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(block.items.enumerated()), id: \.offset) { index, item in
                    row(for: item)
                    if index < block.items.count - 1 {
                        Divider().padding(.vertical, 6)
                    }
                }
            }

            if let actions = block.actions {
                AgentActionButtonRow(actions: actions)
            }
        }
    }

    private func row(for item: EntityListBlock.Item) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let url = item.url {
                AgentActionButton(action: UIAction(
                    type: .open,
                    label: "Open",
                    url: url,
                    variant: .secondary
                ))
            }
        }
    }
}

