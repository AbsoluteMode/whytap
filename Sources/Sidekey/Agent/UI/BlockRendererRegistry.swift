import SwiftUI

enum BlockRendererRegistry {
    @ViewBuilder
    static func view(for block: UIBlock) -> some View {
        view(for: block, sources: [])
    }

    @ViewBuilder
    static func view(for block: UIBlock, sources: [Source]) -> some View {
        switch block {
        case .textAnswer(let payload):
            TextAnswerView(block: payload, sources: sources)
        case .entityCard(let payload):
            EntityCardView(block: payload)
        case .entityList(let payload):
            EntityListView(block: payload)
        case .metricCard(let payload):
            MetricCardView(block: payload)
        case .searchResults(let payload):
            SearchResultsView(block: payload, sources: sources)
        case .stateEmpty(let payload):
            StateEmptyView(block: payload)
        case .stateError(let payload):
            StateErrorView(block: payload)
        case .statePermission(let payload):
            StatePermissionView(block: payload)
        case .usefulLinks(let payload):
            UsefulLinksBlockView(block: payload)
        case .usefulActions(let payload):
            // Stateless render (no selection chip / hotkeys). The live agent
            // path renders via AgentAnswerBodyView's special-case, which injects
            // the shared selection state; this registry path is for surfaces
            // that don't drive selection.
            ActionsBlockView(block: payload)
        }
    }

    static func rendererTypeName(for block: UIBlock) -> String {
        String(describing: rendererType(for: block))
    }

    static func rendererType(for block: UIBlock) -> Any.Type {
        switch block {
        case .textAnswer:
            return TextAnswerView.self
        case .entityCard:
            return EntityCardView.self
        case .entityList:
            return EntityListView.self
        case .metricCard:
            return MetricCardView.self
        case .searchResults:
            return SearchResultsView.self
        case .stateEmpty:
            return StateEmptyView.self
        case .stateError:
            return StateErrorView.self
        case .statePermission:
            return StatePermissionView.self
        case .usefulLinks:
            return UsefulLinksBlockView.self
        case .usefulActions:
            return ActionsBlockView.self
        }
    }
}

