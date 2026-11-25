import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import Sidekey

/// A clip's card shows a frame of the clip with a play mark, picked where the
/// feature's result is on screen, never the dark first frame.
// WHY: .project-docs/decisions/2026-11-25-feature-clip-posters.md
@MainActor
final class FeatureClipPosterTests: XCTestCase {
    private var resources: Bundle!

    override func setUp() async throws {
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        resources = try XCTUnwrap(Bundle(url: root.appendingPathComponent("Resources")))
        FeatureVideoPoster.clearForTesting()
        let saved = FeatureVideo.resourceBundle
        FeatureVideo.resourceBundle = resources
        addTeardownBlock { @MainActor in
            FeatureVideo.resourceBundle = saved
            FeatureVideoPoster.clearForTesting()
        }
    }

    /// Every clip a feature screen shows.
    private var screenClips: [FeatureVideo] {
        FeatureCatalog.all.flatMap(\.clips).compactMap(\.video)
    }

    func testEveryScreenClipHasAPosterInsideTheClip() async throws {
        XCTAssertFalse(screenClips.isEmpty)
        for video in FeatureVideo.allCases {
            let url = try XCTUnwrap(video.url(in: resources), "\(video) is bundled")
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            XCTAssertGreaterThan(video.posterSeconds, 1, "\(video): not the first frame")
            XCTAssertLessThan(video.posterSeconds, duration, "\(video): inside the clip")
        }
    }

    func testThePosterIsAFrameWithSomethingOnIt() async throws {
        for video in screenClips {
            let url = try XCTUnwrap(video.url(in: resources))
            let loaded = await FeatureVideoPoster.load(video, url: url)
            let image = try XCTUnwrap(loaded, "\(video) poster")
            XCTAssertEqual(image.size.width / image.size.height, 16.0 / 9.0, accuracy: 0.02)
            let (mean, spread) = try luminance(of: image)
            XCTAssertGreaterThan(mean, 0.08, "\(video): not a black frame")
            XCTAssertGreaterThan(spread, 0.05, "\(video): not a blank frame")
            XCTAssertIdentical(FeatureVideoPoster.cached(url), image, "read once and kept")
        }
    }

    func testConcurrentRequestsReuseTheSamePoster() async throws {
        let url = try XCTUnwrap(FeatureVideo.subtitles.url(in: resources))
        let first = Task { await FeatureVideoPoster.load(.subtitles, url: url) }
        let second = Task { await FeatureVideoPoster.load(.subtitles, url: url) }
        let firstImage = await first.value
        let secondImage = await second.value
        let poster = try XCTUnwrap(firstImage)
        XCTAssertIdentical(secondImage, poster)
        XCTAssertIdentical(FeatureVideoPoster.cached(url), poster)
    }

    func testAClipNotMadeYetHasNoPoster() async throws {
        let clip = FeatureClip(name: "Upcoming clip", video: nil, caption: "Soon")
        XCTAssertNil(clip.video?.url(in: resources))
        let missing = URL(fileURLWithPath: "/nonexistent/clip.mp4")
        let image = await FeatureVideoPoster.load(.translate, url: missing)
        XCTAssertNil(image)
        XCTAssertNil(FeatureVideoPoster.cached(missing))
    }

    func testRenderTheCardsWithTheirPosters() async throws {
        for video in screenClips {
            _ = await FeatureVideoPoster.load(video, url: try XCTUnwrap(video.url(in: resources)))
        }
        let directory = FeaturesFixture.renderDirectory
        let resources = self.resources!
        for info in FeatureCatalog.all where info.clips.contains(where: { $0.video != nil }) {
            for dark in [false, true] {
                let view = VStack(spacing: 12) {
                    ForEach(Array(info.clips.enumerated()), id: \.offset) { _, clip in
                        FeatureVideoStrip(clip: clip, bundle: resources)
                    }
                }
                let height = 40 + 86 * CGFloat(info.clips.count)
                let card = view
                    .padding(20)
                    .frame(width: 640, height: height, alignment: .top)
                    .background(MacSettingsTheme.bgContent)
                try FeaturesFixture.render(card, size: NSSize(width: 640, height: height),
                                           dark: dark,
                                           to: directory?.appendingPathComponent(
                                               "poster-\(info.feature.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func luminance(of image: NSImage) throws -> (mean: Double, spread: Double) {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let width = 64, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values: [Double] = []
        for i in stride(from: 0, to: pixels.count, by: 4) {
            values.append((0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1])
                           + 0.0722 * Double(pixels[i + 2])) / 255)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }
}
