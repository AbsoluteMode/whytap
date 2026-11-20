import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
private final class QuietKeyTap: CaseApprovalKeyIntercepting {
    private var onKey: (@MainActor (CaseApprovalKey) -> Void)?
    private var onUnarmedKeyDown: (@MainActor () -> Void)?
    private var armed = false

    func start(onKey: @escaping @MainActor (CaseApprovalKey) -> Void,
               onUnarmedKeyDown: @escaping @MainActor () -> Void) throws {
        self.onKey = onKey
        self.onUnarmedKeyDown = onUnarmedKeyDown
    }

    func stop() { onKey = nil; onUnarmedKeyDown = nil }
    func setArmed(_ armed: Bool) { self.armed = armed }
    func press(_ key: CaseApprovalKey) { if armed { onKey?(key) } else { onUnarmedKeyDown?() } }
}

@MainActor
private final class ManualClock {
    private var nextID = 0
    private var items: [(id: Int, at: TimeInterval, work: @MainActor () -> Void)] = []
    private var now: TimeInterval = 0

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        items.append((id, now + delay, work))
        return { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = items.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            items.removeAll { $0.id == next.id }
            now = next.at
            next.work()
        }
        now = target
    }
}

/// The island card a person sees right after adding the plugin.
@MainActor
final class HarnessAccessPromptTests: XCTestCase {
    private let claude = HarnessClient(
        identity: HarnessIdentity(teamID: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code"),
        name: "Claude Code")
    private let codex = HarnessClient(
        identity: HarnessIdentity(teamID: "2DC432GLL2", signingIdentifier: "codex"), name: "Codex")
    private var tap: QuietKeyTap!
    private var clock: ManualClock!
    private var controller: CaseApprovalController!

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    override func tearDown() async throws {
        ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        ProviderBrandIconAsset.clearCacheForTesting()
    }

    override func setUp() async throws {
        // The packaged app reads the same files from its bundle.
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(
            Self.repository.appendingPathComponent("Resources/UsefulLinkIcons"))
        tap = QuietKeyTap()
        clock = ManualClock()
        controller = CaseApprovalController(keyTap: tap, schedule: { [clock] in clock!.schedule(after: $0, $1) })
    }

    private func ask(_ client: HarnessClient) -> Task<HarnessAccessOutcome, Never> {
        Task { await self.controller.requestAccess(for: client) }
    }

    private func shown() async {
        while controller.current == nil { await Task.yield() }
    }

    func test_the_card_names_the_harness_and_what_yes_means() {
        XCTAssertEqual(CaseApprovalView.harnessTitle(claude), "Let Claude Code use Whytap?")
        XCTAssertEqual(CaseApprovalView.harnessTitle(codex), "Let Codex use Whytap?")
        XCTAssertTrue(CaseApprovalView.harnessDetail.contains("Case keys keep their own approval"))
        XCTAssertEqual(CaseApprovalView.harnessMark(claude).asset, "claude-code")
        XCTAssertEqual(CaseApprovalView.harnessMark(codex).asset, "codex")
        XCTAssertNotNil(ProviderBrandIconAsset.image(named: "claude-code"))
        XCTAssertNotNil(ProviderBrandIconAsset.image(named: "codex"))
    }

    func test_y_allows_after_the_quiet_keyboard_and_shows_connected_briefly() async {
        let answer = ask(claude)
        await shown()
        XCTAssertEqual(controller.current?.harness, claude)
        XCTAssertFalse(controller.offersTimed, "there is no temporary Yes")

        // The person is typing in their editor: Y does not answer.
        tap.press(.yes)
        XCTAssertNotNil(controller.current)
        clock.advance(by: CaseApprovalController.armingDelay)
        tap.press(.timed)
        XCTAssertNotNil(controller.current, "A is not an answer to this card")
        tap.press(.yes)
        let outcome = await answer.value
        XCTAssertEqual(outcome, .allow)
        XCTAssertNil(controller.current)
        XCTAssertEqual(controller.connected, claude)
        clock.advance(by: CaseApprovalController.connectedDuration)
        XCTAssertNil(controller.connected)
    }

    func test_n_and_escape_refuse_without_a_confirmation() async {
        for key in [CaseApprovalKey.no, .escape] {
            let answer = ask(codex)
            await shown()
            clock.advance(by: CaseApprovalController.armingDelay)
            tap.press(key)
            let outcome = await answer.value
            XCTAssertEqual(outcome, .deny)
            XCTAssertNil(controller.connected)
        }
    }

    func test_an_ignored_card_times_out_and_grants_nothing() async {
        let answer = ask(claude)
        await shown()
        clock.advance(by: CaseApprovalController.timeout)
        let outcome = await answer.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertNil(controller.connected)
    }

    func test_the_next_question_replaces_the_confirmation() async {
        let first = ask(claude)
        await shown()
        let second = ask(codex)
        while controller.pendingCount == 0 { await Task.yield() }
        clock.advance(by: CaseApprovalController.armingDelay)
        tap.press(.yes)
        _ = await first.value
        XCTAssertNil(controller.connected, "Codex's question is on screen instead")
        XCTAssertEqual(controller.current?.harness, codex)
        clock.advance(by: CaseApprovalController.armingDelay)
        tap.press(.yes)
        _ = await second.value
        XCTAssertEqual(controller.connected, codex)
    }

    /// EXODIA_HARNESS_PROMPT_RENDER_DIR=<dir> writes the card's faces as PNG
    /// from a window that is never shown.
    func test_offscreen_render_of_every_face() throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_HARNESS_PROMPT_RENDER_DIR"] else {
            throw XCTSkip("Set EXODIA_HARNESS_PROMPT_RENDER_DIR for offscreen visual proof")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let icon = try XCTUnwrap(NSImage(contentsOf: Self.repository.appendingPathComponent("Resources/AppIcon.icns")))
        func request(_ client: HarnessClient) -> CaseApprovalRequest {
            var request = CaseApprovalRequest(appName: client.name, projectName: "", keyNames: [], command: "", timedMinutes: 0)
            request.harness = client
            return request
        }
        func card(_ client: HarnessClient, width: CGFloat, armed: Bool = true, pending: Int = 0) -> AnyView {
            AnyView(CaseApprovalView(request: request(client), width: width, pendingCount: pending,
                                     isArmed: armed, onChoose: { _ in }, appIcon: icon))
        }
        let faces: [(String, CGFloat, AnyView)] = [
            ("claude-code-312", 312, card(claude, width: 312)),
            ("codex-312", 312, card(codex, width: 312)),
            ("claude-code-arming-312", 312, card(claude, width: 312, armed: false)),
            ("codex-queued-310", 310, card(codex, width: 310, pending: 1)),
            ("claude-code-narrow-260", 260, card(claude, width: 260)),
            ("claude-code-connected-312", 312, AnyView(CaseApprovalConnectedView(client: claude, width: 312))),
            ("codex-connected-312", 312, AnyView(CaseApprovalConnectedView(client: codex, width: 312))),
        ]
        for (name, width, view) in faces {
            // A wallpaper-like backdrop shows the card's own shape and corners.
            let framed = view.padding(.horizontal, 24).padding(.bottom, 24)
                .background(LinearGradient(colors: [Color(white: 0.42), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
            let host = NSHostingView(rootView: framed)
            let size = NSSize(width: width + 48, height: host.fittingSize.height)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            host.layoutSubtreeIfNeeded()
            let scale: CGFloat = 2
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = size
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
            window.contentView = nil
            window.close()
        }
    }
}
