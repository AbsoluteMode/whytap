import Carbon.HIToolbox
import XCTest
@testable import Sidekey

final class CarbonHotkeyMonitorTests: XCTestCase {
    private static let fakeHotKeyRef: EventHotKeyRef = OpaquePointer(bitPattern: 0xDEAD)!
    private static let fakeHandlerRef: EventHandlerRef = OpaquePointer(bitPattern: 0xBEEF)!

    func testStartRegistersHotKeyWithSlashAndOptionModifier() throws {
        let recorder = SeamRecorder()
        let monitor = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor.start()

        XCTAssertEqual(recorder.registerCalls.count, 1)
        XCTAssertEqual(recorder.registerCalls[0].keyCode, CarbonHotkeyMonitor.slashKeyCode)
        XCTAssertEqual(recorder.registerCalls[0].modifiers, UInt32(optionKey))
    }

    // ROO-208: the old per-mode `⌥1` / `⌥2` / `⌥3` hotkeys were replaced
    // with a single `⌥V` hotkey that opens the unified strip with a
    // sidebar filter. The per-mode `historyMode(forKeyCode:)` resolver
    // and `historyHotkeyRegistrations` table are gone.
    func testUnifiedHistoryHotkeyRegistersOptionV() throws {
        let recorder = SeamRecorder()
        let monitor = CarbonHotkeyMonitor(
            keyCode: CarbonHotkeyMonitor.vKeyCode,
            modifiers: CarbonHotkeyMonitor.optionModifier,
            hotKeyIDValue: CarbonHotkeyMonitor.historyUnifiedHotKeyID,
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor.start()

        XCTAssertEqual(recorder.registerCalls.count, 1)
        XCTAssertEqual(recorder.registerCalls[0].keyCode, CarbonHotkeyMonitor.vKeyCode)
        XCTAssertEqual(recorder.registerCalls[0].modifiers, UInt32(optionKey))
        XCTAssertEqual(recorder.registerCalls[0].hotKeyIDValue, CarbonHotkeyMonitor.historyUnifiedHotKeyID)
        XCTAssertEqual(recorder.registerCalls[0].signature, CarbonHotkeyMonitor.signature)

        monitor.stop()

        XCTAssertEqual(recorder.unregisterCalls, 1)
        XCTAssertEqual(recorder.removeCalls, 1)
    }

    func testStartInstallsEventHandlerBeforeRegistering() throws {
        let recorder = SeamRecorder()
        let monitor = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor.start()

        XCTAssertEqual(recorder.installCalls, 1)
        XCTAssertEqual(recorder.callOrder, ["install", "register"])
    }

    func testStartThrowsWhenRegisterFails() {
        let recorder = SeamRecorder()
        recorder.registerReturn = OSStatus(-1)

        let monitor = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        XCTAssertThrowsError(try monitor.start()) { error in
            guard case VEError.hotkeyFailed(let message) = error else {
                XCTFail("expected VEError.hotkeyFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("RegisterEventHotKey"))
        }

        XCTAssertEqual(recorder.removeCalls, 1, "handler must be cleaned up when register fails")
    }

    func testStartThrowsWhenInstallHandlerFailsAndDoesNotRegister() {
        let recorder = SeamRecorder()
        recorder.installReturn = OSStatus(-1)

        let monitor = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        XCTAssertThrowsError(try monitor.start()) { error in
            guard case VEError.hotkeyFailed(let message) = error else {
                XCTFail("expected VEError.hotkeyFailed, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("InstallEventHandler"))
        }

        XCTAssertEqual(recorder.registerCalls.count, 0)
    }

    func testStopUnregistersAndRemovesHandler() throws {
        let recorder = SeamRecorder()
        let monitor = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor.start()
        monitor.stop()

        XCTAssertEqual(recorder.unregisterCalls, 1)
        XCTAssertEqual(recorder.removeCalls, 1)
    }

    func testStopIsIdempotent() throws {
        let recorder = SeamRecorder()
        let monitor = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor.start()
        monitor.stop()
        monitor.stop()
        monitor.stop()

        XCTAssertEqual(recorder.unregisterCalls, 1)
        XCTAssertEqual(recorder.removeCalls, 1)
    }

    func testStartCallsStopFirstSoSecondStartReregisters() throws {
        let recorder = SeamRecorder()
        let monitor = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor.start()
        try monitor.start()

        XCTAssertEqual(recorder.registerCalls.count, 2)
        XCTAssertEqual(recorder.unregisterCalls, 1, "second start must unregister the first registration")
        XCTAssertEqual(recorder.installCalls, 2)
        XCTAssertEqual(recorder.removeCalls, 1)
    }

    func testDeinitCallsStop() throws {
        let recorder = SeamRecorder()
        var monitor: CarbonHotkeyMonitor? = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor?.start()
        monitor = nil

        XCTAssertEqual(recorder.unregisterCalls, 1)
        XCTAssertEqual(recorder.removeCalls, 1)
    }

    func testHandleHotKeyEventDispatchesOnHotkey() throws {
        let recorder = SeamRecorder()
        var fireCount = 0
        let monitor = CarbonHotkeyMonitor(
            onHotkey: { fireCount += 1 },
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor.start()
        monitor.handleHotKeyEvent()
        monitor.handleHotKeyEvent()

        XCTAssertEqual(fireCount, 2)
    }

    func testHandleHotKeyReleaseEventDispatchesReleaseCallbackOnly() throws {
        let recorder = SeamRecorder()
        var pressCount = 0
        var releaseCount = 0
        let monitor = CarbonHotkeyMonitor(
            onHotkey: { pressCount += 1 },
            onHotkeyReleased: { releaseCount += 1 },
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { $0() }
        )

        try monitor.start()
        monitor.handleHotKeyReleaseEvent()

        XCTAssertEqual(pressCount, 0)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertEqual(recorder.installedEventKinds, [
            UInt32(kEventHotKeyPressed),
            UInt32(kEventHotKeyReleased)
        ])
    }

    // MARK: - Stage 4 suppression gate

    /// Stage 4 contract: when `shouldSuppress` returns `true`, the
    /// callback must NOT fire AND the dispatch seam must NOT run. The
    /// real wiring plugs this to `AppState.shared.isMeetingRecording` so
    /// Option+/ silently drops while a meeting recorder owns the mic;
    /// this test pins the gate without depending on AppState.
    func testOptionSlashSkippedWhenMeetingRecordingActive() throws {
        let recorder = SeamRecorder()
        var dispatchCount = 0
        var fireCount = 0
        let monitor = CarbonHotkeyMonitor(
            onHotkey: { fireCount += 1 },
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { work in
                dispatchCount += 1
                work()
            },
            shouldSuppress: { true }  // simulate isMeetingRecording == true
        )

        try monitor.start()
        monitor.handleHotKeyEvent()
        monitor.handleHotKeyEvent()

        XCTAssertEqual(fireCount, 0,
                       "onHotkey callback must NOT fire while suppression gate is true")
        XCTAssertEqual(dispatchCount, 0,
                       "dispatchOnMain must NOT run when the hotkey is suppressed")
    }

    func testHandleHotKeyEventGoesThroughDispatchOnMainSeam() throws {
        let recorder = SeamRecorder()
        var dispatchCount = 0
        let monitor = CarbonHotkeyMonitor(
            onHotkey: {},
            registerHotKey: recorder.register(slot: Self.fakeHotKeyRef),
            unregisterHotKey: recorder.unregister(),
            installHandler: recorder.install(slot: Self.fakeHandlerRef),
            removeHandler: recorder.remove(),
            dispatchOnMain: { work in
                dispatchCount += 1
                work()
            }
        )

        try monitor.start()
        monitor.handleHotKeyEvent()

        XCTAssertEqual(dispatchCount, 1)
    }
}

// MARK: - Seam recorder

/// Captures seam calls so tests can assert on order, arguments, and counts.
/// The C/Carbon types are kept as raw arguments so test code does not depend
/// on the production class internals.
private final class SeamRecorder {
    struct RegisterCall: Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let signature: OSType
        let hotKeyIDValue: UInt32
    }

    var registerCalls: [RegisterCall] = []
    var installCalls = 0
    var unregisterCalls = 0
    var removeCalls = 0
    var callOrder: [String] = []
    var installedEventKinds: [UInt32] = []

    var registerReturn: OSStatus = noErr
    var installReturn: OSStatus = noErr

    func register(slot: EventHotKeyRef) -> CarbonHotkeyMonitor.RegisterHotKey {
        return { [weak self] keyCode, modifiers, hotKeyID, _, _, refPtr in
            guard let self else { return OSStatus(-1) }
            self.registerCalls.append(RegisterCall(
                keyCode: keyCode,
                modifiers: modifiers,
                signature: hotKeyID.signature,
                hotKeyIDValue: hotKeyID.id
            ))
            self.callOrder.append("register")
            if self.registerReturn == noErr {
                refPtr?.pointee = slot
            }
            return self.registerReturn
        }
    }

    func unregister() -> CarbonHotkeyMonitor.UnregisterHotKey {
        return { [weak self] _ in
            self?.unregisterCalls += 1
            self?.callOrder.append("unregister")
            return noErr
        }
    }

    func install(slot: EventHandlerRef) -> CarbonHotkeyMonitor.InstallHandler {
        return { [weak self] _, _, count, eventTypes, _, refPtr in
            guard let self else { return OSStatus(-1) }
            self.installCalls += 1
            self.installedEventKinds = (0..<count).compactMap { index in
                eventTypes?[index].eventKind
            }
            self.callOrder.append("install")
            if self.installReturn == noErr {
                refPtr?.pointee = slot
            }
            return self.installReturn
        }
    }

    func remove() -> CarbonHotkeyMonitor.RemoveHandler {
        return { [weak self] _ in
            self?.removeCalls += 1
            self?.callOrder.append("remove")
            return noErr
        }
    }
}
