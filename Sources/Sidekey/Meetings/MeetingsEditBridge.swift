import Combine
import Foundation
import WebKit
import os.log

/// Bridges BlockNote's `noteEdit` postMessage calls into the Swift side
/// of the meetings module.
///
/// Responsibilities:
///
/// 1. Conform to `WKScriptMessageHandler` (via a weak proxy, see the
///    note below) so the WKWebView in `MeetingsViewerView` can register
///    us under the `noteEdit` name without leaking the viewer.
/// 2. Validate the JS payload schema — `{markdown: String, clientVersion: Int}`
///    is the only shape we accept; anything else is dropped with a log
///    line so a misbehaving bundle cannot push garbage into the
///    coordinator.
/// 3. Coalesce a burst of keystroke-driven edits into a single
///    trailing emission via Combine `debounce`. Production wires
///    `MeetingsConfig.editDebounceMilliseconds`; tests inject a tiny
///    interval so they don't wait for half a second per assertion.
/// 4. Publish the debounced events on a Combine `Publisher` the
///    coordinator subscribes to and dispatches into `saveNoteEdit`.
///
/// `attachMeeting(id:)` is mandatory before edits are accepted —
/// without it we don't know which meeting the WKWebView is currently
/// viewing, so we drop the message to defend against a race where the
/// JS bundle fires `noteEdit` before the viewer has loaded a meeting.
@MainActor
final class MeetingsEditBridge {

    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "edit-bridge")

    /// Single edit event the bridge publishes after debounce. Carries
    /// the markdown body, the client's view of the version, and the
    /// meeting id the WKWebView was attached to when the message
    /// arrived — that combination is everything `saveNoteEdit` needs.
    struct EditEvent: Equatable {
        let meetingId: UUID
        let markdown: String
        let clientVersion: Int
    }

    /// Public Combine publisher consumed by `MeetingsCoordinator`. Each
    /// element is the trailing emit from a debounce window — bursts of
    /// keystrokes collapse to one.
    var editEvents: AnyPublisher<EditEvent, Never> {
        debouncedSubject.eraseToAnyPublisher()
    }

    private let rawSubject = PassthroughSubject<EditEvent, Never>()
    private let debouncedSubject = PassthroughSubject<EditEvent, Never>()
    private var cancellable: AnyCancellable?

    /// Currently attached meeting id. Nil until `attachMeeting` is
    /// called; `noteEdit` messages received while nil are dropped so a
    /// stray emission cannot save against the wrong meeting.
    private var currentMeetingId: UUID?

    init(debounceMilliseconds: Int = 500) {
        cancellable = rawSubject
            .debounce(
                for: .milliseconds(debounceMilliseconds),
                scheduler: DispatchQueue.main
            )
            .sink { [weak self] event in
                self?.debouncedSubject.send(event)
            }
    }

    deinit {
        cancellable?.cancel()
    }

    /// Bind the bridge to the meeting currently rendered in the
    /// WKWebView. Subsequent `noteEdit` messages get tagged with this
    /// id; the viewer calls this whenever the sidebar selection
    /// changes.
    func attachMeeting(id: UUID) {
        currentMeetingId = id
        os_log(
            "edit bridge attached (meetingId: %{public}@)",
            log: Self.log, type: .info,
            id.uuidString
        )
    }

    /// Main entry point invoked by `MeetingsEditBridgeMessageProxy` on
    /// every postMessage call from BlockNote. Exposed `internal` so
    /// `MeetingsViewerView` can also route messages here in tests
    /// without needing the proxy.
    func handleScriptMessage(name: String, body: Any) {
        guard name == Self.messageName else {
            os_log(
                "edit bridge dropped unknown message (name: %{public}@)",
                log: Self.log, type: .info,
                name
            )
            return
        }
        guard let payload = body as? [String: Any] else {
            os_log(
                "edit bridge dropped non-dict payload (type: %{public}@)",
                log: Self.log, type: .error,
                String(describing: type(of: body))
            )
            return
        }
        guard let markdown = payload["markdown"] as? String else {
            os_log(
                "edit bridge dropped payload missing markdown key",
                log: Self.log, type: .error
            )
            return
        }
        // JS `Number` round-trips as `Int` for whole numbers and `Double`
        // for fractional — accept either by going through `NSNumber`.
        let clientVersion: Int
        if let int = payload["clientVersion"] as? Int {
            clientVersion = int
        } else if let number = payload["clientVersion"] as? NSNumber,
                  Double(number.intValue) == number.doubleValue {
            clientVersion = number.intValue
        } else {
            os_log(
                "edit bridge dropped payload missing clientVersion or wrong type",
                log: Self.log, type: .error
            )
            return
        }

        guard let meetingId = currentMeetingId else {
            os_log(
                "edit bridge dropped edit — no meeting attached",
                log: Self.log, type: .info
            )
            return
        }

        os_log(
            "edit bridge received edit (meetingId: %{public}@, chars: %{public}d, clientVersion: %{public}d)",
            log: Self.log, type: .info,
            meetingId.uuidString, markdown.count, clientVersion
        )
        rawSubject.send(EditEvent(
            meetingId: meetingId,
            markdown: markdown,
            clientVersion: clientVersion
        ))
    }

    /// Native-editor entry point — submit an edited note body for the
    /// currently attached meeting. Mirrors the old webview `noteEdit` path
    /// (same debounce + publisher → `saveNoteEdit`) but takes an already
    /// validated `String` instead of a JS payload. Dropped if no meeting is
    /// attached, exactly like `handleScriptMessage`.
    func submitEdit(markdown: String, clientVersion: Int) {
        guard let meetingId = currentMeetingId else {
            os_log(
                "edit bridge dropped native edit — no meeting attached",
                log: Self.log, type: .info
            )
            return
        }
        os_log(
            "edit bridge received native edit (meetingId: %{public}@, chars: %{public}d, clientVersion: %{public}d)",
            log: Self.log, type: .info,
            meetingId.uuidString, markdown.count, clientVersion
        )
        rawSubject.send(EditEvent(
            meetingId: meetingId,
            markdown: markdown,
            clientVersion: clientVersion
        ))
    }

    /// Stop forwarding edits — used by `MeetingsViewerView.deinit`
    /// (production) and by tests that want to assert no further
    /// emissions arrive after a teardown.
    func finish() {
        cancellable?.cancel()
        cancellable = nil
    }

    /// JS message-handler name this bridge listens on. The viewer
    /// registers the proxy under the same name in
    /// `MeetingsViewerView`'s init.
    static let messageName = MeetingsViewerView.noteEditHandlerName
}

/// Weak proxy that forwards `WKScriptMessage` to a `MeetingsEditBridge`
/// instance. The proxy exists because `WKUserContentController` retains
/// every script-message handler it's given — registering the bridge
/// directly would leak the bridge (and through it the coordinator's
/// closure references) for the lifetime of the WKWebView.
///
/// Mirrors `MeetingsViewerMessageProxy` from Stage 8b.
final class MeetingsEditBridgeMessageProxy: NSObject, WKScriptMessageHandler {
    private final class WeakRef {
        weak var bridge: MeetingsEditBridge?
    }

    private let weakOwner = WeakRef()
    private let lock = NSLock()

    func setBridge(_ bridge: MeetingsEditBridge) {
        lock.lock(); defer { lock.unlock() }
        weakOwner.bridge = bridge
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let name = message.name
        let body = message.body
        let bridge: MeetingsEditBridge? = {
            lock.lock(); defer { lock.unlock() }
            return weakOwner.bridge
        }()
        Task { @MainActor [weak bridge] in
            bridge?.handleScriptMessage(name: name, body: body)
        }
    }
}
