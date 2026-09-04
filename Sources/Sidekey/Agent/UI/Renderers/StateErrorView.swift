import SwiftUI

struct StateErrorView: View {
    let block: StateErrorBlock

    var body: some View {
        AgentBlockContainer(accent: Color.red.opacity(0.45)) {
            RendererTitle(
                title: block.title ?? "Error",
                subtitle: block.subtitle ?? block.code
            )

            Text(block.message)
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if block.retryable {
                AgentActionButton(action: retryAction)
            }
        }
    }

    private var retryAction: UIAction {
        block.actions?.first(where: { $0.type == .retry })
            ?? UIAction(type: .retry, label: "Retry", variant: .primary)
    }
}

