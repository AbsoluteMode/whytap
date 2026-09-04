import Combine
import XCTest
@testable import Sidekey

/// Regression: stale-read race when Drop is re-bound at runtime (ROO-234).
///
/// `HotkeyPreferences` publishes its `@Published` Drop shortcut/gesture in the
/// property's `willSet` — i.e. BEFORE the stored value is updated. A Combine
/// `sink` with no `.receive(on:)` therefore runs *synchronously inside that
/// willSet*. The old re-registration path re-read `HotkeyPreferences.shared`
/// from inside the sink, so it saw the PREVIOUS value and rebuilt Drop on the
/// wrong monitor (combo ↔ hold-Space swapped). After an app restart the stored
/// value was settled and everything worked, which is why the bug was purely a
/// runtime symptom.
///
/// These tests drive the SAME wiring production uses — the static
/// `AppDelegate.observeDropShortcut` / `observeDropGesture` installers — and
/// assert the value handed to the registrar is the FRESH one, not the stale
/// stored property captured mid-willSet.
@MainActor
final class DropReregisterRaceTests: XCTestCase {

    // MARK: - Shortcut sink sees the new value (not the stale stored property)

    func test_drop_shortcut_change_delivers_fresh_value_to_registrar() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        // Start from the Hold-Space default so the change crosses the
        // holdSpace → combo boundary that mis-routes the monitor.
        preferences.dropVoiceShortcut = .holdSpace

        var resolved: [HotkeyShortcut] = []
        let cancellable = AppDelegate.observeDropShortcut(preferences) { shortcut in
            resolved.append(shortcut)
        }
        defer { cancellable.cancel() }

        preferences.dropVoiceShortcut = .combo(.optionD)

        // The registrar must build Drop from the value just assigned. Reading
        // `HotkeyPreferences.shared` mid-willSet (the bug) would yield the prior
        // `.holdSpace` here and register the wrong monitor.
        XCTAssertEqual(resolved.last, .combo(.optionD))
    }

    func test_drop_shortcut_change_back_to_holdspace_delivers_fresh_value() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.dropVoiceShortcut = .combo(.optionD)

        var resolved: [HotkeyShortcut] = []
        let cancellable = AppDelegate.observeDropShortcut(preferences) { shortcut in
            resolved.append(shortcut)
        }
        defer { cancellable.cancel() }

        preferences.dropVoiceShortcut = .holdSpace

        // Returning to the default must hand `.holdSpace` to the registrar so it
        // rebuilds the Space-hold monitor; a stale read would keep the old combo
        // and leave hold-Space broken until the next launch.
        XCTAssertEqual(resolved.last, .holdSpace)
    }

    // MARK: - Resolved monitor routes to the correct backend for the fresh value

    func test_resolved_shortcut_routes_to_spacehold_after_switching_back() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.dropVoiceShortcut = .combo(.optionD)

        var resolved: HotkeyShortcut?
        let cancellable = AppDelegate.observeDropShortcut(preferences) { shortcut in
            resolved = shortcut
        }
        defer { cancellable.cancel() }

        preferences.dropVoiceShortcut = .holdSpace

        let monitor = HotkeyShortcutMonitor(
            shortcut: try! XCTUnwrap(resolved),
            hotKeyIDValue: 1,
            onHotkey: {},
            onHotkeyReleased: {},
            onCancel: {}
        )
        // The fresh value is `.holdSpace`, so the monitor the registrar would
        // build must be the CGEventTap Space-hold one — not the stale Carbon
        // combo monitor.
        XCTAssertTrue(monitor.routedMonitorIsSpaceHold)
        XCTAssertFalse(monitor.routedMonitorIsCarbon)
    }

    // MARK: - Gesture sink sees the new value too

    func test_drop_gesture_change_delivers_fresh_value_to_registrar() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.dropVoiceGesture = .hold

        var resolved: [HotkeyGesture] = []
        let cancellable = AppDelegate.observeDropGesture(preferences) { gesture in
            resolved.append(gesture)
        }
        defer { cancellable.cancel() }

        preferences.dropVoiceGesture = .tap

        XCTAssertEqual(resolved.last, .tap)
    }

    // MARK: - Hover-slot sinks share the same willSet stale-read class

    /// The Hover-slot registrar reads `configuration.hoverSlotShortcuts` — i.e.
    /// all five stored properties. A synchronous sink on one
    /// `$hoverSlotNShortcut` therefore re-reads that same property mid-willSet
    /// and sees the prior value, registering the changed slot on the stale
    /// shortcut. Same fix: thread the published value through per slot.
    func test_hover_slot_change_delivers_fresh_value_for_that_slot() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.hoverSlot2Shortcut = .combo(.optionTwo)

        var resolved: [(index: Int, shortcut: HotkeyShortcut)] = []
        let cancellables = AppDelegate.observeHoverSlotShortcuts(preferences) { index, shortcut in
            resolved.append((index, shortcut))
        }
        defer { cancellables.forEach { $0.cancel() } }

        preferences.hoverSlot2Shortcut = .combo(.optionD)

        let last = resolved.last
        XCTAssertEqual(last?.index, 2)
        XCTAssertEqual(last?.shortcut, .combo(.optionD))
    }

    func test_hover_slot_change_reports_correct_slot_index() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())

        var resolved: [(index: Int, shortcut: HotkeyShortcut)] = []
        let cancellables = AppDelegate.observeHoverSlotShortcuts(preferences) { index, shortcut in
            resolved.append((index, shortcut))
        }
        defer { cancellables.forEach { $0.cancel() } }

        preferences.hoverSlot4Shortcut = .combo(.optionQ)

        let last = resolved.last
        XCTAssertEqual(last?.index, 4)
        XCTAssertEqual(last?.shortcut, .combo(.optionQ))
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SidekeyTests.DropReregisterRace.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
