import Carbon.HIToolbox
import Foundation
import XCTest
@testable import Sidekey

@MainActor
final class UsefulLinksHotkeyControllerTests: XCTestCase {
    // MARK: - Activation policy

    func testStartWithZeroLinksRegistersNothing() {
        // An empty useful_links block — no chips visible, no nav to do.
        // The controller must not register any monitors so other apps'
        // ⌥← / ⌥→ word-jump bindings keep working.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 0, openAvailable: true)

        XCTAssertEqual(factory.created.count, 0)
        XCTAssertEqual(factory.activeStarts, 0)
    }

    func testStartWithOneLinkRegistersInsertAndOpenOnly() {
        // Spec: count == 1 — register ⌥← (Insert) and ⌥→ (Open), skip
        // ⌥↑ / ⌥↓ (nothing to move between). The Carbon registration
        // surface stays minimal so we don't shadow ⌥↑/⌥↓ in other apps
        // when there's no nav to do.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 1, openAvailable: true)

        XCTAssertEqual(factory.created.count, 2)
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.leftArrowKeyCode })
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.rightArrowKeyCode })
        XCTAssertFalse(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.upArrowKeyCode })
        XCTAssertFalse(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.downArrowKeyCode })
        XCTAssertEqual(factory.activeStarts, 2)
    }

    func testStartWithTwoLinksRegistersAllFourHotkeys() {
        // Spec: count >= 2 — all four hotkeys register so the user can
        // navigate up/down between rows in addition to acting on the
        // selected row.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 2, openAvailable: true)

        XCTAssertEqual(factory.created.count, 4)
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.leftArrowKeyCode })
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.rightArrowKeyCode })
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.upArrowKeyCode })
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.downArrowKeyCode })
        XCTAssertEqual(factory.activeStarts, 4)
    }

    func testStartWithThreeLinksStillRegistersFourHotkeys() {
        // Sanity check: the SSE contract caps at 3 links, so 3 is the
        // realistic upper bound. The four-hotkey set is the same as
        // for 2 — registration policy is binary on count >= 2.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 3, openAvailable: true)

        XCTAssertEqual(factory.created.count, 4)
    }

    // MARK: - Open availability gating (per selected item type)

    func testCopyItemSelectedOmitsOpenHotkey() {
        // Spec: a copy item exposes insert only. When the selected item does
        // not support open, the Open (→) hotkey must NOT register — Insert (←)
        // and up/down nav stay. So a 3-item block with a copy selected
        // registers Insert + Down + Up = 3 monitors, no Open.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 3, openAvailable: false)

        XCTAssertEqual(factory.created.count, 3)
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.leftArrowKeyCode })
        XCTAssertFalse(
            factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.rightArrowKeyCode },
            "Open (→) must not register for a copy item"
        )
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.downArrowKeyCode })
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.upArrowKeyCode })
    }

    func testSingleCopyItemRegistersInsertOnly() {
        // count == 1, copy selected: only Insert (←). No Open, no nav.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 1, openAvailable: false)

        XCTAssertEqual(factory.created.count, 1)
        XCTAssertTrue(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.leftArrowKeyCode })
        XCTAssertFalse(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.rightArrowKeyCode })
    }

    func testNavigationHotkeysUseConfiguredCombos() {
        var configuration = HotkeyConfiguration.defaults
        configuration.usefulLinksNextCombo = .optionD
        configuration.usefulLinksPreviousCombo = .optionQ
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(
            configurationProvider: { configuration },
            monitorFactory: factory.make
        )

        controller.start(itemCount: 2, openAvailable: true)

        XCTAssertTrue(factory.created.contains {
            $0.keyCode == HotkeyTapCombo.optionD.keyCode &&
                $0.hotKeyIDValue == CarbonHotkeyMonitor.usefulLinksDownHotKeyID
        })
        XCTAssertTrue(factory.created.contains {
            $0.keyCode == HotkeyTapCombo.optionQ.keyCode &&
                $0.hotKeyIDValue == CarbonHotkeyMonitor.usefulLinksUpHotKeyID
        })
        XCTAssertFalse(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.downArrowKeyCode })
        XCTAssertFalse(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.upArrowKeyCode })
    }

    func testInsertAndOpenHotkeysUseConfiguredCombos() {
        var configuration = HotkeyConfiguration.defaults
        configuration.usefulLinksInsertCombo = .optionD
        configuration.usefulLinksOpenCombo = .optionQ
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(
            configurationProvider: { configuration },
            monitorFactory: factory.make
        )

        controller.start(itemCount: 1, openAvailable: true)

        XCTAssertTrue(factory.created.contains {
            $0.keyCode == HotkeyTapCombo.optionD.keyCode &&
                $0.modifiers == HotkeyTapCombo.optionD.modifiers &&
                $0.hotKeyIDValue == CarbonHotkeyMonitor.usefulLinksInsertHotKeyID
        })
        XCTAssertTrue(factory.created.contains {
            $0.keyCode == HotkeyTapCombo.optionQ.keyCode &&
                $0.modifiers == HotkeyTapCombo.optionQ.modifiers &&
                $0.hotKeyIDValue == CarbonHotkeyMonitor.usefulLinksOpenHotKeyID
        })
        XCTAssertFalse(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.leftArrowKeyCode })
        XCTAssertFalse(factory.created.contains { $0.keyCode == CarbonHotkeyMonitor.rightArrowKeyCode })
    }

    // MARK: - Modifier policy

    func testAllUsefulLinksHotkeysAreBareArrows() {
        // The whole family defaults to BARE arrows, no modifier: Insert ←,
        // Open →, Next ↓, Previous ↑. The user drives links with the arrow
        // keys alone while the answer is on screen.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 3, openAvailable: true)

        for monitor in factory.created {
            XCTAssertEqual(monitor.modifiers, 0, "Useful-links hotkeys must be bare (no modifier).")
            switch monitor.hotKeyIDValue {
            case CarbonHotkeyMonitor.usefulLinksInsertHotKeyID:
                XCTAssertEqual(monitor.keyCode, CarbonHotkeyMonitor.leftArrowKeyCode)
            case CarbonHotkeyMonitor.usefulLinksOpenHotKeyID:
                XCTAssertEqual(monitor.keyCode, CarbonHotkeyMonitor.rightArrowKeyCode)
            case CarbonHotkeyMonitor.usefulLinksDownHotKeyID:
                XCTAssertEqual(monitor.keyCode, CarbonHotkeyMonitor.downArrowKeyCode)
            case CarbonHotkeyMonitor.usefulLinksUpHotKeyID:
                XCTAssertEqual(monitor.keyCode, CarbonHotkeyMonitor.upArrowKeyCode)
            default:
                XCTFail("Unexpected useful-links hotkey id \(monitor.hotKeyIDValue)")
            }
        }
    }

    func testConfiguredUsefulLinksHotkeysUseConfiguredModifiers() {
        let commandD = HotkeyTapCombo(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey),
            keyTitle: "D"
        )
        let shiftQ = HotkeyTapCombo(
            keyCode: UInt32(kVK_ANSI_Q),
            modifiers: UInt32(shiftKey),
            keyTitle: "Q"
        )
        var configuration = HotkeyConfiguration.defaults
        configuration.usefulLinksInsertCombo = commandD
        configuration.usefulLinksNextCombo = shiftQ
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(
            configurationProvider: { configuration },
            monitorFactory: factory.make
        )

        controller.start(itemCount: 2, openAvailable: true)

        XCTAssertTrue(factory.created.contains {
            $0.keyCode == commandD.keyCode &&
                $0.modifiers == commandD.modifiers &&
                $0.hotKeyIDValue == CarbonHotkeyMonitor.usefulLinksInsertHotKeyID
        })
        XCTAssertTrue(factory.created.contains {
            $0.keyCode == shiftQ.keyCode &&
                $0.modifiers == shiftQ.modifiers &&
                $0.hotKeyIDValue == CarbonHotkeyMonitor.usefulLinksDownHotKeyID
        })
    }

    func testHotkeyIDsAreDistinctPerActionSoCarbonRoutingDoesntCollide() {
        // Carbon delivers hot-key events by (signature, id) — duplicate
        // ids would mean an Insert press also fires Open. Pin the four
        // ids to the constants reserved on CarbonHotkeyMonitor.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 3, openAvailable: true)

        let ids = factory.created.map(\.hotKeyIDValue)
        XCTAssertEqual(Set(ids).count, ids.count, "hotkey ids must be unique across the family")
        XCTAssertTrue(ids.contains(CarbonHotkeyMonitor.usefulLinksInsertHotKeyID))
        XCTAssertTrue(ids.contains(CarbonHotkeyMonitor.usefulLinksOpenHotKeyID))
        XCTAssertTrue(ids.contains(CarbonHotkeyMonitor.usefulLinksDownHotKeyID))
        XCTAssertTrue(ids.contains(CarbonHotkeyMonitor.usefulLinksUpHotKeyID))
    }

    // MARK: - Action dispatch

    func testInsertHotkeyDispatchesToInsertHandler() {
        let factory = FakeMonitorFactory()
        var insertCount = 0
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)
        controller.onInsert = { insertCount += 1 }

        controller.start(itemCount: 3, openAvailable: true)
        factory.fireHotkey(keyCode: CarbonHotkeyMonitor.leftArrowKeyCode)

        XCTAssertEqual(insertCount, 1)
    }

    func testOpenHotkeyDispatchesToOpenHandler() {
        let factory = FakeMonitorFactory()
        var openCount = 0
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)
        controller.onOpen = { openCount += 1 }

        controller.start(itemCount: 3, openAvailable: true)
        factory.fireHotkey(keyCode: CarbonHotkeyMonitor.rightArrowKeyCode)

        XCTAssertEqual(openCount, 1)
    }

    func testConfiguredInsertAndOpenHotkeysDispatchToHandlers() {
        var configuration = HotkeyConfiguration.defaults
        configuration.usefulLinksInsertCombo = .optionD
        configuration.usefulLinksOpenCombo = .optionQ
        let factory = FakeMonitorFactory()
        var insertCount = 0
        var openCount = 0
        let controller = UsefulLinksHotkeyController(
            configurationProvider: { configuration },
            monitorFactory: factory.make
        )
        controller.onInsert = { insertCount += 1 }
        controller.onOpen = { openCount += 1 }

        controller.start(itemCount: 3, openAvailable: true)
        factory.fireHotkey(keyCode: HotkeyTapCombo.optionD.keyCode)
        factory.fireHotkey(keyCode: HotkeyTapCombo.optionQ.keyCode)

        XCTAssertEqual(insertCount, 1)
        XCTAssertEqual(openCount, 1)
    }

    func testDownHotkeyDispatchesToNextHandler() {
        let factory = FakeMonitorFactory()
        var nextCount = 0
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)
        controller.onNext = { nextCount += 1 }

        controller.start(itemCount: 3, openAvailable: true)
        factory.fireHotkey(keyCode: CarbonHotkeyMonitor.downArrowKeyCode)

        XCTAssertEqual(nextCount, 1)
    }

    func testUpHotkeyDispatchesToPreviousHandler() {
        let factory = FakeMonitorFactory()
        var prevCount = 0
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)
        controller.onPrevious = { prevCount += 1 }

        controller.start(itemCount: 3, openAvailable: true)
        factory.fireHotkey(keyCode: CarbonHotkeyMonitor.upArrowKeyCode)

        XCTAssertEqual(prevCount, 1)
    }

    func testConfiguredNavigationHotkeysDispatchToHandlers() {
        var configuration = HotkeyConfiguration.defaults
        configuration.usefulLinksNextCombo = .optionD
        configuration.usefulLinksPreviousCombo = .optionQ
        let factory = FakeMonitorFactory()
        var nextCount = 0
        var previousCount = 0
        let controller = UsefulLinksHotkeyController(
            configurationProvider: { configuration },
            monitorFactory: factory.make
        )
        controller.onNext = { nextCount += 1 }
        controller.onPrevious = { previousCount += 1 }

        controller.start(itemCount: 3, openAvailable: true)
        factory.fireHotkey(keyCode: HotkeyTapCombo.optionD.keyCode)
        factory.fireHotkey(keyCode: HotkeyTapCombo.optionQ.keyCode)

        XCTAssertEqual(nextCount, 1)
        XCTAssertEqual(previousCount, 1)
    }

    // MARK: - Lifecycle

    func testStopUnregistersAllMonitors() {
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 3, openAvailable: true)
        XCTAssertEqual(factory.activeStarts, 4)

        controller.stop()

        XCTAssertEqual(factory.activeStops, 4)
    }

    func testRestartingWithDifferentCountRebuildsMonitorSet() {
        // First useful_links block had 3 links — 4 monitors. The next
        // block lands with 1 link — controller must tear down the up/down
        // monitors and end up with just Insert + Open.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 3, openAvailable: true)
        XCTAssertEqual(factory.created.count, 4)
        XCTAssertEqual(factory.activeStarts, 4)

        controller.start(itemCount: 1, openAvailable: true)

        // Previous 4 stopped, new 2 created and started.
        XCTAssertEqual(factory.activeStops, 4)
        XCTAssertEqual(factory.created.count, 6)
        XCTAssertEqual(factory.activeStarts, 6)
    }

    func testStopWhenNotStartedIsNoOp() {
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.stop()

        XCTAssertEqual(factory.activeStops, 0)
    }

    func testStartWithZeroLinksTearsDownAnyPriorMonitors() {
        // Useful_links block disappears (next agent turn, panel close)
        // — the controller is told `start(itemCount: 0, openAvailable: true)` which is
        // equivalent to a stop. Carbon registrations must drop so the
        // user's normal ⌥←/⌥→ word-jump bindings come back.
        let factory = FakeMonitorFactory()
        let controller = UsefulLinksHotkeyController(monitorFactory: factory.make)

        controller.start(itemCount: 3, openAvailable: true)
        XCTAssertEqual(factory.activeStarts, 4)

        controller.start(itemCount: 0, openAvailable: true)

        XCTAssertEqual(factory.activeStops, 4)
    }
}

// MARK: - Fake monitor factory

@MainActor
private final class FakeMonitorFactory {
    /// Records every monitor the controller asked us to create. The
    /// controller talks to the factory through a closure so we can
    /// keep production CarbonHotkeyMonitor independent of test code.
    final class FakeMonitor: UsefulLinksHotkeyControlling {
        let shortcut: HotkeyShortcut
        let hotKeyIDValue: UInt32
        var onHotkey: (() -> Void) = {}
        private(set) var startCount = 0
        private(set) var stopCount = 0

        var keyCode: UInt32 {
            shortcut.combo?.keyCode ?? 0
        }

        var modifiers: UInt32 {
            shortcut.combo?.modifiers ?? 0
        }

        init(shortcut: HotkeyShortcut, hotKeyIDValue: UInt32) {
            self.shortcut = shortcut
            self.hotKeyIDValue = hotKeyIDValue
        }

        func setOnHotkey(_ handler: @escaping () -> Void) {
            self.onHotkey = handler
        }

        func start() throws {
            startCount += 1
        }

        func stop() {
            stopCount += 1
        }

        func fire() {
            onHotkey()
        }
    }

    private(set) var created: [FakeMonitor] = []

    var activeStarts: Int {
        created.reduce(0) { $0 + $1.startCount }
    }

    var activeStops: Int {
        created.reduce(0) { $0 + $1.stopCount }
    }

    func make(
        _ shortcut: HotkeyShortcut,
        _ hotKeyIDValue: UInt32
    ) -> UsefulLinksHotkeyControlling {
        let monitor = FakeMonitor(
            shortcut: shortcut,
            hotKeyIDValue: hotKeyIDValue
        )
        created.append(monitor)
        return monitor
    }

    func fireHotkey(keyCode: UInt32) {
        guard let monitor = created.last(where: { $0.keyCode == keyCode && $0.stopCount == 0 }) else {
            XCTFail("no monitor registered for keyCode 0x\(String(keyCode, radix: 16))")
            return
        }
        monitor.fire()
    }
}
