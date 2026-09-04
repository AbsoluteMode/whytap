import AppKit
import Foundation

/// Owns the standalone Meetings `NSWindow`. The actual sidebar/detail
/// experience lives in `MeetingsContentController` so Settings > Notes
/// can host the same surface without duplicating logic.
@MainActor
final class MeetingsWindowController: NSWindowController {

    let contentController: MeetingsContentController

    init(
        source: MeetingsSidebarSource,
        markdownProvider: @escaping @MainActor (UUID) async throws -> String?,
        transcriptProvider: @escaping @MainActor (UUID) async throws -> [TranscriptSegment]?,
        bundleURL: URL?,
        bundleAccessRoot: URL?,
        refreshHandler: (@MainActor (UUID) async -> Void)? = nil
    ) {
        let contentController = MeetingsContentController(
            source: source,
            markdownProvider: markdownProvider,
            transcriptProvider: transcriptProvider,
            bundleURL: bundleURL,
            bundleAccessRoot: bundleAccessRoot,
            refreshHandler: refreshHandler,
            topBarLeadingInset: 14
        )
        self.contentController = contentController

        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: MeetingsContentController.minimumContentSize
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Meetings"
        window.contentMinSize = MeetingsContentController.minimumContentSize
        window.contentViewController = contentController
        window.isReleasedWhenClosed = false

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MeetingsWindowController only supports programmatic init.")
    }

    // MARK: - Public API

    /// Bring the window forward, refresh the sidebar, and select the
    /// requested meeting.
    func selectMeeting(id: UUID) {
        showWindow(nil)
        contentController.selectMeeting(id: id)
    }

    func refreshSidebar() {
        contentController.refreshSidebar()
    }

    func reloadMeeting(id: UUID) {
        contentController.reloadMeeting(id: id)
    }

    func attachEditBridge(_ bridge: MeetingsEditBridge) {
        contentController.attachEditBridge(bridge)
    }

    func sidebarDidSelectMeeting(id: UUID) {
        contentController.sidebarDidSelectMeeting(id: id)
    }

    override func showWindow(_ sender: Any?) {
        if let window {
            SidekeyWindowChrome.centerOnMainScreen(window)
            window.makeKeyAndOrderFront(nil)
            SidekeyWindowChrome.centerOnMainScreen(window)
            NSApp.activate(ignoringOtherApps: true)
        }
        super.showWindow(sender)
        contentController.refreshOnShow()
    }
}

// MARK: - Production factory

extension MeetingsWindowController {
    /// Production factory used by `MeetingsCoordinator`. Resolves the
    /// BlockNote bundle out of `Bundle.main`'s `blocknote/` subdirectory
    /// (copied in by `scripts/dev-run.sh` / `scripts/build-dmg.sh`).
    static func makeProduction(
        source: MeetingsSidebarSource,
        markdownProvider: @escaping @MainActor (UUID) async throws -> String?,
        transcriptProvider: @escaping @MainActor (UUID) async throws -> [TranscriptSegment]?,
        refreshHandler: (@MainActor (UUID) async -> Void)? = nil
    ) -> MeetingsWindowController {
        let bundleURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "blocknote"
        )
        let bundleRoot = bundleURL?.deletingLastPathComponent()
        return MeetingsWindowController(
            source: source,
            markdownProvider: markdownProvider,
            transcriptProvider: transcriptProvider,
            bundleURL: bundleURL,
            bundleAccessRoot: bundleRoot,
            refreshHandler: refreshHandler
        )
    }
}
