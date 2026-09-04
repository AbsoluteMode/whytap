import SwiftUI

struct DebugFallbackView: View {
    let rawJSON: String
    let env: BuildFlavor

    init(rawJSON: String, env: BuildFlavor = BuildConfig.flavor) {
        self.rawJSON = rawJSON
        self.env = env
    }

    init(block: UIBlock, env: BuildFlavor = BuildConfig.flavor) {
        self.rawJSON = Self.jsonString(for: block)
        self.env = env
    }

    var body: some View {
        switch env {
        case .prod:
            StateErrorView(block: StateErrorBlock(
                title: "Response error",
                message: "Malformed server response.",
                code: "block_malformed",
                retryable: true
            ))
        case .dev, .beta:
            AgentBlockContainer(accent: Color.orange.opacity(0.45)) {
                RendererTitle(
                    title: "Unsupported UI block",
                    subtitle: "Debug payload"
                )

                ScrollView(.horizontal, showsIndicators: true) {
                    Text(rawJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private static func jsonString(for block: UIBlock) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(block),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: block)
        }
        return string
    }
}

