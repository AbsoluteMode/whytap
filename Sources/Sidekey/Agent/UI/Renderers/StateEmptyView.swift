import SwiftUI

struct StateEmptyView: View {
    let block: StateEmptyBlock

    var body: some View {
        AgentBlockContainer(accent: Color.secondary.opacity(0.22)) {
            RendererTitle(
                title: block.title ?? "No results",
                subtitle: block.subtitle
            )

            Text(block.message)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let actions = block.actions {
                AgentActionButtonRow(actions: actions)
            }
        }
    }
}

