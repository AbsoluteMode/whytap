import CoreGraphics
import CoreText
import Foundation

enum ScreenshotOCRFixture: String {
    case full, small, mixed

    static let displaySize = CGSize(width: 1728, height: 1117)

    private enum FixtureError: Error { case bitmapUnavailable }

    var crop: CGRect {
        switch self {
        case .full: return CGRect(origin: .zero, size: Self.displaySize)
        case .small: return CGRect(x: 0, y: 0, width: 430, height: 120)
        case .mixed: return CGRect(x: 0, y: 0, width: 760, height: 260)
        }
    }

    func screenshot() throws -> (CGImage, [String]) {
        guard let context = CGContext(data: nil, width: 3456, height: 2234, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw FixtureError.bitmapUnavailable }
        let dark = self == .full
        context.setFillColor(CGColor(gray: dark ? 0.10 : 0.98, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        var expected: [String] = []
        let font = CTFontCreateWithName("Menlo" as CFString, dark ? 21 : 28, nil)
        for column in 0..<(dark ? 3 : 1) {
            for row in 0..<(dark ? 48 : self == .small ? 4 : 9) {
                let number = 4310 + column * 100 + row
                let line = self == .small || (row + column).isMultiple(of: 2)
                    ? "Build \(number): service status ready"
                    : "Сборка \(number): отчёт готов"
                let value = NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: dark ? 0.91 : 0.10, alpha: 1)
                ])
                context.textPosition = CGPoint(x: 35 + column * 1050,
                                               y: Int(crop.height * 2) - 46 - row * (dark ? 43 : 52))
                CTLineDraw(CTLineCreateWithAttributedString(value), context)
                expected.append(line)
            }
        }
        guard let image = context.makeImage() else { throw FixtureError.bitmapUnavailable }
        return (image, expected)
    }
}
