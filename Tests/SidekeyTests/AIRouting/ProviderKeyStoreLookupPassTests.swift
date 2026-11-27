import XCTest
@testable import Sidekey

/// One Keychain read per account within a pass; nothing remembered outside it.
// WHY: .project-docs/decisions/2026-11-28-drop-mode-switch-motion.md
final class ProviderKeyStoreLookupPassTests: XCTestCase {
    private final class Counting: TokenStore, @unchecked Sendable {
        let inner: InMemoryTokenStore
        var reads: Int { counter.value }
        let counter: Box
        final class Box: @unchecked Sendable { var value = 0 }
        init(_ inner: InMemoryTokenStore, _ counter: Box) { self.inner = inner; self.counter = counter }
        func save(_ token: String) throws { try inner.save(token) }
        func read() throws -> String? { counter.value += 1; return try inner.read() }
        func delete() throws { try inner.delete() }
    }

    private let box = InMemoryTokenStore.Box()
    private let reads = Counting.Box()
    private var store: ProviderKeyStore {
        ProviderKeyStore(makeStore: { [box, reads] in Counting(InMemoryTokenStore(account: $0, box: box), reads) })
    }

    func testAPassReadsEachAccountOnceAndCopiesShareIt() throws {
        let keys = store
        try keys.save("one", account: "a")
        let copy = keys
        keys.withLookupPass {
            XCTAssertEqual(keys.lookup(account: "a"), .key("one"))
            XCTAssertEqual(copy.lookup(account: "a"), .key("one"))
            XCTAssertEqual(keys.lookup(account: "b"), .absent)
            XCTAssertEqual(copy.lookup(account: "b"), .absent)
        }
        XCTAssertEqual(reads.value, 2)
    }

    func testOutsideAPassEveryLookupReadsAndNothingIsKept() throws {
        let keys = store
        try keys.save("one", account: "a")
        keys.withLookupPass { _ = keys.lookup(account: "a") }
        try InMemoryTokenStore(account: "a", box: box).save("changed elsewhere")
        XCTAssertEqual(keys.lookup(account: "a"), .key("changed elsewhere"), "The pass ended: a new read")
        _ = keys.lookup(account: "a")
        XCTAssertEqual(reads.value, 3)
    }

    func testSaveAndDeleteInsideAPassAreSeenAndNestedPassesShareAnswers() throws {
        let keys = store
        keys.withLookupPass {
            XCTAssertEqual(keys.lookup(account: "a"), .absent)
            try? keys.save("new", account: "a")
            XCTAssertEqual(keys.lookup(account: "a"), .key("new"))
            keys.withLookupPass { XCTAssertEqual(keys.lookup(account: "a"), .key("new")) }
            XCTAssertEqual(keys.lookup(account: "a"), .key("new"), "The inner pass did not clear the outer one")
            try? keys.delete(account: "a")
            XCTAssertEqual(keys.lookup(account: "a"), .absent)
        }
        XCTAssertEqual(reads.value, 3)
    }
}
