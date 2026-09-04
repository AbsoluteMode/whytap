import SwiftUI

struct TextAnswerView: View {
    let block: TextAnswerBlock
    let sources: [Source]

    init(block: TextAnswerBlock, sources: [Source] = []) {
        self.block = block
        self.sources = sources
    }

    var body: some View {
        AgentBlockContainer {
            if let title = block.title {
                RendererTitle(title: title, subtitle: block.subtitle)
            }

            MarkdownBodyText(text: block.body)

            SourceAnnotationView(sourceIds: block.sourceIds, sources: sources)

            if let actions = block.actions {
                AgentActionButtonRow(actions: actions)
            }
        }
    }
}

