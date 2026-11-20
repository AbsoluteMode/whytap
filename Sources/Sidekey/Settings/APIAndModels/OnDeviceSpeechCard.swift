import SwiftUI

/// Dictation on this Mac has its own block above the key tiles: it is not a
/// key, and its one action (Download, Cancel or Remove) sits in the card
/// itself instead of in a form under a tile. The download belongs to the
/// shared controller, so it survives leaving the tab.
// WHY: .project-docs/decisions/2026-11-19-on-device-dictation.md
@MainActor
struct OnDeviceSpeechCard: View {
    @ObservedObject var viewModel: APIAndModelsViewModel
    @ObservedObject var model: OnDeviceSpeechModelController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the card shows for a status. Pure, so the copy is tested without
    /// a view.
    struct Presentation: Equatable {
        let symbol: String
        let title: String
        let detail: String
        let action: String

        init(_ status: OnDeviceSpeechModelStatus, model: OnDeviceSpeechModel = .parakeetTdtV3) {
            switch status {
            case .notDownloaded:
                symbol = "laptopcomputer"
                title = "Dictate without a key"
                detail = "Speech is recognized on this Mac: no account, and audio never leaves it. "
                    + "\(model.displayName), \(model.approximateSize)."
                action = "Download"
            case .downloading(let fraction):
                symbol = "arrow.down"
                title = "Downloading \(model.displayName)"
                // Before the first percent the number says nothing, and "0%"
                // read as a stalled download.
                detail = Self.isStarting(fraction)
                    ? "Starting… \(model.approximateSize). You can leave this tab."
                    : "\(Self.percent(fraction))% of \(model.approximateSize). You can leave this tab."
                action = "Cancel"
            case .ready:
                symbol = "checkmark"
                title = "\(model.displayName) is on this Mac"
                detail = "Works offline. Choose On this Mac for Drop in Models."
                action = "Remove"
            case .failed:
                symbol = "exclamationmark.triangle"
                title = "The download didn't finish"
                detail = "Check your connection and try again."
                action = "Download"
            }
        }

        static func percent(_ fraction: Double) -> Int {
            Int((min(1, max(0, fraction)) * 100).rounded(.down))
        }

        /// The download has no whole percent yet: the provider is being
        /// reached or the first bytes are arriving.
        static func isStarting(_ fraction: Double) -> Bool { percent(fraction) == 0 }
    }

    private var presentation: Presentation { Presentation(model.status) }

    private var tint: Color {
        switch model.status {
        case .notDownloaded, .downloading: return MacSettingsTheme.accent
        case .ready: return MacSettingsTheme.green
        case .failed: return MacSettingsTheme.orange
        }
    }

    private var fraction: Double? {
        if case .downloading(let fraction) = model.status { return fraction }
        return nil
    }

    /// The kind of state, without the download fraction: what the card
    /// animates between.
    private var stage: Int {
        switch model.status {
        case .notDownloaded: return 0
        case .downloading: return 1
        case .ready: return 2
        case .failed: return 3
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                icon
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(presentation.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 12)
                actionButton
            }
            if let fraction {
                OnDeviceDownloadBar(
                    fraction: fraction, starting: Presentation.isStarting(fraction), animated: !reduceMotion)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(Presentation.isStarting(fraction)
                        ? "Starting" : "\(Presentation.percent(fraction)) percent")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(stage == 2 ? tint.opacity(0.45) : MacSettingsTheme.sep, lineWidth: stage == 2 ? 1 : 0.5)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: stage)
        .task { await model.refresh() }
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11)
                .fill(tint.opacity(0.13))
            symbol
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    /// The symbol replaces itself between states; the arrow pulses while the
    /// download runs and the checkmark bounces once when it lands. With
    /// Reduce Motion the symbol only changes.
    @ViewBuilder private var symbol: some View {
        let image = Image(systemName: presentation.symbol)
        if reduceMotion {
            image
        } else {
            image
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, options: .repeating, isActive: stage == 1)
                .symbolEffect(.bounce, value: stage == 2)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch model.status {
        case .notDownloaded, .failed:
            MacButton(title: presentation.action, style: .primary, action: download)
        case .downloading:
            MacButton(title: presentation.action, action: remove)
        case .ready:
            MacButton(title: presentation.action, style: .danger, action: remove)
        }
    }

    private func download() {
        Task {
            if await model.download() { viewModel.onDeviceModelChanged() }
        }
    }

    private func remove() {
        Task {
            if await model.remove() { viewModel.onDeviceModelChanged() }
        }
    }
}

/// The download's progress: a bar that eases to each new fraction, with a
/// highlight travelling along the filled part so a slow download still looks
/// alive. While `starting` (no whole percent yet) there is no filled part to
/// show, so a tinted highlight travels the whole track instead of a dot
/// sitting at the left edge. With `animated` off it is a plain bar that
/// jumps to its value, empty while starting.
struct OnDeviceDownloadBar: View {
    let fraction: Double
    var starting = false
    var animated = true
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            let width = starting ? 0 : max(6, proxy.size.width * min(1, max(0, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(MacSettingsTheme.controlBg)
                    .overlay(alignment: .leading) {
                        if starting, animated {
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [
                                        MacSettingsTheme.accent.opacity(0), MacSettingsTheme.accent,
                                        MacSettingsTheme.accent.opacity(0),
                                    ],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: 90)
                                .offset(x: sweep ? proxy.size.width : -90)
                        }
                    }
                    .clipShape(Capsule())
                Capsule()
                    .fill(MacSettingsTheme.accent)
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        if animated {
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [.white.opacity(0), .white.opacity(0.55), .white.opacity(0)],
                                    startPoint: .leading, endPoint: .trailing))
                                .frame(width: 46)
                                .offset(x: sweep ? width : -46)
                        }
                    }
                    .clipShape(Capsule())
                    .animation(animated ? .easeOut(duration: 0.35) : nil, value: fraction)
            }
        }
        .frame(height: 5)
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}
