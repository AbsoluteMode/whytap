import AppKit
import CryptoKit
import Darwin

// Build from the repository root and run once per fixture in a fresh process:
// d=Sources/Sidekey/Screenshots
// swiftc -O "$d/ScreenshotDocument.swift" "$d/ScreenshotGlyphDetector.swift" \
//   "$d/ScreenshotInlineText.swift" Tests/SidekeyTests/Screenshots/ScreenshotOCRFixture.swift \
//   scripts/benchmark-screenshot-ocr.swift -o /tmp/whytap-ocr
// /tmp/whytap-ocr full --prewarm
// /tmp/whytap-ocr small --prewarm
// /tmp/whytap-ocr mixed --prewarm
// Rebuild with a distinct -module-name for each fixture to test a new client's cold cache.
// To benchmark the old detector, compile it with -D OCR_BASELINE and omit --prewarm.
@main
enum ScreenshotOCRBenchmark {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let name = arguments.first, let fixture = ScreenshotOCRFixture(rawValue: name),
              arguments.count == 1 || arguments == [name, "--prewarm"] else {
            print("Usage: whytap-ocr full|small|mixed [--prewarm]")
            exit(2)
        }
        #if !OCR_BASELINE
        if arguments.contains("--prewarm") {
            let start = ContinuousClock.now
            await ScreenshotTextDetector.warmUp().value
            print(String(format: "warmup_ms=%.1f", milliseconds(start.duration(to: .now))))
            fflush(stdout)
        }
        #endif
        let (source, expected) = try fixture.screenshot()
        for run in 0..<4 {
            let clock = ContinuousClock()
            let start = clock.now
            let crop = try ScreenshotRenderer.image(source: source, size: ScreenshotOCRFixture.displaySize,
                                                    annotations: [], crop: fixture.crop)
            let rendered = clock.now
            #if OCR_BASELINE
            let text = try ScreenshotTextDetector.text(crop)
            #else
            let text = try await ScreenshotTextDetector.text(crop)
            #endif
            let elapsed = rendered.duration(to: clock.now)
            let matches = expected.filter { text.contains($0) }.count
            let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            let renderMs = milliseconds(start.duration(to: rendered))
            let ocrMs = milliseconds(elapsed)
            print(String(format: "%@ run=%d %dx%d render_ms=%.1f ocr_ms=%.1f exact=%d/%d sha256=%@",
                         fixture.rawValue, run, crop.width, crop.height, renderMs, ocrMs, matches, expected.count, hash))
            fflush(stdout)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
