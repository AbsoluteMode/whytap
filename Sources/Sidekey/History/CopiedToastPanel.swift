import AppKit
import Combine
import SwiftUI

/// Tiny centered NSPanel that pops up when the user clicks a strip
/// card's body. Hosts a SwiftUI `DarkGlassCard` pill that says
/// "Copied" + a checkmark, fades in / holds / fades out.
@MainActor
final class CopiedToastPanel: NSPanel {
    static let panelSize = NSSize(width: 130, height: 44)
    /// NSWindow level for the "Copied" toast. Sits at the same tier as
    /// `HistoryStripPanel.windowLevel` / `HistoryExpandedPanel.windowLevel`
    /// (above the Dock). Because the toast is ordered front each time
    /// it's shown, it wins the tie and overlays the other two panels.
    static let windowLevel: NSWindow.Level = .statusBar

    private let controller: CopiedToastController
    private var cancellables = Set<AnyCancellable>()

    init(controller: CopiedToastController) {
        self.controller = controller

        let initialFrame = Self.centeredFrame(
            on: IslandScreenResolver.currentVisibleFrame()
        )
        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        // Toast must beat the Dock too — it appears centered on screen
        // but can overlap the dock zone on small displays. Matches the
        // other two history panels' window level and orders front on
        // every show, so the tie-break with the strip / expanded panel
        // resolves in the toast's favour.
        self.level = Self.windowLevel
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        // Toast is purely visual — must NOT swallow clicks. Without
        // this the user clicking-through the toast (e.g. trying to
        // click the strip behind it) hits the toast first and nothing
        // would happen.
        self.ignoresMouseEvents = true
        self.isMovable = false
        self.hidesOnDeactivate = false

        let host = NSHostingView(rootView: CopiedToastView(controller: controller))
        host.frame = NSRect(origin: .zero, size: initialFrame.size)
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        self.contentView = host

        controller.$isVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                self?.applyVisibility(visible: visible)
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenChange),
            name: IslandScreenResolver.selectionDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc private func handleScreenChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshFrame()
        }
    }

    private func refreshFrame() {
        let visible = IslandScreenResolver.currentVisibleFrame()
        setFrame(Self.centeredFrame(on: visible), display: true, animate: false)
    }

    static func centeredFrame(on visible: NSRect) -> NSRect {
        let size = panelSize
        let originX = visible.midX - size.width / 2
        let originY = visible.midY - size.height / 2
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }

    private func applyVisibility(visible: Bool) {
        if visible {
            refreshFrame()
            orderFrontRegardless()
        } else {
            // SwiftUI handles its own fade-out. Schedule the
            // `orderOut` slightly after the SwiftUI fade-out window so
            // the pixels disappear AFTER the animation completes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
                guard let self else { return }
                guard !self.controller.isVisible else { return }
                self.orderOut(nil)
            }
        }
    }
}

/// SwiftUI body for the toast — a dark-glass pill with the word
/// "Copied" + a checkmark, animating its opacity off
/// `controller.isVisible`.
struct CopiedToastView: View {
    @ObservedObject var controller: CopiedToastController

    var body: some View {
        DarkGlassCard(
            width: CopiedToastPanel.panelSize.width,
            height: CopiedToastPanel.panelSize.height,
            cornerRadius: 22
        ) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Copied")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .opacity(controller.isVisible ? 1 : 0)
        .scaleEffect(controller.isVisible ? 1.0 : 0.92)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: controller.isVisible)
    }
}
