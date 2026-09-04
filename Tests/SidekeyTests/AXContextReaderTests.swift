import XCTest
@testable import Sidekey

final class AXContextReaderTests: XCTestCase {
    // MARK: - assemble (pure)

    func test_assemble_returns_nil_for_no_fragments() {
        XCTAssertNil(AXContextReader.assemble([], limit: 2000))
    }

    func test_assemble_returns_nil_when_all_fragments_are_blank() {
        XCTAssertNil(AXContextReader.assemble(["", "   ", "\n\t"], limit: 2000))
    }

    func test_assemble_trims_and_joins_fragments_with_newlines() {
        XCTAssertEqual(
            AXContextReader.assemble(["  hello ", "world  "], limit: 2000),
            "hello\nworld"
        )
    }

    func test_assemble_drops_exact_duplicate_fragments_keeping_first() {
        XCTAssertEqual(
            AXContextReader.assemble(["alpha", "beta", "alpha"], limit: 2000),
            "alpha\nbeta"
        )
    }

    func test_assemble_truncates_to_character_limit() {
        // "12345\n67890" is 11 chars; a limit of 5 keeps only the first fragment.
        XCTAssertEqual(
            AXContextReader.assemble(["12345", "67890"], limit: 5),
            "12345"
        )
    }

    // MARK: - context(for:) with an injected collector

    func test_context_assembles_text_from_injected_collector() {
        let reader = AXContextReader(maxCharacters: 2000, collectFragments: { _ in ["alpha", "beta"] })
        XCTAssertEqual(reader.context(for: 4242), "alpha\nbeta")
    }

    func test_context_is_nil_when_collector_returns_nothing() {
        let reader = AXContextReader(maxCharacters: 2000, collectFragments: { _ in [] })
        XCTAssertNil(reader.context(for: 4242))
    }

    func test_context_passes_the_pid_through_to_the_collector() {
        var seenPID: pid_t?
        let reader = AXContextReader(maxCharacters: 2000, collectFragments: { pid in
            seenPID = pid
            return ["x"]
        })
        _ = reader.context(for: 777)
        XCTAssertEqual(seenPID, 777)
    }

    // MARK: - snapshot(forPID:)

    func test_snapshot_returns_nil_for_a_nil_pid() async {
        let result = await AXContextReader.snapshot(forPID: nil)
        XCTAssertNil(result)
    }

    func test_snapshot_abandons_context_when_the_walk_exceeds_the_timeout() async {
        // A target app that answers Accessibility slowly must NOT stall the
        // drop: the per-message 0.5s timeout × 600-node budget bounds the walk
        // only at minutes, so the island can sit on "thinking…" for ~55s while
        // the (already-resolved) transcript waits to be pasted. The snapshot
        // must abandon the best-effort context once the wall-clock timeout
        // elapses and let the paste proceed without it.
        let started = ContinuousClock.now
        let result = await AXContextReader.snapshot(
            forPID: 4242,
            timeout: .milliseconds(100),
            collect: { _ in
                // Simulate a sluggish AX tree that, like `liveCollect`, checks
                // for cancellation as it descends. The real walk bails per node
                // on `Task.isCancelled`; mirror that so the test exercises the
                // production cancel path, not an un-cancellable sleep. Cancelled
                // before it gathered anything → no fragments.
                while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.02) }
                return []
            }
        )
        let elapsed = ContinuousClock.now - started
        XCTAssertNil(result)
        XCTAssertLessThan(
            elapsed, .seconds(1),
            "snapshot must return on the timeout, not wait out the slow AX walk"
        )
    }

    func test_snapshot_returns_context_when_the_walk_finishes_before_timeout() async {
        // The fast path (the common case: apps that answer AX quickly) is
        // unaffected — the timeout is a ceiling, not a delay.
        let result = await AXContextReader.snapshot(
            forPID: 4242,
            timeout: .seconds(5),
            collect: { _ in ["alpha", "beta"] }
        )
        XCTAssertEqual(result, "alpha\nbeta")
    }
}
