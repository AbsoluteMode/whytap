import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Settings -> Features open while Drop Mode switches in the island (task 96):
/// the switch must not stall the main thread with Keychain reads.
// WHY: .project-docs/decisions/2026-11-28-drop-mode-switch-motion.md
@MainActor
final class SettingsFeaturesKeychainTests: XCTestCase {
    /// Memory keys that count reads and cost what a login Keychain read costs
    /// (about 1.2 ms median, measured on the maintainer's Mac).
    final class SlowKeychain: @unchecked Sendable {
        let box = InMemoryTokenStore.Box()
        var reads = 0
        var readOnMain = 0
        var delay: TimeInterval = 0.0012
        struct Store: TokenStore {
            let owner: SlowKeychain
            let inner: InMemoryTokenStore
            func save(_ token: String) throws { try inner.save(token) }
            func read() throws -> String? {
                owner.reads += 1
                if Thread.isMainThread { owner.readOnMain += 1 }
                Thread.sleep(forTimeInterval: owner.delay)
                return try inner.read()
            }
            func delete() throws { try inner.delete() }
        }
        var keys: ProviderKeyStore { ProviderKeyStore(makeStore: { Store(owner: self, inner: InMemoryTokenStore(account: $0, box: self.box)) }) }
    }

    private func mountFeatures(_ keychain: SlowKeychain) async throws -> (FeaturesFixture, NSView) {
        let keys = keychain.keys
        let fixture = try await FeaturesFixture(.usual, keys: keys)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        for account in [ProviderAccount.soniox, .openRouter, .openAI, .anthropic, .deepgram, .elevenLabs] {
            try keys.save("synthetic-key", account: XCTUnwrap(account.keychainAccount(in: fixture.routing)))
        }
        fixture.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropSmart)
        fixture.routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .dropSmartCleanup)
        let view = SettingsFeaturesView(selection: SettingsWindowSelection(), models: fixture.models,
                                        permissions: fixture.permissions, environment: fixture.environment)
            .frame(width: 900, height: 700)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { await MainActor.run { window.close() } }
        Self.pump(host, seconds: 0.25)
        return (fixture, host)
    }

    /// What the island's switch does in the app: the mode write (a defaults
    /// change) and `sidekeyDropModeChanged`.
    private func switchDropMode(_ fixture: FeaturesFixture) {
        UserPreferencesCache(defaults: fixture.defaults).setMode(.smart)
    }

    func testADropModeSwitchWithFeaturesOpenReadsFewKeysAndKeepsTheMainThreadFree() async throws {
        let keychain = SlowKeychain()
        let (fixture, host) = try await mountFeatures(keychain)
        keychain.reads = 0; keychain.readOnMain = 0

        let (longest, busy) = Self.measure(host) {
            switchDropMode(fixture)
            NotificationCenter.default.post(name: .sidekeyDropModeChanged, object: nil)
        }
        let report = String(format: "Features open, one Drop Mode switch: %d Keychain reads (%d on main), longest main-thread block %.0f ms, blocked %.0f ms in 600 ms",
                            keychain.reads, keychain.readOnMain, longest * 1000, busy * 1000)
        print(report)
        try? report.write(toFile: "/tmp/t96c-features-\(ProcessInfo.processInfo.environment["T96_LABEL"] ?? "x").txt",
                          atomically: true, encoding: .utf8)
        XCTAssertLessThanOrEqual(keychain.readOnMain, 20, "Before the fix: 150 reads and a 243 ms block. " + report)
        XCTAssertLessThan(longest, 0.1, report)
    }

    private static func pump(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// The longest main-thread block and the time blocked over 8 ms, in the
    /// 600 ms after `change`, laying out like display frames.
    private static func measure(_ host: NSView, change: () -> Void) -> (TimeInterval, TimeInterval) {
        let start = CFAbsoluteTimeGetCurrent()
        var last = start, longest = 0.0, busy = 0.0
        change()
        while CFAbsoluteTimeGetCurrent() - start < 0.6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.004))
            let now = CFAbsoluteTimeGetCurrent()
            let gap = now - last
            longest = max(longest, gap)
            if gap > 0.008 { busy += gap }
            last = now
        }
        return (longest, busy)
    }
}
