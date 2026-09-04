import XCTest

/// Locks invariant #3 ("prompt/user content NEVER logged") on the on-device
/// paths added by ROO-257. These flows handle the user's dictated text, agent
/// prompts, model replies, and meeting transcripts entirely on-device — and
/// must log only timing / counts / ids, never the content itself.
///
/// Source-inspection guard (mirrors the `scripts/build-dmg.sh`-style grep tests
/// elsewhere in the suite): it parses every `os_log(...)` call in each guarded
/// file and asserts that none interpolates a forbidden content identifier. This
/// is currently compliant; the test exists so a future edit that starts logging
/// `reply`/`transcript`/`user` text fails loudly instead of silently leaking it
/// into `os_log`.
final class LocalPathLoggingInvariantTests: XCTestCase {
    /// Files on the new local (on-device) paths that touch user/model content.
    private static let guardedFiles = [
        "Sources/Sidekey/LLM/Local/LocalLLMSession.swift",
        "Sources/Sidekey/Meetings/MeetingLocalProcessor.swift",
        "Sources/Sidekey/Meetings/MeetingLocalTranscriber.swift",
        "Sources/Sidekey/Streaming/Local/LocalTranscriptionSession.swift",
        "Sources/Sidekey/Streaming/Local/LocalBatchTranscriber.swift",
    ]

    /// Identifiers whose VALUE is user/model content. If an `os_log` call passes
    /// any of these as a logged argument, the content would land in the unified
    /// log — exactly what invariant #3 forbids. Matched as whole words so e.g.
    /// `systemSamples.count` (a count, allowed) does not trip the `system` rule.
    private static let forbiddenContentTokens = [
        "prompt", "user", "system", "reply", "text", "transcript",
        "markdown", "instructions", "segments", "samples",
    ]

    func test_localPathsNeverLogPromptOrContent() throws {
        for relativePath in Self.guardedFiles {
            let source = try readProjectFile(relativePath)

            let calls = Self.osLogCalls(in: source)
            XCTAssertFalse(
                calls.isEmpty,
                "\(relativePath): expected at least one os_log call to inspect — has the logging API changed? Update this guard."
            )

            for call in calls {
                // 1. No string interpolation inside an os_log call. os_log uses
                //    %-format specifiers; a `\(reply)` interpolation would inline
                //    content directly into the message.
                XCTAssertFalse(
                    call.contains(#"\("#),
                    "\(relativePath): os_log must not use string interpolation (would inline content). Call:\n\(call)"
                )

                // 2. No `%{private}` specifier — that's the format-string lever
                //    for emitting redacted-in-release-but-still-captured content.
                //    These paths must log only `%{public}` metrics.
                XCTAssertFalse(
                    call.contains("%{private}"),
                    "\(relativePath): os_log must not use a %{private} specifier on the local paths. Call:\n\(call)"
                )

                // 3. No forbidden content identifier in the ARGUMENT code. Field
                //    labels inside the format-string literal (e.g. "segments:")
                //    are descriptive, not content — so we strip string literals
                //    first and scan only the argument expressions. A forbidden
                //    token there is allowed only when immediately reduced to a
                //    scalar metric (.count / .uuidString / .compactMap{…}.count …).
                let argumentCode = Self.strippingStringLiterals(from: call)
                for token in Self.forbiddenContentTokens {
                    for hit in Self.wholeWordOccurrences(of: token, in: argumentCode) {
                        if Self.isAllowedMetricUsage(hit) { continue }
                        XCTFail(
                            "\(relativePath): os_log appears to log content identifier '\(token)' "
                                + "(usage: '\(hit)'). Invariant #3: log timing/counts only, never "
                                + "prompt/user/system/reply/text/transcript content. Call:\n\(call)"
                        )
                    }
                }
            }
        }
    }

    /// Replace every double-quoted string literal in `call` with a space, so the
    /// format string and its embedded field labels don't get mistaken for logged
    /// content. Leaves the argument expressions intact.
    private static func strippingStringLiterals(from call: String) -> String {
        var out = ""
        var inString = false
        var escaped = false
        for char in call {
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            if char == "\"" {
                inString = true
                out.append(" ")
            } else {
                out.append(char)
            }
        }
        return out
    }

    // MARK: - os_log call extraction

    /// Extract the full text of every `os_log( ... )` call via a balanced-paren
    /// scan, so multi-line calls (which these files use) are captured whole.
    private static func osLogCalls(in source: String) -> [String] {
        let scalars = Array(source)
        var calls: [String] = []
        let needle = Array("os_log(")
        var index = 0

        while index <= scalars.count - needle.count {
            if Array(scalars[index..<index + needle.count]) == needle {
                // Walk from the opening paren to its match, respecting nesting
                // and skipping string literals so a ')' inside a string doesn't
                // close the call early.
                var depth = 0
                var cursor = index + needle.count - 1 // points at '('
                var inString = false
                var escaped = false
                let start = index
                while cursor < scalars.count {
                    let char = scalars[cursor]
                    if inString {
                        if escaped {
                            escaped = false
                        } else if char == "\\" {
                            escaped = true
                        } else if char == "\"" {
                            inString = false
                        }
                    } else if char == "\"" {
                        inString = true
                    } else if char == "(" {
                        depth += 1
                    } else if char == ")" {
                        depth -= 1
                        if depth == 0 {
                            calls.append(String(scalars[start...cursor]))
                            break
                        }
                    }
                    cursor += 1
                }
                index = cursor + 1
            } else {
                index += 1
            }
        }
        return calls
    }

    /// All whole-word usages of `token` in `text`, returned with a short
    /// trailing context (the token plus what immediately follows, e.g.
    /// `samples.count`) so the metric-allowlist can inspect the access.
    private static func wholeWordOccurrences(of token: String, in text: String) -> [String] {
        let chars = Array(text)
        let needle = Array(token)
        var results: [String] = []
        var index = 0

        func isWordChar(_ char: Character) -> Bool {
            char.isLetter || char.isNumber || char == "_"
        }

        while index <= chars.count - needle.count {
            if Array(chars[index..<index + needle.count]) == needle {
                let before = index > 0 ? chars[index - 1] : " "
                let afterIndex = index + needle.count
                let after = afterIndex < chars.count ? chars[afterIndex] : " "
                if !isWordChar(before) && !isWordChar(after) {
                    // Capture a trailing window for context (e.g. `.count`,
                    // `.compactMap(\.speaker)).count`). Wide enough to reach the
                    // terminating metric accessor on the wrapped-collection cases.
                    let end = min(chars.count, afterIndex + 40)
                    results.append(String(chars[index..<end]))
                }
                index = afterIndex
            } else {
                index += 1
            }
        }
        return results
    }

    /// A forbidden token (found in the argument code) is acceptable ONLY when it
    /// is reduced to a scalar metric — a count/length, a UUID string, or a
    /// collection mapped/reduced to a count — never the content value itself.
    private static func isAllowedMetricUsage(_ hit: String) -> Bool {
        // Direct scalar reductions: `samples.count`, `mic.length`, …
        if hit.contains(".count") || hit.contains(".length") {
            return true
        }
        // Ids are not content: `meetingId.uuidString`.
        if hit.contains(".uuidString") {
            return true
        }
        // Collection reduced to a count via map/compactMap (the speakers case is
        // `Set(segments.compactMap(\.speaker)).count`).
        if hit.contains(".compactMap") || hit.contains(".map") {
            return true
        }
        return false
    }

    // MARK: - Project file access (mirrors ReleaseToolchainContractTests)

    private func readProjectFile(_ relativePath: String) throws -> String {
        let root = try projectRoot()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "LocalPathLoggingInvariantTests", code: 1)
    }
}
