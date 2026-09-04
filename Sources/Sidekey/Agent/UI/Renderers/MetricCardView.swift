import SwiftUI

struct MetricCardView: View {
    let block: MetricCardBlock

    var body: some View {
        AgentBlockContainer(accent: Color.accentColor.opacity(0.35)) {
            RendererTitle(
                title: block.title ?? block.label,
                subtitle: block.subtitle
            )

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(block.value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if let unit = block.unit {
                    Text(unit)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            if let trend = block.trend {
                Text(trend)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let actions = block.actions {
                AgentActionButtonRow(actions: actions)
            }
        }
    }
}

