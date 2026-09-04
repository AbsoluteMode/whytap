import SwiftUI

struct StatePermissionView: View {
    let block: StatePermissionBlock

    var body: some View {
        AgentBlockContainer(accent: Color.accentColor.opacity(0.30)) {
            RendererTitle(
                title: block.title ?? "Permission required",
                subtitle: block.subtitle
            )

            if let message = block.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AgentActionButton(action: connectAction)
        }
    }

    private var connectAction: UIAction {
        block.actions?.first(where: { $0.type == .connect })
            ?? UIAction(
                type: .connect,
                label: "Connect \(block.provider.capitalized)",
                variant: .primary
            )
    }
}

