import AppKit
import CoreImage
import Vision

enum ScreenshotTool: String, CaseIterable {
    case select, arrow, rectangle, ellipse, pen, text, blur, counter
}

enum ScreenshotBlurMode: String, CaseIterable {
    case textAndNumbers = "Text and numbers"
    case entireArea = "Entire area"
}

enum ScreenshotEditorKeys {
    static let tools: [(key: String, title: String, tool: ScreenshotTool)] = [
        ("a", "Arrow", .arrow), ("r", "Rectangle", .rectangle),
        ("o", "Oval", .ellipse), ("p", "Pen", .pen), ("t", "Text", .text),
        ("b", "Blur text and numbers", .blur), ("n", "Numbered steps", .counter)
    ]
}

struct ScreenshotAnnotation {
    let id: UUID
    var tool: ScreenshotTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String
    var textWidth: CGFloat?
    var patch: CGImage?

    init(tool: ScreenshotTool, points: [CGPoint], color: NSColor = .systemRed,
         width: CGFloat = 3, text: String = "", patch: CGImage? = nil) {
        self.id = UUID(); self.tool = tool; self.points = points
        self.color = color; self.width = width; self.text = text; self.patch = patch
    }

    var rect: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, point in
            CGRect(x: min(result.minX, point.x), y: min(result.minY, point.y),
                   width: max(result.maxX, point.x) - min(result.minX, point.x),
                   height: max(result.maxY, point.y) - min(result.minY, point.y))
        }
    }
}

/// Document coordinates are bottom-left screen points, independent of Retina scale.
enum ScreenshotGeometry {
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func pixelRect(_ rect: CGRect, size: CGSize, pixels: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .null }
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, !clipped.isEmpty else { return .null }
        return CGRect(x: clipped.minX * pixels.width / size.width,
                      y: (size.height - clipped.maxY) * pixels.height / size.height,
                      width: clipped.width * pixels.width / size.width,
                      height: clipped.height * pixels.height / size.height).integral
            .intersection(CGRect(origin: .zero, size: pixels))
    }

    static func toolbarFrame(selection: CGRect, screen: CGRect, size: CGSize, safeAreaTop: CGFloat = 0) -> CGRect {
        let screen = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - safeAreaTop)
        let x = min(max(screen.minX + 8, selection.maxX - size.width), screen.maxX - size.width - 8)
        let below = selection.minY - size.height - 10
        let y = below >= screen.minY + 8 ? below : selection.maxY + 10
        return CGRect(x: max(screen.minX, x), y: max(screen.minY + 8, min(y, screen.maxY - size.height - 8)),
                      width: min(size.width, screen.width), height: size.height)
    }

    static func toolSettingsFrame(toolbar: CGRect, selection: CGRect, screen: CGRect, size: CGSize, safeAreaTop: CGFloat = 0) -> CGRect {
        let screen = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: screen.height - safeAreaTop)
        let below = toolbar.minY - size.height - 6, above = toolbar.maxY + 6
        let preferred = toolbar.midY < selection.midY ? below : above
        let other = toolbar.midY < selection.midY ? above : below
        let y = preferred >= screen.minY + 8 && preferred + size.height <= screen.maxY - 8 ? preferred : other
        return CGRect(x: max(screen.minX + 8, min(toolbar.minX, screen.maxX - size.width - 8)),
                      y: max(screen.minY + 8, min(y, screen.maxY - size.height - 8)),
                      width: min(size.width, screen.width - 16), height: size.height)
    }
}

struct ScreenshotDisplayLayout: Equatable {
    let id: UInt32
    let frame: CGRect
    let scale: CGFloat
    init(screen: NSScreen) {
        id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        frame = screen.frame; scale = screen.backingScaleFactor
    }
}

enum ScreenshotImageError: LocalizedError {
    case rendering, emptySelection, noText
    var errorDescription: String? {
        switch self {
        case .rendering: return "The screenshot could not be prepared. Try a smaller area."
        case .emptySelection: return "Select an area first."
        case .noText: return "No text or numbers were found. Try Entire area, or select a larger area."
        }
    }
}

enum ScreenshotRenderer {
    // Reuse the hardware renderer instead of creating a software context per gesture.
    // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
    private static let blurContext = CIContext(options: [.cacheIntermediates: false])
    static func draw(_ annotation: ScreenshotAnnotation, in context: CGContext, bounds: CGRect) {
        let points = annotation.points
        guard let start = points.first else { return }
        let end = points.last ?? start, rect = annotation.rect
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)
        context.setLineWidth(annotation.width)
        context.setLineCap(.round); context.setLineJoin(.round)
        switch annotation.tool {
        case .arrow:
            context.move(to: start); context.addLine(to: end); context.strokePath()
            let angle = atan2(end.y - start.y, end.x - start.x), length = max(12, annotation.width * 4)
            for offset in [CGFloat(-0.5), CGFloat(0.5)] {
                context.move(to: CGPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset)))
                context.addLine(to: end); context.strokePath()
            }
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .pen:
            context.move(to: start)
            for point in points.dropFirst() { context.addLine(to: point) }
            if points.count == 1 { context.addLine(to: CGPoint(x: start.x + 0.1, y: start.y)) }
            context.strokePath()
        case .blur:
            if let patch = annotation.patch { context.interpolationQuality = .high; context.draw(patch, in: rect) }
        case .text, .counter:
            let old = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            defer { NSGraphicsContext.current = old }
            if annotation.tool == .counter {
                let circle = CGRect(x: start.x - 14, y: start.y - 14, width: 28, height: 28)
                context.fillEllipse(in: circle)
                let value = NSAttributedString(string: annotation.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white
                ])
                let size = value.size()
                value.draw(at: CGPoint(x: start.x - size.width / 2, y: start.y - size.height / 2))
            } else {
                let value = NSAttributedString(string: annotation.text, attributes: ScreenshotTextLayout.attributes(annotation))
                var frame = ScreenshotTextLayout.frame(annotation)
                frame.size.width = annotation.textWidth ?? max(1, frame.width)
                value.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        case .select: break
        }
    }

    static func image(source: CGImage, size: CGSize, annotations: [ScreenshotAnnotation], crop: CGRect) throws -> CGImage {
        let pixelRect = ScreenshotGeometry.pixelRect(crop, size: size, pixels: CGSize(width: source.width, height: source.height))
        guard !pixelRect.isNull, !pixelRect.isEmpty, let cropped = source.cropping(to: pixelRect) else { throw ScreenshotImageError.emptySelection }
        guard !annotations.isEmpty else { return cropped }
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotImageError.rendering }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        context.scaleBy(x: CGFloat(source.width) / size.width, y: CGFloat(source.height) / size.height)
        context.translateBy(x: -pixelRect.minX * size.width / CGFloat(source.width),
                            y: -(CGFloat(source.height) - pixelRect.maxY) * size.height / CGFloat(source.height))
        for annotation in annotations { draw(annotation, in: context, bounds: CGRect(origin: .zero, size: size)) }
        guard let result = context.makeImage() else { throw ScreenshotImageError.rendering }
        return result
    }

    /// Composite replacement pixels before encoding. Export never carries editable originals.
    static func blurred(_ image: CGImage, boxes: [CGRect]) throws -> CGImage {
        guard !boxes.isEmpty else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var groups: [Int: [CGRect]] = [:]
        for box in boxes {
            let pixels = CGRect(x: box.minX * bounds.width, y: box.minY * bounds.height,
                                width: box.width * bounds.width, height: box.height * bounds.height)
                .insetBy(dx: -3, dy: -3).intersection(bounds)
            guard !pixels.isEmpty, !pixels.isNull else { continue }
            let entireArea = boxes.count == 1 && box == CGRect(x: 0, y: 0, width: 1, height: 1)
            let strength = entireArea ? max(14, min(bounds.width, bounds.height) * 0.06) : max(12, min(256, box.height * bounds.height * 0.65))
            let radius = Int(ceil(strength / 4)) * 4
            groups[radius, default: []].append(pixels)
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ScreenshotImageError.rendering }
        context.draw(image, in: bounds)
        let ci = CIImage(cgImage: image)
        // Stronger masks go last so a small overlapping detection cannot reveal large text.
        for radius in groups.keys.sorted() {
            try Task.checkCancellation()
            let regions = groups[radius]!
            let extent = regions.reduce(CGRect.null) { $0.union($1) }.integral.intersection(bounds)
            let filtered = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            guard let blurred = blurContext.createCGImage(filtered, from: extent) else { throw ScreenshotImageError.rendering }
            context.saveGState()
            for region in regions {
                let corner: CGFloat = region == bounds ? 0 : min(3, region.height * 0.18)
                context.addPath(CGPath(roundedRect: region, cornerWidth: corner, cornerHeight: corner, transform: nil))
            }
            context.clip(); context.draw(blurred, in: extent); context.restoreGState()
        }
        guard let result = context.makeImage() else { throw ScreenshotImageError.rendering }
        return result
    }
}

enum ScreenshotTextDetector {
    /// Accurate system OCR is used only for an explicit Copy text action.
    /// Keep correction off so numbers and codes are not rewritten.
    // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
    static func text(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = false
        recognition.automaticallyDetectsLanguage = true
        recognition.minimumTextHeight = 0
        let supported = try recognition.supportedRecognitionLanguages()
        let languages = ["en-US", "ru-RU"].filter { supported.contains($0) }
        if !languages.isEmpty { recognition.recognitionLanguages = languages }
        try useCPU(recognition)
        let input = try recognitionImage(image)
        try Task.checkCancellation()
        try VNImageRequestHandler(cgImage: input, options: [:]).perform([recognition])
        try Task.checkCancellation()
        return (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Avoid the accurate recognizer's per-build cold start. An isolated-glyph pass
    /// supplements fast text regions without loading that model.
    static func boxes(_ image: CGImage) throws -> [CGRect] {
        let image = try recognitionImage(image)
        let detection = VNDetectTextRectanglesRequest()
        detection.reportCharacterBoxes = false
        let recognition = fastRequest()
        try useCPU(detection)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([detection, recognition])
        let boxes = (detection.results ?? []).map(\.boundingBox) + (recognition.results ?? []).map(\.boundingBox)
        try Task.checkCancellation()
        return boxes + (try ScreenshotGlyphDetector.boxes(in: image, excluding: boxes))
    }

    static func fastRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast; request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false; request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0
        return request
    }

    static func useCPU(_ request: VNRequest) throws {
        for (stage, devices) in try request.supportedComputeStageDevices {
            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                request.setComputeDevice(cpu, for: stage)
            }
        }
    }

    static func recognitionImage(_ image: CGImage) throws -> CGImage {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let corners = [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)]
        let brightness = corners.compactMap { x, y -> CGFloat? in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
            return color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722
        }
        guard !brightness.isEmpty, brightness.reduce(0, +) / CGFloat(brightness.count) < 0.45 else { return image }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenshotImageError.rendering
        }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: bounds)
        context.setBlendMode(.difference); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        guard let inverted = context.makeImage() else { throw ScreenshotImageError.rendering }
        return inverted
    }
}
