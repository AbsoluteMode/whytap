import AppKit
import SwiftUI

/// Centered, scrollable expanded card. Opens when the user clicks a
/// strip card's expand button; closes via X / Esc / outside-click.
/// Layered above the strip so the strip stays visible behind.
struct HistoryExpandedView: View {
    @ObservedObject var controller: HistoryStripController
    let assetsDirectory: URL

    static let size = NSSize(width: 700, height: 500)

    var body: some View {
        if let entry = controller.expandedEntry {
            SidekeyExpandedGlass(
                title: headerTitle,
                width: Self.size.width,
                height: Self.size.height,
                onClose: { controller.collapseExpanded() }
            ) {
                ScrollView {
                    bodyContent(for: entry)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(20)
                }
            }
        } else {
            Color.clear
        }
    }

    private var headerTitle: String {
        switch controller.expandedEntry {
        case .agent: return "Agent response"
        case .drop: return "Drop dictation"
        case .clipboard: return "Clipboard entry"
        case nil: return ""
        }
    }

    @ViewBuilder
    private func bodyContent(for entry: HistoryStripExpandedEntry) -> some View {
        switch entry {
        case .agent(let body):
            agentBody(body)
        case .drop(let body):
            dropBody(body)
        case .clipboard(let body):
            clipboardBody(body)
        }
    }

    // MARK: - Body variants

    @ViewBuilder
    private func agentBody(_ body: HistoryStripExpandedEntry.AgentBody) -> some View {
        switch body {
        case .text(let s):
            MarkdownText(raw: s)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
        case .full(let title, let response, let links):
            VStack(alignment: .leading, spacing: 14) {
                if let title = title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                }
                MarkdownText(raw: response.isEmpty ? "(empty)" : response)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                if !links.isEmpty {
                    linksSection(links)
                }
            }
        }
    }

    private func linksSection(_ links: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Links")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
            ForEach(links, id: \.self) { url in
                Text(url.absoluteString)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func dropBody(_ body: HistoryStripExpandedEntry.DropBody) -> some View {
        switch body {
        case .text(let s):
            Text(s)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
        case .full(let raw, let formatted, let targetApp):
            VStack(alignment: .leading, spacing: 14) {
                if let app = targetApp {
                    Text("Pasted into \(app)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Text(formatted)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                if raw != formatted, !raw.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Raw transcript")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(raw)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func clipboardBody(_ body: HistoryStripExpandedEntry.ClipboardBody) -> some View {
        switch body {
        case .text(let s):
            Text(s)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)

        case .image(let img):
            let sidecar = img.sidecarURL(in: assetsDirectory)
            if let data = try? Data(contentsOf: sidecar),
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else if let nsImage = NSImage(data: img.thumbnailData) {
                // Sidecar evicted — fall back to thumbnail bytes so the
                // expanded view still shows something. Caption helps the
                // user understand the lower fidelity.
                VStack(alignment: .leading, spacing: 8) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    Text("Original image no longer available (thumbnail only)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                Text("Image unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }

        case .fileURLs(let urls):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(urls, id: \.self) { url in
                    Text(url.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Aurora glass for expanded panel

/// Mirrors the visual of `SidekeyAuroraWindow` (Settings modal) but
/// accommodates the manual X close button — the expanded panel is a
/// borderless `.nonactivatingPanel` without traffic lights, so we can't
/// reuse `SidekeyAuroraWindow` directly (it was designed for a
/// `SidekeyWindowChrome.configure(_:)`-d NSWindow with full-size content
/// view + traffic lights).
///
/// Same `.ultraThinMaterial` + dark linear gradient
/// (28/28/34 0.78 → 18/18/24 0.85), 14pt continuous corner radius, 40pt
/// title bar with 1pt white 0.06 separator, `.environment(\.colorScheme, .dark)`.
@MainActor
private struct SidekeyExpandedGlass<Content: View>: View {
    let title: String
    let width: CGFloat
    let height: CGFloat
    let onClose: () -> Void
    @ViewBuilder var content: Content

    private let cornerRadius: CGFloat = 14
    private let titleBarHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            content
        }
        .frame(width: width, height: height)
        .background(glassFill)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var titleBar: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.80))
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close expanded view")
                .padding(.trailing, 10)
            }
        }
        .frame(height: titleBarHeight)
        .frame(maxWidth: .infinity)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.white.opacity(0.06)),
            alignment: .bottom
        )
    }

    private var glassFill: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    Color(red: 28 / 255, green: 28 / 255, blue: 34 / 255).opacity(0.78),
                    Color(red: 18 / 255, green: 18 / 255, blue: 24 / 255).opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}
