import AppKit
import SwiftUI

/// Opens the What's New window: by itself once after an update, and from the
/// version in Settings.
// WHY: .project-docs/decisions/2026-11-24-whats-new-window.md
@MainActor
final class WhatsNewPresenter {
    static let shared = WhatsNewPresenter()

    struct Request: Equatable {
        let releases: [WhatsNewRelease]
        let since: String?
        /// From Settings the window takes the keyboard; after an update it
        /// comes forward without taking it from the app the person is in.
        let activates: Bool
    }

    var catalog: WhatsNewCatalog
    var currentVersion: String
    var openSettings: (SettingsWindowTab) -> Void = { _ in }
    /// Shows the window; tests replace it and no window opens.
    var display: (Request) -> Void = { _ in }
    /// Puts the built window on screen; tests replace it and nothing shows.
    var bringForward: (WhatsNewWindowController) -> Void = { $0.show() }
    /// The presenter's window, while one is open.
    private(set) var controller: WhatsNewWindowController?

    init(catalog: WhatsNewCatalog = .bundled(), currentVersion: String = AppBuildIdentity.current.version) {
        self.catalog = catalog
        self.currentVersion = currentVersion
        display = { [weak self] in self?.open($0) }
    }

    /// Every release up to the running one that has something to show.
    var history: [WhatsNewRelease] { catalog.releases(after: nil, through: currentVersion) }

    /// Call once per launch, after the onboarding decision.
    func presentAfterLaunch(isFirstLaunch: Bool, defaults: UserDefaults) {
        let seen = defaults.string(forKey: WhatsNewLaunch.seenVersionKey)
        let releases = WhatsNewLaunch.consume(currentVersion: currentVersion, isFirstLaunch: isFirstLaunch,
                                              catalog: catalog, defaults: defaults)
        guard !releases.isEmpty else { return }
        display(Request(releases: releases, since: seen, activates: false))
    }

    /// The same list from Settings, with the earlier releases under it.
    func presentHistory() {
        let releases = history
        guard !releases.isEmpty else { return }
        display(Request(releases: releases, since: nil, activates: true))
    }

    private func open(_ request: Request) {
        controller?.close()
        let controller = WhatsNewWindowController(request: request, onLink: { [weak self] tab in
            self?.openSettings(tab)
        }, onClosed: {})
        controller.onClosed = { [weak self, weak controller] in
            // Released after AppKit finishes closing the window, and only
            // while this window is still the presenter's: a newer window
            // that replaced it stays.
            DispatchQueue.main.async {
                guard let self, let controller, self.controller === controller else { return }
                self.controller = nil
            }
        }
        self.controller = controller
        bringForward(controller)
    }
}

@MainActor
final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    private let request: WhatsNewPresenter.Request
    var onClosed: () -> Void

    init(request: WhatsNewPresenter.Request, onLink: @escaping (SettingsWindowTab) -> Void,
         onClosed: @escaping () -> Void) {
        self.request = request
        self.onClosed = onClosed
        let window = WhatsNewWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: WhatsNewView.width, height: 400)),
                                    styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "What’s New in Whytap"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.level = .normal
        window.collectionBehavior = [.managed, .fullScreenNone]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self

        func view(scrolls: Bool) -> WhatsNewView {
            WhatsNewView(releases: request.releases, since: request.since, scrolls: scrolls, onLink: onLink,
                         onClose: { [weak self] in self?.close() })
        }
        let natural = Self.naturalHeight(of: request)
        let height = Self.height(natural: natural, screen: NSScreen.main?.visibleFrame.height)
        let hosting = NSHostingController(rootView: view(scrolls: natural > height))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: WhatsNewView.width, height: height))
    }

    required init?(coder: NSCoder) {
        fatalError("WhatsNewWindowController only supports programmatic init.")
    }

    /// The height of the whole list without scrolling.
    static func naturalHeight(of request: WhatsNewPresenter.Request) -> CGFloat {
        let probe = NSHostingView(rootView: WhatsNewView(releases: request.releases, since: request.since,
                                                         playsVideo: false))
        return ceil(probe.fittingSize.height)
    }

    /// As tall as the list, up to the window's limit and a small screen.
    static func height(natural: CGFloat, screen: CGFloat?) -> CGFloat {
        let limit = min(WhatsNewView.maxHeight, (screen ?? .infinity) - 60)
        return min(natural, max(limit, 320))
    }

    func show() {
        guard let window else { return }
        SidekeyWindowChrome.centerOnMainScreen(window)
        if request.activates {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFrontRegardless()
        }
    }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) { onClosed() }
}

/// Escape closes the window. The page has no text field, so nothing in it
/// turns the key into `cancelOperation`; unhandled, it would end at the
/// window and beep.
final class WhatsNewWindow: NSWindow {
    static let escapeKeyCode: UInt16 = 53

    override func keyDown(with event: NSEvent) {
        if event.keyCode == Self.escapeKeyCode { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { close() }
}
