import AppKit
import XCTest
import Vision
@testable import Sidekey

@MainActor
final class ScreenshotTests: XCTestCase {
    private func fixture(width: Int = 800, height: Int = 400, text: Bool = true) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if text {
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 44, weight: .medium), .foregroundColor: NSColor.black]
            ("Invoice" as NSString).draw(at: CGPoint(x: 55, y: 290), withAttributes: attributes)
            ("401" as NSString).draw(at: CGPoint(x: 580, y: 190), withAttributes: attributes)
            ("123456" as NSString).draw(at: CGPoint(x: 55, y: 75), withAttributes: attributes)
            NSGraphicsContext.current = previous
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                                 bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    func testRetinaCropClipsToImageAndFlipsOnlyTheCropOrigin() {
        let size = CGSize(width: 1000, height: 500), pixels = CGSize(width: 2000, height: 1000)
        XCTAssertEqual(ScreenshotGeometry.pixelRect(CGRect(x: 100, y: 300, width: 200, height: 100), size: size, pixels: pixels),
                       CGRect(x: 200, y: 200, width: 400, height: 200))
        XCTAssertEqual(ScreenshotGeometry.pixelRect(CGRect(x: -10, y: -10, width: 30, height: 30), size: size, pixels: pixels),
                       CGRect(x: 0, y: 960, width: 40, height: 40))
        XCTAssertTrue(ScreenshotGeometry.pixelRect(CGRect(x: 2000, y: 1000, width: 10, height: 10), size: size, pixels: pixels).isNull)
    }

    func testCaptureRequestsFullRetinaPixelsInsteadOfLogicalDisplayDimensions() {
        // The affected display reports 1728×1117 from CGDisplayPixelsWide/High,
        // while ScreenCaptureKit supplies a 2× pixel scale.
        let retina = ScreenshotCaptureConfiguration.make(contentRect: CGRect(x: 0, y: 0, width: 1728, height: 1117), pointPixelScale: 2)
        XCTAssertEqual(retina.width, 3456)
        XCTAssertEqual(retina.height, 2234)
        XCTAssertEqual(retina.captureResolution, .best)
        XCTAssertFalse(retina.scalesToFit)
        XCTAssertFalse(retina.showsCursor)
        let external = ScreenshotCaptureConfiguration.make(contentRect: CGRect(x: -1920, y: 100, width: 1920, height: 1080), pointPixelScale: 1)
        XCTAssertEqual(external.width, 1920)
        XCTAssertEqual(external.height, 1080)
    }

    func testRetinaPNGKeepsOriginalPointSizeWithoutDroppingPixels() throws {
        let source = try fixture(text: false)
        let encoded = try ScreenshotDownload.png(source, scale: 2)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: encoded))
        XCTAssertEqual(decoded.pixelsWide, source.width); XCTAssertEqual(decoded.pixelsHigh, source.height)
        XCTAssertEqual(decoded.size.width, CGFloat(source.width) / 2, accuracy: 0.05)
        XCTAssertEqual(decoded.size.height, CGFloat(source.height) / 2, accuracy: 0.05)
        XCTAssertEqual(try pixels(try XCTUnwrap(decoded.cgImage)), try pixels(source))
    }

    func testToolbarFitsNegativeOriginDisplayAndMovesAboveBottomSelection() {
        let screen = CGRect(x: -1440, y: -200, width: 1440, height: 900)
        let selection = CGRect(x: -1435, y: -195, width: 50, height: 40)
        let frame = ScreenshotGeometry.toolbarFrame(selection: selection, screen: screen, size: CGSize(width: 450, height: 85))
        XCTAssertTrue(screen.contains(frame)); XCTAssertGreaterThan(frame.minY, selection.maxY)
        let narrow = ScreenshotGeometry.toolbarFrame(selection: .zero, screen: CGRect(x: 0, y: 0, width: 400, height: 300), size: CGSize(width: 450, height: 85))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 400, height: 300).contains(narrow))
    }

    func testBlurDetectionFindsWordsAndStandaloneNumbers() throws {
        let boxes = try ScreenshotTextDetector.boxes(fixture())
        for point in [CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.775, y: 0.54), CGPoint(x: 0.17, y: 0.25)] {
            XCTAssertTrue(boxes.contains { $0.contains(point) }, "Missing text or standalone digits near \(point)")
        }
        XCTAssertTrue(try ScreenshotTextDetector.boxes(fixture(text: false)).isEmpty)
    }

    func testCopyTextRecognizesEnglishCyrillicAndCodesOnLightAndDarkRetinaImages() throws {
        for dark in [false, true] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1000, height: 400, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: 2, y: 2)
            context.setFillColor((dark ? NSColor.black : .white).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 500, height: 200))
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 26),
                .foregroundColor: dark ? NSColor.white : NSColor.black]
            ("Invoice 401" as NSString).draw(at: CGPoint(x: 30, y: 130), withAttributes: attributes)
            ("Привет мир 123456" as NSString).draw(at: CGPoint(x: 30, y: 50), withAttributes: attributes)
            NSGraphicsContext.current = previous
            let text = try ScreenshotTextDetector.text(XCTUnwrap(context.makeImage()))
            for expected in ["Invoice", "401", "Привет", "мир", "123456"] {
                XCTAssertTrue(text.contains(expected), "Missing \(expected), dark=\(dark)")
            }
        }
    }

    func testCopyTextUsesOnlyFlattenedCropAndCannotReadCoveredPixels() throws {
        let source = try fixture(), size = CGSize(width: 800, height: 400)
        let crop = CGRect(x: 0, y: 0, width: 400, height: 160)
        let selected = try ScreenshotRenderer.image(source: source, size: size, annotations: [], crop: crop)
        let text = try ScreenshotTextDetector.text(selected)
        XCTAssertTrue(text.contains("123456")); XCTAssertFalse(text.contains("Invoice")); XCTAssertFalse(text.contains("401"))
        let cover = ScreenshotAnnotation(tool: .blur, points: [crop.origin, CGPoint(x: crop.maxX, y: crop.maxY)],
                                         patch: try fixture(width: 400, height: 160, text: false))
        let covered = try ScreenshotRenderer.image(source: source, size: size, annotations: [cover], crop: crop)
        XCTAssertTrue(try ScreenshotTextDetector.text(covered).isEmpty)
        let placed = ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 40, y: 60)], color: .black, width: 5, text: "PLACED 902")
        let edited = try ScreenshotRenderer.image(source: source, size: size, annotations: [cover, placed], crop: crop)
        XCTAssertTrue(try ScreenshotTextDetector.text(edited).contains("PLACED 902"))
    }

    func testBlurDetectionIncludesSmallDigitsAndCyrillicInBothAppearances() throws {
        for scale in [1, 2] {
            for dark in [false, true] {
                let context = try XCTUnwrap(CGContext(data: nil, width: 500 * scale, height: 180 * scale, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                context.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: 500, height: 180))
                let previous = NSGraphicsContext.current
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14),
                    .foregroundColor: dark ? NSColor.white : NSColor.black]
                for (text, x) in [("7", 20), ("42", 100), ("12 345 ₽", 200), ("Счёт 01", 350)] {
                    (text as NSString).draw(at: CGPoint(x: x, y: 80), withAttributes: attributes)
                }
                NSGraphicsContext.current = previous
                let boxes = try ScreenshotTextDetector.boxes(XCTUnwrap(context.makeImage()))
                for x in [24.0, 108, 220, 370] {
                    let point = CGPoint(x: x / 500, y: 88.0 / 180)
                    XCTAssertTrue(boxes.contains { $0.insetBy(dx: -0.005, dy: -0.01).contains(point) }, "Missing \(x) at \(scale)x, dark=\(dark)")
                }
            }
        }
    }

    func testCropFirstCompositingMatchesFullFrameReferenceAtFractionalRetinaCrop() throws {
        let source = try fixture(), size = CGSize(width: 400, height: 200)
        let crop = CGRect(x: 30.25, y: 20.75, width: 310.5, height: 160.5)
        let annotations = [ScreenshotAnnotation(tool: .arrow, points: [CGPoint(x: 50, y: 50), CGPoint(x: 250, y: 110)]),
                           ScreenshotAnnotation(tool: .text, points: [CGPoint(x: 80, y: 130)], text: "Test 123"),
                           ScreenshotAnnotation(tool: .ellipse, points: [CGPoint(x: 80, y: 70), CGPoint(x: 200, y: 140)])]
        let reference = try XCTUnwrap(CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reference.scaleBy(x: 2, y: 2); reference.draw(source, in: CGRect(origin: .zero, size: size))
        for annotation in annotations { ScreenshotRenderer.draw(annotation, in: reference, bounds: CGRect(origin: .zero, size: size)) }
        let expected = try XCTUnwrap(reference.makeImage()?.cropping(to: ScreenshotGeometry.pixelRect(crop, size: size, pixels: CGSize(width: source.width, height: source.height))))
        let actual = try ScreenshotRenderer.image(source: source, size: size, annotations: annotations, crop: crop)
        XCTAssertEqual(try pixels(actual), try pixels(expected))
    }

    func testIsolatedDigitsAcrossFontSizesAndRetinaScales() throws {
        for scale in [1, 2] { for fontSize: CGFloat in [11, 14, 18] { for dark in [false, true] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 500 * scale, height: 100 * scale, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.setFillColor((dark ? NSColor.black : NSColor.white).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 500, height: 100))
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            for (digit, x) in [("7", 40), ("3", 150), ("1", 260), ("9", 370)] {
                (digit as NSString).draw(at: CGPoint(x: x, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: fontSize),
                    .foregroundColor: dark ? NSColor.white : NSColor.black])
            }
            NSGraphicsContext.current = previous
            let boxes = try ScreenshotTextDetector.boxes(XCTUnwrap(context.makeImage()))
            for x: CGFloat in [40, 150, 260, 370] {
                let point = CGPoint(x: (x + fontSize * 0.3) / 500, y: (40 + fontSize * 0.6) / 100)
                XCTAssertTrue(boxes.contains { $0.insetBy(dx: -0.005, dy: -0.01).contains(point) }, "Missing digit at \(x), \(fontSize)pt, \(scale)x, dark=\(dark)")
            }
        } } }
    }

    func testLargeTextGetsItsOwnBlurStrengthBesideSmallLabels() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1400, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1400, height: 640))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("$48,213.07" as NSString).draw(at: CGPoint(x: 40, y: 380), withAttributes: [.font: NSFont.systemFont(ofSize: 128), .foregroundColor: NSColor.black])
        for index in 0..<8 {
            ("Small label \(index)" as NSString).draw(at: CGPoint(x: 40 + (index % 2) * 500, y: 40 + (index / 2) * 60),
                withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.current = previous
        let source = try XCTUnwrap(context.makeImage())
        let result = try ScreenshotRenderer.blurred(source, boxes: ScreenshotTextDetector.boxes(source))
        let readable = try ScreenshotTextDetector.analyze(result, detectAdditionalBoxes: false).text.filter(\.isNumber)
        XCTAssertFalse(readable.contains("4821307"), "Small labels must not weaken the large amount's mask")
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_TEST_RENDER_DIR"] {
            try ScreenshotDownload.png(result).write(to: URL(fileURLWithPath: directory).appendingPathComponent("blur-mixed-font-sizes.png"))
        }
    }

    func testDownloadUsesReadableUniquePNGNamesAndPreservesExistingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotDownloadTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try ScreenshotDownload.png(fixture()), date = Date(timeIntervalSince1970: 1_792_500_000)
        let first = try ScreenshotDownload.write(data, directory: directory, date: date)
        let second = try ScreenshotDownload.write(Data([1, 2, 3]), directory: directory, date: date)
        XCTAssertTrue(first.lastPathComponent.hasPrefix("Screenshot 2026-10-"))
        XCTAssertEqual(first.pathExtension, "png")
        XCTAssertEqual(second.deletingPathExtension().lastPathComponent, first.deletingPathExtension().lastPathComponent + " (2)")
        XCTAssertEqual(try Data(contentsOf: first), data)
        XCTAssertEqual(try Data(contentsOf: second), Data([1, 2, 3]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2, "Publishing leaves no staging files")
        XCTAssertThrowsError(try ScreenshotDownload.write(data, directory: first, date: date))
    }

    func testPackagedPermissionCopyDescribesOnlyExplicitScreenshotUse() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist.template"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let description = try XCTUnwrap(plist["NSScreenCaptureUsageDescription"] as? String)
        XCTAssertTrue(description.contains("only when you choose Screenshot"))
        XCTAssertTrue(description.contains("text and numbers"))
        XCTAssertFalse(description.contains("context"))
    }

    func testTextBlurChangesOnlyDetectedRegionsAndLeavesBackgroundUntouched() throws {
        let source = try fixture(), result = try ScreenshotTextDetector.analyze(source)
        let blurred = try ScreenshotRenderer.blurred(source, boxes: result.boxes)
        let before = try pixels(source), after = try pixels(blurred)
        XCTAssertNotEqual(before, after)
        // Icon / separator stand-ins outside all recognized text remain pixel-identical.
        for y in [10, 350, 390] {
            for x in [10, 400, 790] {
                let offset = (y * source.width + x) * 4
                XCTAssertEqual(Array(before[offset..<offset+4]), Array(after[offset..<offset+4]))
            }
        }
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: blurred).representation(using: .png, properties: [:]))
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png)?.cgImage)
        XCTAssertEqual(try pixels(decoded), after, "Export must contain the modified pixels")
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_TEST_RENDER_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try ScreenshotDownload.png(source).write(to: URL(fileURLWithPath: directory).appendingPathComponent("blur-before.png"))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("blur-after.png"))
        }
    }

    func testRenderedPatchAndCropPreserveOriginalOrientationAtRetinaScale() throws {
        let source = try fixture()
        let size = CGSize(width: 400, height: 200), crop = CGRect(x: 270, y: 90, width: 90, height: 50)
        let patch = try ScreenshotRenderer.image(source: source, size: size, annotations: [], crop: crop)
        let text = try ScreenshotTextDetector.analyze(patch).text
        XCTAssertTrue(text.contains("401"))
        let blurred = try ScreenshotRenderer.blurred(patch, boxes: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        let annotation = ScreenshotAnnotation(tool: .blur, points: [crop.origin, CGPoint(x: crop.maxX, y: crop.maxY)], patch: blurred)
        let rendered = try ScreenshotRenderer.image(source: source, size: size, annotations: [annotation], crop: crop)
        XCTAssertEqual(rendered.width, patch.width); XCTAssertEqual(rendered.height, patch.height)
        XCTAssertNotEqual(try pixels(rendered), try pixels(patch))
        let outside = CGRect(x: 0, y: 130, width: 200, height: 70)
        let before = try ScreenshotRenderer.image(source: source, size: size, annotations: [], crop: outside)
        let after = try ScreenshotRenderer.image(source: source, size: size, annotations: [annotation], crop: outside)
        XCTAssertEqual(try pixels(before), try pixels(after))
    }

    func testUndoRedoRetainsBlurPixelsAndSelection() throws {
        let source = try fixture(), canvas = ScreenshotCanvas(image: source, size: CGSize(width: 800, height: 400))
        canvas.selection = canvas.bounds
        let blurred = try ScreenshotRenderer.blurred(source, boxes: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        canvas.commit(ScreenshotAnnotation(tool: .blur, points: [.zero, CGPoint(x: 800, y: 400)], patch: blurred))
        XCTAssertTrue(canvas.canUndo); XCTAssertEqual(canvas.annotations.count, 1)
        canvas.undo(); XCTAssertTrue(canvas.annotations.isEmpty); XCTAssertTrue(canvas.canRedo)
        canvas.redo(); XCTAssertEqual(canvas.annotations.count, 1)
        XCTAssertEqual(canvas.selection, canvas.bounds)
        XCTAssertTrue(canvas.annotations[0].patch === blurred)
        canvas.busy = true; canvas.undo(); XCTAssertEqual(canvas.annotations.count, 1)
    }

    func testScreenshotSearchAndActivationAreIndependentOfPinnedLayout() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "скриншот"), [.screenshot])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "blur text numbers"), [.screenshot])
        XCTAssertEqual(HoverSlotRouter.effect(for: .screenshot), .openScreenshot)
        XCTAssertFalse(HoverSlotRouter.effect(for: .screenshot).requiresExpansion)
        var calls = 0, actions = IslandActions.noOp
        actions.openScreenshot = { calls += 1 }
        HoverSlotRouter.effect(for: .screenshot).invoke(on: actions)
        XCTAssertEqual(calls, 1)
    }

    func testRealCanvasGesturesSelectCropAndRequestTextAndNumberBlur() throws {
        let canvas = ScreenshotCanvas(image: try fixture(), size: CGSize(width: 800, height: 400))
        let window = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 800, height: 400),
                                             styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = canvas; window.keyboardCanvas = canvas
        defer { window.contentView = nil; window.close() }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func drag(_ start: CGPoint, _ end: CGPoint) throws {
            canvas.mouseDown(with: try event(.leftMouseDown, start))
            canvas.mouseDragged(with: try event(.leftMouseDragged, end))
            canvas.mouseUp(with: try event(.leftMouseUp, end))
        }
        try drag(CGPoint(x: 10, y: 20), CGPoint(x: 750, y: 380))
        XCTAssertEqual(canvas.selection, CGRect(x: 10, y: 20, width: 740, height: 360))
        var requests: [(CGRect, ScreenshotBlurMode)] = []
        canvas.onBlur = { requests.append(($0, $1)) }
        canvas.selectTool(.blur)
        try drag(CGPoint(x: 540, y: 180), CGPoint(x: 700, y: 250))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].0, CGRect(x: 540, y: 180, width: 160, height: 70))
        XCTAssertEqual(requests[0].1, .textAndNumbers)
        canvas.busy = true
        try drag(CGPoint(x: 540, y: 180), CGPoint(x: 700, y: 250))
        XCTAssertEqual(requests.count, 1)
        canvas.busy = false; canvas.undo()
        XCTAssertTrue(canvas.selection.isEmpty); XCTAssertEqual(canvas.tool, .select)
        try drag(CGPoint(x: 40, y: 50), CGPoint(x: 300, y: 200))
        XCTAssertEqual(canvas.selection, CGRect(x: 40, y: 50, width: 260, height: 150))
        XCTAssertFalse(window.isVisible)
    }

    func testScreenshotKeyboardCommandsAndHelpAgree() throws {
        let canvas = ScreenshotCanvas(image: try fixture(), size: CGSize(width: 800, height: 400))
        var copiesWithoutSelection = 0
        canvas.onCommand = { if case .copy = $0 { copiesWithoutSelection += 1 } }
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        canvas.keyDown(with: enter)
        XCTAssertTrue(canvas.selection.isEmpty); XCTAssertEqual(copiesWithoutSelection, 0)
        XCTAssertTrue(canvas.message.isEmpty, "The passive instruction banner is removed")
        XCTAssertFalse(HelpWindowContent.hotkeyRows.contains { $0.title == "Screenshot — full display" })
        let crop = CGRect(x: 50, y: 50, width: 400, height: 200)
        canvas.selection = crop
        for entry in ScreenshotEditorKeys.tools {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                       windowNumber: 0, context: nil, characters: entry.key,
                                                       charactersIgnoringModifiers: entry.key, isARepeat: false, keyCode: 0))
            canvas.keyDown(with: event)
            XCTAssertEqual(canvas.tool, entry.tool)
            XCTAssertTrue(HelpWindowContent.hotkeyRows.contains { $0.title == "Screenshot — \(entry.title)" })
        }
        canvas.selectTool(.arrow)
        for key in ["v", "m"] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: key,
                                                      charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0))
            canvas.keyDown(with: event)
            XCTAssertEqual(canvas.tool, .arrow, "Removed shortcuts must not select hidden tools")
        }
        XCTAssertFalse(HelpWindowContent.hotkeyRows.contains { ["Screenshot — Select & crop", "Screenshot — Highlighter"].contains($0.title) })
        var copyRequests = 0
        canvas.onCommand = { command in if case .copy = command { copyRequests += 1 } }
        let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                                 windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        // The coordinator queues Copy during Blur and refuses unfinished pixels.
        canvas.busy = true; XCTAssertTrue(canvas.performKeyEquivalent(with: copy)); XCTAssertEqual(copyRequests, 1)
        canvas.busy = false; XCTAssertTrue(canvas.performKeyEquivalent(with: copy)); XCTAssertEqual(copyRequests, 2)
        canvas.keyDown(with: enter); XCTAssertEqual(copyRequests, 3)
        canvas.busy = true; canvas.keyDown(with: enter); XCTAssertEqual(copyRequests, 4)
        XCTAssertEqual(canvas.selection, crop)
    }

    func testAllToolbarCommandsAndSeparateSettingsFitWithoutOpeningApp() throws {
        _ = NSApplication.shared
        let suite = "ScreenshotTests.\(UUID().uuidString)", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = ScreenshotCanvas(image: try fixture(), size: CGSize(width: 800, height: 400))
        canvas.selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        canvas.selectTool(.blur)
        let toolbar = ScreenshotToolbar(canvas: canvas, defaults: defaults)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 500, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        let settingsWindow = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = toolbar
        settingsWindow.isReleasedWhenClosed = false; settingsWindow.contentView = toolbar.toolSettings
        defer { window.contentView = nil; window.close(); settingsWindow.contentView = nil; settingsWindow.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let buttons = descendants(toolbar).compactMap { $0 as? NSButton }
        let settings = descendants(toolbar.toolSettings)
        XCTAssertTrue(buttons.contains { $0.title == "Blur" && $0.state == .on && $0.image == nil })
        XCTAssertTrue(buttons.contains { $0.toolTip?.hasPrefix("Download to Downloads") == true && $0.title.isEmpty && $0.image != nil })
        XCTAssertFalse(buttons.contains { $0.toolTip == "More tools" })
        XCTAssertEqual(buttons.count, 17, "Thirteen tools/actions including Copy text plus four inline arrow assignment controls")
        for removed in ["Select & crop", "Highlighter", "Spotlight", "Pin above windows", "Output size"] {
            XCTAssertFalse(buttons.contains { $0.toolTip?.hasPrefix(removed) == true }, removed)
        }
        for tool in [ScreenshotTool.arrow, .rectangle, .pen, .text, .blur, .counter] {
            XCTAssertTrue(buttons.contains { $0.identifier?.rawValue == tool.rawValue })
        }
        for label in ["Copy text", "Share", "Undo", "Redo", "Cancel capture"] {
            XCTAssertTrue(buttons.contains { $0.toolTip?.hasPrefix(label) == true }, label)
        }
        let arrow = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "arrow" })
        arrow.performClick(nil); toolbar.refresh()
        XCTAssertEqual(canvas.tool, .arrow); XCTAssertEqual(arrow.state, .on)
        arrow.performClick(nil); toolbar.refresh()
        XCTAssertEqual(canvas.tool, .select); XCTAssertEqual(arrow.state, .off)
        let shape = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "rectangle" })
        shape.performClick(nil); canvas.selectTool(.ellipse); toolbar.refresh()
        XCTAssertEqual(shape.state, .on)
        shape.performClick(nil); toolbar.refresh()
        XCTAssertEqual(canvas.tool, .select); XCTAssertEqual(shape.state, .off)
        XCTAssertEqual(canvas.selection, CGRect(x: 100, y: 100, width: 200, height: 100))
        canvas.selectTool(.blur); toolbar.refresh()
        XCTAssertFalse(descendants(toolbar).contains { $0 is NSColorWell || $0 is NSPopUpButton || $0 is NSTextField })
        let mode = try XCTUnwrap(settings.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("Text and numbers") })
        XCTAssertEqual(mode.titleOfSelectedItem, "Text and numbers")
        XCTAssertEqual(mode.itemTitles, ["Text and numbers", "Entire area"])
        let copy = try XCTUnwrap(buttons.first { $0.title == "Copy & exit" })
        XCTAssertEqual(copy.accessibilityLabel(), "Copy screenshot and exit")
        let download = try XCTUnwrap(buttons.first { $0.toolTip?.hasPrefix("Download to Downloads") == true })
        let copyText = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "command.copyText" })
        var textRequests = 0, copyRequests = 0
        toolbar.onCommand = {
            if case .copyText = $0 { textRequests += 1 }
            if case .copy = $0 { copyRequests += 1 }
        }
        copyText.performClick(nil)
        XCTAssertEqual(textRequests, 1)
        XCTAssertTrue(toolbar.focusableControls.contains(copyText))
        XCTAssertFalse(settings.compactMap { $0 as? NSTextField }.contains { $0.isEditable }, "Text is entered on the canvas")
        XCTAssertEqual(copyRequests, 0)
        let directory = ProcessInfo.processInfo.environment["SCREENSHOT_TEST_RENDER_DIR"]
        if let directory { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        for tool in ScreenshotTool.allCases {
            canvas.selectTool(tool); toolbar.refresh()
            settingsWindow.setContentSize(toolbar.toolSettings.fittingSize); toolbar.toolSettings.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(toolbar.toolSettings.fittingSize.width, 304, "Settings must fit beside a 320 pt display")
            for control in settings.compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
                let frame = control.alignmentRect(forFrame: toolbar.toolSettings.convert(control.bounds, from: control))
                XCTAssertGreaterThanOrEqual(frame.minX, 10)
                XCTAssertLessThanOrEqual(frame.maxX, toolbar.toolSettings.bounds.maxX - 10)
            }
            for availableWidth: CGFloat in [1440, 1024, 768, 640, 390, 320] {
                toolbar.configure(availableWidth: availableWidth)
                window.setContentSize(toolbar.fittingSize); toolbar.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(toolbar.fittingSize.width, availableWidth - 16)
                for button in buttons {
                    let frame = toolbar.convert(button.bounds, from: button)
                    XCTAssertTrue(toolbar.bounds.contains(frame), "Clipped control \(button.toolTip ?? button.title), width \(availableWidth), frame \(frame), bounds \(toolbar.bounds)")
                }
                XCTAssertTrue(copy.isEnabled); XCTAssertTrue(download.isEnabled); XCTAssertTrue(copyText.isEnabled)
                if let directory, tool == .select || availableWidth == 1024 {
                    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                        window.appearance = NSAppearance(named: appearance)
                        settingsWindow.appearance = NSAppearance(named: appearance)
                        try render(toolbar, to: directory, name: "toolbar-\(tool.rawValue)-\(name)-\(Int(availableWidth))")
                        if !toolbar.toolSettings.isHidden {
                            try render(toolbar.toolSettings, to: directory, name: "settings-\(tool.rawValue)-\(name)")
                        }
                    }
                }
            }
        }
        canvas.busy = true; toolbar.refresh()
        XCTAssertFalse(copy.isEnabled); XCTAssertFalse(download.isEnabled); XCTAssertFalse(copyText.isEnabled)
        copyText.performClick(nil); XCTAssertEqual(textRequests, 1, "Busy text extraction cannot start a second request")
        XCTAssertTrue(buttons.contains { $0.toolTip?.hasPrefix("Cancel capture") == true && $0.isEnabled })
        XCTAssertFalse(window.isVisible); XCTAssertFalse(settingsWindow.isVisible)
    }

    private func render(_ view: NSView, to directory: String, name: String) throws {
        view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
    }
}

// Independent accurate-OCR oracle for Blur regressions.
private struct ScreenshotTextAnalysis {
    let boxes: [CGRect]
    let text: String
}

private extension ScreenshotTextDetector {
    /// Vision stays on device. Correction is off so standalone numbers and codes survive.
    // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
    static func analyze(_ image: CGImage, detectAdditionalBoxes: Bool = true) throws -> ScreenshotTextAnalysis {
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.usesLanguageCorrection = false
        recognition.automaticallyDetectsLanguage = true
        recognition.minimumTextHeight = 0
        let supported = try recognition.supportedRecognitionLanguages()
        let languages = ["en-US", "ru-RU"].filter { supported.contains($0) }
        if !languages.isEmpty { recognition.recognitionLanguages = languages }
        let detection = VNDetectTextRectanglesRequest()
        detection.reportCharacterBoxes = false
        // Small OCR crops are faster on CPU and avoid long accelerator model setup.
        // WHY: .project-docs/decisions/2026-10-20-screenshot-toolbar.md
        try useCPU(recognition)
        if detectAdditionalBoxes { try useCPU(detection) }
        // Dark UI crops use the same geometry with light-background OCR input only.
        // Export and blur always keep the original screenshot colors.
        try VNImageRequestHandler(cgImage: recognitionImage(image), options: [:]).perform(detectAdditionalBoxes ? [recognition, detection] : [recognition])
        let observations = recognition.results ?? []
        var boxes = observations.map(\.boundingBox)
        if detectAdditionalBoxes { boxes += (detection.results ?? []).map(\.boundingBox) }
        return ScreenshotTextAnalysis(boxes: boxes, text: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
    }
}
