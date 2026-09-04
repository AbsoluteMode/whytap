import Foundation
import XCTest
@testable import Sidekey

/// Stage 5b eviction contract: an `evict()` clears a store's cached model so
/// the NEXT load re-loads from scratch. Real model stores cache a 2.3 GB Core
/// ML / MLX instance that cannot be fabricated in a unit test, so the
/// cache-clearing semantics are asserted on a faithful in-memory fake that
/// mirrors the real stores' "cache on load, drop on evict" shape (the exact
/// pattern `LocalLLMModelStore` / `LocalDiarizerModelStore` /
/// `LocalTranscriptionModelStore` implement). The real stores' conformance to
/// the `MeetingLocalModelEvicting` seam is locked at the bottom.
final class MeetingLocalModelEvictionTests: XCTestCase {

    /// Mirrors the real stores: `load()` returns the cached instance when warm
    /// and re-creates (incrementing `loadCount`) when cold; `evict()` drops the
    /// cache so the next `load()` is cold again.
    private actor FakeCachingStore: MeetingLocalModelEvicting {
        private var cached: Int?
        private(set) var loadCount = 0

        func load() -> Int {
            if let cached { return cached }
            loadCount += 1
            let instance = loadCount
            cached = instance
            return instance
        }

        func evict() async {
            cached = nil
        }

        func loads() -> Int { loadCount }
    }

    func test_evictClearsCacheSoNextLoadReloads() async {
        let store = FakeCachingStore()

        _ = await store.load()                 // cold → load #1
        _ = await store.load()                 // warm → cached, no reload
        let loadsAfterWarm = await store.loads()
        XCTAssertEqual(loadsAfterWarm, 1, "second load must hit the cache")

        await store.evict()

        _ = await store.load()                 // cold again → load #2
        let loadsAfterEvict = await store.loads()
        XCTAssertEqual(loadsAfterEvict, 2, "load after evict must re-load")
    }

    func test_evictIsIdempotentOnColdCache() async {
        let store = FakeCachingStore()
        // Evicting an already-cold cache is a harmless no-op (the serial
        // pipeline may evict a store whose model was never loaded).
        await store.evict()
        await store.evict()
        _ = await store.load()
        let loads = await store.loads()
        XCTAssertEqual(loads, 1)
    }

    func test_realStoresConformToEvictionSeam() async {
        // Compile-time + runtime: the three shared stores are usable as the
        // eviction seam the processor serialises, and evicting an empty cache
        // never throws.
        let stores: [any MeetingLocalModelEvicting] = [
            LocalTranscriptionModelStore.shared,
            LocalDiarizerModelStore.shared,
            LocalLLMModelStore.shared,
        ]
        for store in stores {
            await store.evict()
        }
    }
}
