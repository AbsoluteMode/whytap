import XCTest
@testable import Sidekey

final class CaseRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test_recently_used_key_beats_old_high_copy_key() {
        let old = secret(name: "OLD_PROJECT_KEY", copyCount: 200, lastCopiedDaysAgo: 120, createdDaysAgo: 200)
        let recent = secret(name: "CURRENT_PROJECT_KEY", copyCount: 3, lastCopiedDaysAgo: 1, createdDaysAgo: 2)

        let sorted = CaseRanker.sortedEntries(secrets: [old, recent], groups: [], query: "", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["CURRENT_PROJECT_KEY", "OLD_PROJECT_KEY"])
    }

    func test_new_key_gets_short_lived_boost() {
        let new = secret(name: "NEW_TOKEN", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 0.5)
        let unusedOld = secret(name: "OLD_UNUSED", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 90)

        let sorted = CaseRanker.sortedEntries(secrets: [unusedOld, new], groups: [], query: "", now: now)

        XCTAssertEqual(sorted.first?.displayName, "NEW_TOKEN")
    }

    func test_search_exact_and_prefix_matches_outrank_plain_score() {
        let veryPopular = secret(name: "STRIPE_PROD", copyCount: 50, lastCopiedDaysAgo: 1, createdDaysAgo: 30)
        let exact = secret(name: "GITHUB_TOKEN", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)
        let prefix = secret(name: "GITHUB_BACKUP", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)

        let sorted = CaseRanker.sortedEntries(secrets: [veryPopular, prefix, exact], groups: [], query: "github token", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["GITHUB_TOKEN", "GITHUB_BACKUP"])
    }

    func test_search_complete_token_matches_outrank_first_token_only_matches() {
        let firstTokenOnly = secret(name: "AWS_STAGING", copyCount: 10, lastCopiedDaysAgo: 1, createdDaysAgo: 30)
        let completeTokenMatch = secret(name: "MY_AWS_PROD_KEY", copyCount: 0, lastCopiedDaysAgo: nil, createdDaysAgo: 30)

        let sorted = CaseRanker.sortedEntries(secrets: [firstTokenOnly, completeTokenMatch], groups: [], query: "aws prod", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["MY_AWS_PROD_KEY", "AWS_STAGING"])
    }

    func test_group_uses_group_name_and_child_usage_for_ranking() {
        let groupID = UUID()
        let child = secret(name: "AWS_PROD_KEY", groupID: groupID, copyCount: 8, lastCopiedDaysAgo: 1, createdDaysAgo: 20)
        let group = CaseGroup(
            id: groupID,
            name: "AWS prod",
            keyIDs: [child.id],
            copyCount: 0,
            lastCopiedAt: nil,
            createdAt: now.addingTimeInterval(-20 * 86_400),
            updatedAt: now
        )

        let sorted = CaseRanker.sortedEntries(secrets: [child], groups: [group], query: "aws", now: now)

        XCTAssertEqual(sorted.first?.displayName, "AWS prod")
    }

    func test_secret_with_group_id_is_not_emitted_individually_when_group_key_ids_are_stale() {
        let groupID = UUID()
        let child = secret(name: "STALE_CHILD", groupID: groupID, copyCount: 3, lastCopiedDaysAgo: 1, createdDaysAgo: 20)
        let group = CaseGroup(
            id: groupID,
            name: "Stale group",
            keyIDs: [],
            copyCount: 0,
            lastCopiedAt: nil,
            createdAt: now.addingTimeInterval(-20 * 86_400),
            updatedAt: now
        )

        let sorted = CaseRanker.sortedEntries(secrets: [child], groups: [group], query: "", now: now)

        XCTAssertEqual(sorted.map(\.displayName), ["Stale group"])
    }

    func test_group_child_usage_includes_secret_group_id_when_group_key_ids_are_stale() {
        let staleGroupID = UUID()
        let oldGroupID = UUID()
        let child = secret(name: "STALE_CHILD", groupID: staleGroupID, copyCount: 8, lastCopiedDaysAgo: 1, createdDaysAgo: 20)
        let staleGroup = CaseGroup(
            id: staleGroupID,
            name: "Stale group",
            keyIDs: [],
            copyCount: 0,
            lastCopiedAt: nil,
            createdAt: now.addingTimeInterval(-20 * 86_400),
            updatedAt: now
        )
        let oldGroup = CaseGroup(
            id: oldGroupID,
            name: "Old group",
            keyIDs: [],
            copyCount: 40,
            lastCopiedAt: now.addingTimeInterval(-120 * 86_400),
            createdAt: now.addingTimeInterval(-200 * 86_400),
            updatedAt: now
        )

        let sorted = CaseRanker.sortedEntries(secrets: [child], groups: [oldGroup, staleGroup], query: "", now: now)

        XCTAssertEqual(sorted.first?.displayName, "Stale group")
    }

    private func secret(
        name: String,
        groupID: UUID? = nil,
        copyCount: Int,
        lastCopiedDaysAgo: Double?,
        createdDaysAgo: Double
    ) -> CaseSecret {
        CaseSecret(
            id: UUID(),
            name: name,
            groupID: groupID,
            copyCount: copyCount,
            lastCopiedAt: lastCopiedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            createdAt: now.addingTimeInterval(-createdDaysAgo * 86_400),
            updatedAt: now
        )
    }
}
