import XCTest
@testable import Sidekey

/// Reported from a second Mac: the agent copied a file and Cyrillic arrived
/// in the clipboard broken. Whytap opened from Finder has no `LANG`, so the
/// agent's commands ran without a locale and tools read UTF-8 as MacRoman.
// WHY: .project-docs/decisions/2026-11-20-agent-command-utf8-locale.md
final class NativeAgentCommandLocaleTests: XCTestCase {
    /// One line per script, each a plain sequence of code points.
    private let samples = [
        "cyrillic": "Привет, мир",
        "chinese": "你好，世界",
        "japanese": "こんにちは世界",
        "korean": "안녕하세요 세계",
        "arabic": "مرحبا بالعالم",
        "hebrew": "שלום עולם",
        "hindi": "नमस्ते दुनिया",
        "latin": "Größe, façade, señor, Łódź",
        "emoji": "ok 🎉🚀",
    ]

    /// The command's own output: the runner appends an exit line after it.
    private func firstLine(_ output: String) -> String {
        String(output.split(separator: "\n", omittingEmptySubsequences: true).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NativeAgentCommandLocaleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test_an_app_without_a_locale_still_gives_commands_utf8() {
        let finder = NativeAgentCommand.childEnvironment(from: ["HOME": "/Users/x", "SECRET": "1"], helper: nil)
        XCTAssertEqual(finder["LANG"], "en_US.UTF-8")
        XCTAssertEqual(finder["HOME"], "/Users/x")
        XCTAssertNil(finder["SECRET"], "unrelated variables still stay out")
        XCTAssertNotNil(finder["PATH"])

        for (inherited, expected) in [
            ("ru_RU.UTF-8", "ru_RU.UTF-8"), ("ja_JP.UTF-8", "ja_JP.UTF-8"), ("C.UTF-8", "C.UTF-8"),
            // Names macOS does not resolve run as C: they are replaced.
            ("ja_JP.utf8", "en_US.UTF-8"), ("en_US.utf-8", "en_US.UTF-8"), ("xx_YY.UTF-8", "en_US.UTF-8"),
            ("../../etc.UTF-8", "en_US.UTF-8"), (".UTF-8", "en_US.UTF-8"),
            ("C", "en_US.UTF-8"), ("POSIX", "en_US.UTF-8"), ("ru_RU.KOI8-R", "en_US.UTF-8"), ("", "en_US.UTF-8"),
        ] {
            XCTAssertEqual(NativeAgentCommand.childEnvironment(from: ["LANG": inherited], helper: nil)["LANG"], expected, inherited)
        }
        XCTAssertEqual(
            NativeAgentCommand.childEnvironment(from: ["LANG": "ru_RU.UTF-8"], helper: nil, localeIsInstalled: { _ in false })["LANG"],
            "en_US.UTF-8", "a UTF-8 name this Mac lacks is not trusted")
        XCTAssertTrue(NativeAgentCommand.localeIsInstalled(NativeAgentCommand.fallbackLocale), "the fallback itself must work")
        let withOverrides = NativeAgentCommand.childEnvironment(
            from: ["LANG": "en_US.UTF-8", "LC_ALL": "C", "LC_CTYPE": "C"], helper: nil)
        XCTAssertNil(withOverrides["LC_ALL"], "an inherited override cannot switch the child back to bytes")
        XCTAssertNil(withOverrides["LC_CTYPE"])
    }

    /// `wc -m` counts characters in the command's locale: bytes without
    /// UTF-8, code points with it. No clipboard is touched.
    func test_commands_read_every_script_as_text_when_the_app_has_no_locale() async throws {
        let directory = try directory()
        for (name, text) in samples {
            try Data(text.utf8).write(to: directory.appendingPathComponent("\(name).txt"))
        }
        // Every inherited value, valid or not, must end in a real UTF-8 shell.
        let bases: [[String: String]] = [
            [:], ["LANG": "C"], ["LANG": "ja_JP.utf8"], ["LANG": "ja_JP.UTF-8"], ["LANG": "xx_YY.UTF-8"],
            ["LANG": "ru_RU.UTF-8"], ["LANG": "C.UTF-8"], ["LANG": "ru_RU.KOI8-R"], ["LANG": "en_US.UTF-8", "LC_ALL": "C"],
        ]
        for base in bases {
            let charmap = await NativeAgentCommand().run(
                command: "locale charmap", directory: directory, helper: nil, baseEnvironment: base)
            XCTAssertEqual(firstLine(charmap), "UTF-8", "\(base)")

            for (name, text) in samples {
                let counted = await NativeAgentCommand().run(
                    command: "wc -m < \(name).txt", directory: directory, helper: nil, baseEnvironment: base)
                XCTAssertEqual(Int(firstLine(counted)), text.unicodeScalars.count,
                               "\(name) with \(base): \(counted)")
                XCTAssertNotEqual(text.unicodeScalars.count, text.utf8.count, "\(name) must be able to fail")

                let printed = await NativeAgentCommand().run(
                    command: "cat \(name).txt", directory: directory, helper: nil, baseEnvironment: base)
                XCTAssertEqual(firstLine(printed), text, name)
            }
        }
    }
}
