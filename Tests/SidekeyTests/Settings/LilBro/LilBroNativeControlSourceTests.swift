import Foundation
import XCTest

/// Builder ticket 651, point 2: a native SwiftUI control (`Button`, `Link`,
/// `TextField`, `SecureField`, `Toggle`, `Picker`, `Menu`, `Slider`…) on a
/// Settings screen does not go through the Mac* primitives that report
/// themselves, so `LilBroRowCoverageTests` cannot see it. Here every one of
/// them in the Settings sources must either report itself with
/// `.lilBroControl(label)` (then the coverage test checks it sits in a row
/// Lil Bro can lead to) or carry a `// lilBro-exempt: <reason>` comment on
/// its line or the two lines above. A new native control without either
/// fails here.
///
/// Not scanned, by design:
/// - `Settings/LilBro/`: Lil Bro's own balloon, not a setting.
/// - The island panels a Toolbox tool's pane embeds (Vocab, Filler, Case,
///   Notify, Monitor, History, Translate…): the whole pane is one row
///   (`toolbox.<tool>`), so every control in it is inside that row.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md (REV 15, builder ticket 651)
final class LilBroNativeControlSourceTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let sources = root.appendingPathComponent("Sources/Sidekey")

    /// Settings screens' files: the Settings folder and the few Settings
    /// views that live next to their feature.
    private static func settingsFiles() throws -> [URL] {
        let settings = sources.appendingPathComponent("Settings")
        var files: [URL] = []
        let walker = FileManager.default.enumerator(at: settings, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.path.contains("/Settings/LilBro/") else { continue }
            files.append(url)
        }
        files += ["Hotkeys/HotkeysSettingsView.swift", "Permissions/DropShortcutStatusSection.swift",
                  "Brightness/ToolboxDisplayPane.swift"].map { sources.appendingPathComponent($0) }
        return files.sorted { $0.path < $1.path }
    }

    private static let control = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])(Button|Link|TextField|SecureField|Toggle|Picker|Menu|Slider|Stepper|DatePicker|ColorPicker)\s*[({]"#)

    func test_every_native_control_in_settings_reports_itself_or_says_why_not() throws {
        var unexplained: [String] = []
        var exempt = 0, reported = 0
        for file in try Self.settingsFiles() {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            let name = file.path.replacingOccurrences(of: Self.sources.path + "/", with: "")
            // Controls, last first, each claiming the nearest `.lilBroControl(`
            // after it that no later control claimed.
            var claimed: Set<Int> = []
            let found = lines.indices.filter { index in
                let line = lines[index]
                let code = line.components(separatedBy: "//").first ?? ""
                return Self.control.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
                    && !code.contains("struct ") && !code.contains("func ")
            }
            for index in found.reversed() {
                let context = lines[max(0, index - 2)...index].joined(separator: "\n")
                if context.contains("lilBro-exempt:") { exempt += 1; continue }
                let reach = lines.indices.filter { $0 >= index && $0 < index + 40 && !claimed.contains($0) }
                if let at = reach.first(where: { lines[$0].contains(".lilBroControl(") }) {
                    claimed.insert(at); reported += 1; continue
                }
                unexplained.append("\(name):\(index + 1): \(lines[index].trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertGreaterThan(reported, 0)
        XCTAssertGreaterThan(exempt, 0)
        XCTAssertEqual(unexplained, [], """
            native controls in Settings neither report themselves (.lilBroControl) nor say why not \
            (// lilBro-exempt: reason)
            """)
    }
}
