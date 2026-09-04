import SwiftUI

struct EntityCardView: View {
    let block: EntityCardBlock

    var body: some View {
        AgentBlockContainer {
            RendererTitle(
                title: block.title ?? block.name,
                subtitle: block.subtitle ?? block.description
            )

            VStack(alignment: .leading, spacing: 5) {
                fieldRow(label: "Type", value: block.entityType.rawValue)
                if let id = block.id {
                    fieldRow(label: "ID", value: id)
                }
                if let url = block.url {
                    fieldRow(label: "URL", value: url.agentDisplayString)
                }
                ForEach(attributeRows, id: \.key) { row in
                    fieldRow(label: row.key, value: row.value)
                }
            }

            if let actions = block.actions {
                AgentActionButtonRow(actions: actions)
            }
        }
    }

    private var attributeRows: [(key: String, value: String)] {
        (block.attributes ?? [:])
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value.displayString) }
    }

    private func fieldRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

