import Combine
import Darwin
import WhytapCaseKit
import XCTest
@testable import Sidekey

private final class Processes: CaseProcessInspecting {
    var table: [pid_t: CaseProcessInfo] = [:]

    func add(_ pid: pid_t, parent: pid_t, team: String? = nil, id: String? = nil) {
        table[pid] = CaseProcessInfo(
            pid: pid, parentPID: parent, executablePath: "/bin/p\(pid)", teamID: team, signingIdentifier: id)
    }

    func info(pid: pid_t) -> CaseProcessInfo? { table[pid] }
    func peer(of socket: Int32) -> (pid: pid_t, auditToken: audit_token_t)? { nil }
    func isTrustedHelper(auditToken: audit_token_t, helperURL: URL) -> Bool { false }
}

@MainActor
private final class Answer: HarnessAccessPresenting {
    var outcome: HarnessAccessOutcome = .allow
    private(set) var asked: [HarnessClient] = []

    func requestAccess(for client: HarnessClient) async -> HarnessAccessOutcome {
        asked.append(client)
        return outcome
    }
}

/// Maxim dictates into Whycode's input: Whycode reads the live take, the
/// island's wing stays quiet. Nobody else gets the words.
@MainActor
final class DropLiveTests: XCTestCase {
    private let whycodePID: pid_t = 510
    private let whycodeHelper: pid_t = 910
    private let claudePID: pid_t = 500
    private let claudeHelper: pid_t = 900
    private let slackPID: pid_t = 777

    private var processes: Processes!
    private var prompt: Answer!
    private var store: HarnessAccessStore!
    private var feed: DropLiveFeed!
    private var gate: HarnessAccessGate!
    private var clock: TimeInterval = 100
    private var phase = "idle"
    private var level: Float? = 0.4
    private var meetingsRead = 0

    override func setUp() async throws {
        processes = Processes()
        processes.add(claudePID, parent: 1, team: "Q6L2SF6YDW", id: "com.anthropic.claude-code")
        processes.add(claudeHelper, parent: claudePID)
        processes.add(whycodePID, parent: 1, team: "UVBKCN5PPV", id: "com.rootwise.whycode")
        processes.add(whycodeHelper, parent: whycodePID)
        prompt = Answer()
        store = HarnessAccessStore(persistence: nil)
        feed = DropLiveFeed(uptime: { [unowned self] in clock }, phase: { [unowned self] in phase },
                            level: { [unowned self] in level }, energy: { $0 / 2 })
        gate = HarnessAccessGate(resolver: HarnessCallerResolver(inspector: processes), store: store,
                                 presenter: prompt, dropLive: feed)
    }

    private func live(_ shows: Bool? = true, from helper: pid_t? = nil) async -> AppControlResponse {
        let args: [String: AppControlValue] = shows.map { ["showsLiveText": .bool($0)] } ?? [:]
        return await gate.handle(AppControlRequest("drop_live", arguments: args), peerPID: helper ?? whycodeHelper) { _ in
            XCTFail("drop_live never reaches the application controls")
            return .failure("unknown_operation", "")
        }
    }

    private func call(_ operation: String, from helper: pid_t) async -> AppControlResponse {
        await gate.handle(AppControlRequest(operation), peerPID: helper) { [unowned self] _ in
            meetingsRead += 1
            return .success(.object(["meetings": .array([])]))
        }
    }

    private func code(_ response: AppControlResponse) -> String? { response.data.object?["code"]?.string }
    private func field(_ response: AppControlResponse, _ key: String) -> AppControlValue? { response.data.object?[key] }

    /// Starts a take into `target` and lets the provider send words.
    @discardableResult
    private func dictate(into target: pid_t?, _ words: String...) -> String {
        let take = feed.beginTake(target: target)
        phase = "recording"
        for text in words { feed.partial(text, take: take) }
        return take
    }

    // MARK: Who may read the live take

    func test_signed_whycode_is_a_live_dictation_client_and_nothing_more() {
        let resolver = HarnessCallerResolver(inspector: processes)
        let client = resolver.client(peerPID: whycodeHelper)
        XCTAssertEqual(client?.name, "Whycode")
        XCTAssertEqual(client?.scope, .liveDictation)
        XCTAssertEqual(resolver.clientProcess(peerPID: whycodeHelper), whycodePID)
        XCTAssertEqual(resolver.client(peerPID: claudeHelper)?.scope, .harness)
    }

    func test_an_ad_hoc_or_foreign_whycode_build_is_nobody() async {
        // Ad-hoc signed: no Team ID that Apple vouches for.
        processes.add(520, parent: 1, team: nil, id: "com.rootwise.whycode")
        processes.add(920, parent: 520)
        // Someone else's certificate with Whycode's identifier.
        processes.add(530, parent: 1, team: "ABCDE12345", id: "com.rootwise.whycode")
        processes.add(930, parent: 530)
        // A script in Whycode's terminal: Whycode -> zsh -> helper.
        processes.add(540, parent: whycodePID)
        processes.add(940, parent: 540)
        dictate(into: 520, "secret words")
        for helper: pid_t in [920, 930, 940] {
            let response = await live(from: helper)
            XCTAssertEqual(code(response), "unsupported_client", "\(helper)")
            XCTAssertFalse(String(describing: response).contains("secret"))
        }
        XCTAssertTrue(prompt.asked.isEmpty)
        XCTAssertFalse(feed.suppressesWing)
    }

    func test_whycodes_yes_opens_no_meetings_or_dictation_lists() async {
        let first = await live()
        XCTAssertTrue(first.ok)
        XCTAssertEqual(prompt.asked.map(\.name), ["Whycode"])
        for operation in HarnessAccessGate.gatedOperations.sorted() {
            let response = await call(operation, from: whycodeHelper)
            XCTAssertEqual(code(response), "unsupported_client", operation)
        }
        XCTAssertEqual(meetingsRead, 0)
        XCTAssertEqual(prompt.asked.count, 1, "no second prompt for tools it can never have")
    }

    func test_coding_harnesses_never_get_the_live_take() async {
        _ = await call("meetings_search", from: claudeHelper)
        XCTAssertEqual(store.decision(for: HarnessIdentity(teamID: "Q6L2SF6YDW", signingIdentifier: "com.anthropic.claude-code")), .allow)
        dictate(into: claudePID, "hello")
        let response = await live(from: claudeHelper)
        XCTAssertEqual(code(response), "unsupported_client")
        XCTAssertFalse(feed.suppressesWing)
    }

    func test_whycode_is_asked_once_and_no_is_kept() async {
        prompt.outcome = .deny
        let first = await live()
        let second = await live()
        XCTAssertEqual(code(first), "access_denied")
        XCTAssertEqual(code(second), "access_denied")
        XCTAssertEqual(prompt.asked.count, 1)
        dictate(into: whycodePID, "hello")
        _ = await live()
        XCTAssertFalse(feed.suppressesWing, "a refused client cannot quiet the wing")
    }

    func test_connecting_whycode_shows_the_prompt_like_a_harness() async {
        let status = await gate.intercept(AppControlRequest(HarnessAccessGate.requestOperation), peerPID: whycodeHelper)
        XCTAssertEqual(status?.data.object?["client"], .string("Whycode"))
        while prompt.asked.isEmpty { await Task.yield() }
        XCTAssertEqual(prompt.asked.first?.scope, .liveDictation)
    }

    // MARK: What it reads

    func test_a_take_into_whycode_carries_its_words_level_and_energy() async {
        dictate(into: whycodePID, "привет", "привет мир")
        let response = await live()
        XCTAssertTrue(response.ok)
        XCTAssertEqual(field(response, "phase"), .string("recording"))
        XCTAssertEqual(field(response, "toCaller"), .bool(true))
        XCTAssertEqual(field(response, "text"), .string("привет мир"))
        XCTAssertEqual(field(response, "takeId")?.string, feed.takeID)
        XCTAssertEqual(field(response, "level")?.double ?? 0, 0.4, accuracy: 0.0005)
        XCTAssertEqual(field(response, "energy")?.double ?? 0, 0.2, accuracy: 0.0005)
    }

    func test_a_take_into_another_app_gives_whycode_no_words() async {
        dictate(into: slackPID, "a private message")
        let response = await live()
        XCTAssertEqual(field(response, "toCaller"), .bool(false))
        XCTAssertEqual(field(response, "text"), .string(""))
        XCTAssertEqual(field(response, "phase"), .string("recording"))
        // A take into one of Whytap's own editors has no target at all.
        dictate(into: nil, "a translation")
        let editor = await live()
        XCTAssertEqual(field(editor, "text"), .string(""))
    }

    func test_after_the_take_the_words_are_gone_and_a_new_take_has_a_new_id() async {
        dictate(into: whycodePID, "first take")
        let firstID = feed.takeID
        phase = "idle"
        let idle = await live()
        XCTAssertEqual(field(idle, "text"), .string(""))
        XCTAssertEqual(field(idle, "toCaller"), .bool(false))
        XCTAssertEqual(field(idle, "energy")?.double ?? -1, 0, accuracy: 0.0005)

        dictate(into: whycodePID)
        let next = await live()
        XCTAssertNotEqual(field(next, "takeId")?.string, firstID)
        XCTAssertEqual(field(next, "text"), .string(""), "nothing carried over from the last take")
    }

    func test_a_blank_partial_keeps_the_words_like_the_wing() async {
        dictate(into: whycodePID, "one two", "  ", "")
        let response = await live()
        XCTAssertEqual(field(response, "text"), .string("one two"))
    }

    func test_unknown_or_mistyped_arguments_are_refused() async {
        for args: [String: AppControlValue] in [["showsLiveText": .string("yes")], ["text": .string("x")]] {
            let response = await gate.handle(AppControlRequest("drop_live", arguments: args), peerPID: whycodeHelper) { _ in
                .success(.null)
            }
            XCTAssertEqual(code(response), "invalid_arguments")
        }
        let none = await live(nil)
        XCTAssertTrue(none.ok, "showsLiveText is optional")
    }

    // MARK: Takes end, fail and overlap

    func test_a_failed_or_parked_take_shows_no_words() async {
        dictate(into: whycodePID, "half a sentence")
        phase = "deliveryFailed"
        let failed = await live()
        XCTAssertEqual(field(failed, "toCaller"), .bool(false))
        XCTAssertEqual(field(failed, "text"), .string(""))
        XCTAssertEqual(field(failed, "energy")?.double ?? -1, 0, accuracy: 0.0005)
    }

    func test_the_end_of_a_take_drops_its_words_and_late_partials() async {
        let take = dictate(into: whycodePID, "first words")
        feed.endTake()
        feed.partial("arrived after the end", take: take)
        let ended = await live()
        XCTAssertEqual(field(ended, "text"), .string(""))
        XCTAssertEqual(field(ended, "toCaller"), .bool(false))
        XCTAssertFalse(feed.suppressesWing)
    }

    func test_a_partial_from_a_cancelled_take_never_reaches_the_next_one() async {
        let old = dictate(into: whycodePID, "old take")
        dictate(into: whycodePID, "new take")
        // The cancelled session's on-device decode returns late.
        feed.partial("old take finished decoding", take: old)
        let response = await live()
        XCTAssertEqual(field(response, "text"), .string("new take"))
    }

    func test_a_long_on_device_take_keeps_its_start() async {
        let take = feed.beginTake(target: whycodePID)
        phase = "recording"
        // Under 14 s every window is the whole take; then it starts sliding.
        feed.partial("one two three four", take: take)
        feed.partial("one two three four five six", take: take)
        feed.partial("three four five six seven eight", take: take, shifted: true)
        feed.partial("Five, six seven eight nine ten", take: take, shifted: true)
        let response = await live()
        XCTAssertEqual(field(response, "text"), .string("one two three four Five, six seven eight nine ten"))
    }

    func test_a_short_on_device_take_is_shown_as_decoded() async {
        let take = feed.beginTake(target: whycodePID)
        phase = "recording"
        // Growing, then the leading word revised: whole-take frames replace.
        for frame in ["hello", "hello world", "Hallo world again"] { feed.partial(frame, take: take) }
        let spaced = await live()
        XCTAssertEqual(field(spaced, "text"), .string("Hallo world again"))
        // A language written without spaces.
        let japanese = feed.beginTake(target: whycodePID)
        for frame in ["こんにちは", "こんにちは世界", "今日は世界です"] { feed.partial(frame, take: japanese) }
        let unspaced = await live()
        XCTAssertEqual(field(unspaced, "text"), .string("今日は世界です"))
    }

    func test_a_long_take_without_spaces_keeps_its_start() async {
        let take = feed.beginTake(target: whycodePID)
        phase = "recording"
        feed.partial("きょうはかいぎでしんきのけいかくをはなしました", take: take)
        feed.partial("しんきのけいかくをはなしましたあしたまでに", take: take, shifted: true)
        let response = await live()
        XCTAssertEqual(field(response, "text"), .string("きょうはかいぎでしんきのけいかくをはなしましたあしたまでに"))
    }

    func test_after_the_watchdog_a_retry_shows_no_old_words() async {
        // The diagnostic watchdog dropped the trace, so no endDropTurn ends
        // the take; the take then parks for Retry and comes back to finishing.
        let phases = PassthroughSubject<String, Never>()
        feed.endTakes(on: phases.eraseToAnyPublisher())
        dictate(into: whycodePID, "words before the stall")
        phase = "deliveryFailed"
        phases.send("deliveryFailed")
        phase = "finishing"
        phases.send("finishing")
        let retry = await live()
        XCTAssertEqual(field(retry, "text"), .string(""))
        XCTAssertEqual(field(retry, "toCaller"), .bool(false))
    }

    func test_a_cloud_take_is_cumulative_and_not_stitched() async {
        dictate(into: whycodePID, "one two three", "one two three four", "one too three four five")
        let response = await live()
        XCTAssertEqual(field(response, "text"), .string("one too three four five"), "the provider's revision wins")
    }

    func test_stitching_windows() {
        XCTAssertEqual(DropLiveFeed.stitch(shown: "", window: " hello "), "hello")
        XCTAssertEqual(DropLiveFeed.stitch(shown: "a b c d", window: "   "), "a b c d")
        // The tail was revised by the re-decode.
        XCTAssertEqual(DropLiveFeed.stitch(shown: "we met on monday to plan the reelase", window: "on monday to plan the release today"),
                       "we met on monday to plan the release today")
        // A phrase said twice: the later, longer run is where the window starts.
        XCTAssertEqual(DropLiveFeed.stitch(shown: "go to the store then go to the bank", window: "go to the bank and home"),
                       "go to the store then go to the bank and home")
        // Nothing in common: the start of the take is kept.
        XCTAssertEqual(DropLiveFeed.stitch(shown: "alpha beta gamma", window: "delta epsilon zeta"), "alpha beta gamma delta epsilon zeta")
        // Punctuation-only tokens do not count as words.
        XCTAssertEqual(DropLiveFeed.stitch(shown: "so — we start now and then", window: "we start now and then stop"),
                       "so — we start now and then stop")
    }

    // MARK: What the user is asked and shown

    func test_whycode_is_asked_about_its_dictation_not_about_meetings() {
        let whycode = HarnessCallerResolver(inspector: processes).client(peerPID: whycodeHelper)!
        XCTAssertEqual(CaseApprovalView.harnessTitle(whycode), "Let Whycode show your dictation?")
        let detail = CaseApprovalView.harnessDetail(for: whycode)
        XCTAssertTrue(detail.contains("While you dictate into Whycode"))
        XCTAssertTrue(detail.contains("no meetings"))
        XCTAssertFalse(detail.contains("read your meetings"))
        let claude = HarnessCallerResolver(inspector: processes).client(peerPID: claudeHelper)!
        XCTAssertEqual(CaseApprovalView.harnessDetail(for: claude), CaseApprovalView.harnessDetail)

        let allowed = HarnessAccessSettingsSection.subtitle(.allow, identity: whycode.identity)
        XCTAssertTrue(allowed.contains("while you dictate into Whycode"))
        XCTAssertFalse(allowed.contains("Reads your meetings"))
        XCTAssertFalse(HarnessAccessSettingsSection.subtitle(.deny, identity: whycode.identity).contains("Not allowed to use Whytap"))
        XCTAssertTrue(HarnessAccessSettingsSection.subtitle(.allow, identity: claude.identity).contains("Reads your meetings"))
    }

    // MARK: The island's wing

    func test_the_wing_is_quiet_only_while_whycode_shows_its_own_take() async {
        dictate(into: whycodePID, "hello")
        XCTAssertFalse(feed.suppressesWing, "no opt-in yet: the wing behaves as today")
        _ = await live(true)
        XCTAssertTrue(feed.suppressesWing)
        _ = await live(false)
        XCTAssertFalse(feed.suppressesWing, "the composer lost focus")
    }

    func test_the_opt_in_lapses_when_whycode_stops_asking() async {
        dictate(into: whycodePID, "hello")
        _ = await live(true)
        clock += DropLiveFeed.optInDuration - 0.1
        XCTAssertTrue(feed.suppressesWing)
        clock += 0.2
        XCTAssertFalse(feed.suppressesWing, "Whycode quit or hung: the wing is back")
    }

    func test_a_take_into_another_app_always_reaches_the_wing() async {
        dictate(into: slackPID, "hello")
        _ = await live(true)
        XCTAssertFalse(feed.suppressesWing)
        // Whycode keeps polling while the next take goes to Slack.
        dictate(into: whycodePID, "mine")
        _ = await live(true)
        XCTAssertTrue(feed.suppressesWing)
        dictate(into: slackPID, "theirs")
        XCTAssertFalse(feed.suppressesWing)
        phase = "idle"
        dictate(into: whycodePID)
        phase = "idle"
        XCTAssertFalse(feed.suppressesWing, "nothing to suppress between takes")
    }

    func test_access_turned_off_mid_call_returns_nothing() async {
        _ = await live()
        dictate(into: whycodePID, "hello")
        let client = HarnessCallerResolver(inspector: processes).client(peerPID: whycodeHelper)!
        _ = store.record(.deny, for: client, at: Date())
        let response = await live()
        XCTAssertEqual(code(response), "access_denied")
        XCTAssertFalse(String(describing: response).contains("hello"))
    }

    // MARK: Outside the gate

    func test_the_application_controls_alone_do_not_know_drop_live() async {
        // The built-in Agent and any path without the gate reach the controller.
        let controls = AppControlController(activity: { .object([:]) })
        let response = await controls.handle(AppControlRequest("drop_live"))
        XCTAssertEqual(code(response), "unknown_operation")
    }

    func test_the_orb_energy_matches_the_island_orb_before_smoothing() {
        let normalize: (Float) -> Float = { ($0 - 0.05) / 0.5 }
        XCTAssertEqual(VoiceOrbView.voiceEnergy(raw: 0.05, floor: 0.04, normalize: normalize), 0)
        XCTAssertEqual(VoiceOrbView.voiceEnergy(raw: 0.30, floor: 0.04, normalize: normalize), 0.5, accuracy: 0.0001)
        // The gate never drops below 0.02 or rises above 0.1.
        XCTAssertEqual(VoiceOrbView.voiceEnergy(raw: 0.09, floor: 0.5, normalize: normalize), 0)
        XCTAssertGreaterThan(VoiceOrbView.voiceEnergy(raw: 0.11, floor: 0.5, normalize: normalize), 0)
    }
}
