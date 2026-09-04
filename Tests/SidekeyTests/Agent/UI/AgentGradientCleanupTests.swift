import Foundation
import XCTest

final class AgentGradientCleanupTests: XCTestCase {
    func testUsefulLinkChipUsesSolidBorderInsteadOfRainbowGradient() throws {
        let source = try loadSource("Agent/UI/Renderers/UsefulLinkChipView.swift")

        XCTAssertFalse(source.contains("LinearGradient("))
        XCTAssertFalse(source.contains("RainbowBottomEdge"))
        XCTAssertFalse(source.contains("rainbow"))
        XCTAssertTrue(source.contains(".strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)"))
    }

    func testShineBorderViewRendersPlainStroke() throws {
        let source = try loadSource("Agent/UI/ShineBorderView.swift")

        XCTAssertFalse(source.contains("AngularGradient("))
        XCTAssertFalse(source.contains("defaultPalette"))
        XCTAssertTrue(source.contains("shape.stroke(color, lineWidth: lineWidth)"))
        XCTAssertTrue(source.contains("Color.primary.opacity(0.12)"))
    }

    func testAgentAnswerBodyUsesPlainStreamingTextAndBorders() throws {
        // The agent answer body (Pill 1 / Pill 2 / blocks) moved out of the
        // now-deleted `AgentResponsePanel.swift` into the shared
        // `AgentAnswerBodyView.swift`. The plain-streaming-text / no-gradient
        // contract follows the renderers.
        let source = try loadSource("Agent/UI/AgentAnswerBodyView.swift")

        XCTAssertFalse(source.contains("LinearGradient("))
        XCTAssertFalse(source.contains("ShimmeringText"))
    }

    private func loadSource(_ relativePath: String) throws -> String {
        let candidates = candidateSourceURLs(for: relativePath)
        for url in candidates {
            if let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8) {
                return source
            }
        }
        throw XCTSkip("Source not reachable: \(relativePath); tried \(candidates.map(\.path).joined(separator: ", "))")
    }

    private func candidateSourceURLs(for relativePath: String) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        if let srcroot = env["SRCROOT"] { roots.append(URL(fileURLWithPath: srcroot)) }
        if let pkgRoot = env["PACKAGE_PATH"] { roots.append(URL(fileURLWithPath: pkgRoot)) }

        let thisFile = URL(fileURLWithPath: #filePath)
        var cursor = thisFile.deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent("Package.swift").path) {
                roots.append(cursor)
                break
            }
            cursor = cursor.deletingLastPathComponent()
        }

        return roots.map { $0.appendingPathComponent("Sources/Sidekey/\(relativePath)") }
    }
}
