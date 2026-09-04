import XCTest
@testable import Sidekey

@MainActor
final class ProviderBrandIconAssetTests: XCTestCase {
    func testSettingsProviderBrandAssetsAreBundled() throws {
        let root = try projectRoot()
        let iconDir = root.appendingPathComponent("Resources/UsefulLinkIcons")
        let expectedNames = [
            "openai",
            "deepgram",
            "soniox",
            "elevenlabs",
            "codex",
            "claude-code",
            "openrouter",
        ]

        for name in expectedNames {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: iconDir.appendingPathComponent("\(name).svg").path
                ),
                "Missing \(name).svg"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: iconDir.appendingPathComponent("\(name).pdf").path
                ),
                "Missing \(name).pdf"
            )
        }
    }

    func testSonioxIconIsVectorNotEmbeddedBitmap() throws {
        let root = try projectRoot()
        let svgURL = root
            .appendingPathComponent("Resources/UsefulLinkIcons")
            .appendingPathComponent("soniox.svg")
        let svg = try String(contentsOf: svgURL, encoding: .utf8)

        XCTAssertTrue(svg.contains("<path"))
        XCTAssertFalse(svg.contains("<image"))
        XCTAssertFalse(svg.contains("base64"))
    }

    func testSonioxIconUsesTightViewBoxSoMarkReadsAtRowSize() throws {
        let root = try projectRoot()
        let svgURL = root
            .appendingPathComponent("Resources/UsefulLinkIcons")
            .appendingPathComponent("soniox.svg")
        let svg = try String(contentsOf: svgURL, encoding: .utf8)

        XCTAssertTrue(svg.contains("width=\"48\""))
        XCTAssertTrue(svg.contains("height=\"48\""))
        XCTAssertTrue(svg.contains("viewBox=\"8 6 32 36\""))
    }

    func testTranscriptionProviderBrandAssetsPrewarmIntoCache() throws {
        let iconDir = try projectRoot().appendingPathComponent("Resources/UsefulLinkIcons")
        ProviderBrandIconAsset.setResourceDirectoryForTesting(iconDir)
        ProviderBrandIconAsset.clearCacheForTesting()
        defer {
            ProviderBrandIconAsset.clearCacheForTesting()
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        }

        let loadedCount = ProviderBrandIconAsset.prewarmTranscriptionProviderAssets()

        XCTAssertEqual(
            loadedCount,
            ProviderBrandIconAsset.transcriptionProviderAssetNames.count
                * ProviderBrandIconAsset.prewarmedPointSizes.count
                + ProviderBrandIconAsset.fullColorProviderAssetNames.count
        )
        for name in ProviderBrandIconAsset.transcriptionProviderAssetNames {
            XCTAssertTrue(ProviderBrandIconAsset.isSourceCachedForTesting(name))
            for pointSize in ProviderBrandIconAsset.prewarmedPointSizes {
                XCTAssertTrue(ProviderBrandIconAsset.isRenderedCachedForTesting(name, pointSize: pointSize))
            }
        }
        for name in ProviderBrandIconAsset.fullColorProviderAssetNames {
            XCTAssertTrue(ProviderBrandIconAsset.isFullColorSourceCachedForTesting(name))
        }
    }

    /// The full-color loader keeps native colors (used for the Qwen island mark);
    /// the template loader flattens to a monochrome tint. They must be distinct
    /// objects so one never clobbers the other's `isTemplate` flag.
    func testFullColorImageIsNonTemplateAndDistinctFromTemplate() throws {
        let iconDir = try projectRoot().appendingPathComponent("Resources/UsefulLinkIcons")
        ProviderBrandIconAsset.setResourceDirectoryForTesting(iconDir)
        ProviderBrandIconAsset.clearCacheForTesting()
        defer {
            ProviderBrandIconAsset.clearCacheForTesting()
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        }

        let fullColor = try XCTUnwrap(ProviderBrandIconAsset.fullColorImage(named: "qwen"))
        XCTAssertFalse(fullColor.isTemplate, "full-color mark must keep native colors")

        let template = try XCTUnwrap(ProviderBrandIconAsset.image(named: "qwen"))
        XCTAssertTrue(template.isTemplate)
        XCTAssertFalse(fullColor === template)
        // The template flag must not have leaked onto the full-color instance.
        XCTAssertFalse(fullColor.isTemplate)
    }

    /// Brand choice (per Andrey, 2026-06-27): the Qwen mark uses the purple
    /// brand gradient, not the solid HF blue — the blue variant was reverted.
    func testQwenAssetIsPurpleBrandMark() throws {
        let svgURL = try projectRoot()
            .appendingPathComponent("Resources/UsefulLinkIcons")
            .appendingPathComponent("qwen.svg")
        let svg = try String(contentsOf: svgURL, encoding: .utf8).lowercased()

        XCTAssertTrue(svg.contains("#6336e7") || svg.contains("#6f69f7"),
                      "Qwen mark must use the purple brand gradient")
        XCTAssertFalse(svg.contains("#002efe"), "the HF-blue variant was reverted")
        // Vector, not an embedded bitmap.
        XCTAssertTrue(svg.contains("<path"))
        XCTAssertFalse(svg.contains("<image"))
        XCTAssertFalse(svg.contains("base64"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "ProviderBrandIconAssetTests", code: 1)
    }
}
