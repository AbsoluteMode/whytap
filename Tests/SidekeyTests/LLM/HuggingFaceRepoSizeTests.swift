import XCTest
@testable import Sidekey

/// Unit coverage for `HuggingFaceRepoSize.totalBytes` via its injectable
/// `TreeFetcher` seam — no network. The `matchedAny ? total : nil` fallback is
/// the only guard against the coarse-progress regression (dividing real
/// downloaded bytes by a bogus/zero total), so these cases pin it explicitly.
final class HuggingFaceRepoSizeTests: XCTestCase {
    private func sut(returning entries: [HuggingFaceRepoSize.Entry]?) -> HuggingFaceRepoSize {
        HuggingFaceRepoSize(fetchTree: { _, _ in entries })
    }

    private func file(_ path: String, _ size: Int64?) -> HuggingFaceRepoSize.Entry {
        HuggingFaceRepoSize.Entry(type: "file", path: path, size: size)
    }

    private func directory(_ path: String) -> HuggingFaceRepoSize.Entry {
        HuggingFaceRepoSize.Entry(type: "directory", path: path, size: nil)
    }

    // MARK: - Matched sum

    func testSumsSizesOfMatchingFiles() async {
        let size = await sut(returning: [
            file("model-00001.safetensors", 1_000),
            file("model-00002.safetensors", 2_500),
            file("readme.md", 42),
        ]).totalBytes(repoID: "org/model", matching: { $0.hasSuffix(".safetensors") })

        XCTAssertEqual(size, 3_500, "should sum only the matching files")
    }

    // MARK: - matchedAny == nil fallback (the coarse-progress guard)

    func testReturnsNilWhenNoFileMatches() async {
        let size = await sut(returning: [
            file("model.bin", 1_000),
            file("config.json", 10),
        ]).totalBytes(repoID: "org/model", matching: { $0.hasSuffix(".safetensors") })

        XCTAssertNil(size, "no match must fall back to nil, not 0 (else progress divides by a bogus total)")
    }

    func testReturnsNilWhenTreeCannotBeRead() async {
        let size = await sut(returning: nil)
            .totalBytes(repoID: "org/model", matching: { _ in true })

        XCTAssertNil(size, "an unreadable tree must propagate as nil")
    }

    func testReturnsNilWhenMatchingFilesHaveNoUsableSize() async {
        // Files match the predicate but none reports a usable (>0, non-nil) size,
        // so matchedAny stays false and the result is nil rather than 0.
        let size = await sut(returning: [
            file("model-00001.safetensors", nil),
            file("model-00002.safetensors", 0),
        ]).totalBytes(repoID: "org/model", matching: { $0.hasSuffix(".safetensors") })

        XCTAssertNil(size, "matching files with only nil/zero sizes must fall back to nil")
    }

    // MARK: - Zero / nil size skip (partial)

    func testSkipsZeroAndNilSizedEntriesButKeepsRealOnes() async {
        let size = await sut(returning: [
            file("model-00001.safetensors", nil),   // skipped (nil)
            file("model-00002.safetensors", 0),      // skipped (zero)
            file("model-00003.safetensors", 4_096),  // counted
        ]).totalBytes(repoID: "org/model", matching: { $0.hasSuffix(".safetensors") })

        XCTAssertEqual(size, 4_096, "nil/zero-sized entries are skipped; the real one still counts")
    }

    // MARK: - File-vs-directory filter

    func testIgnoresDirectoryEntriesEvenWhenPathMatches() async {
        // A directory whose path satisfies `matches` must NOT be summed — only
        // `type == "file"` entries count. Here the directory even carries a
        // (bogus) size to prove the type filter, not the size guard, excludes it.
        let trickyDirectory = HuggingFaceRepoSize.Entry(
            type: "directory",
            path: "weights.safetensors",
            size: 9_999
        )
        let size = await sut(returning: [
            trickyDirectory,
            directory("weights"),
            file("weights.safetensors/part-1", 1_234),
        ]).totalBytes(repoID: "org/model", matching: { $0.contains("safetensors") })

        XCTAssertEqual(size, 1_234, "directory entries are excluded even when their path matches")
    }
}
