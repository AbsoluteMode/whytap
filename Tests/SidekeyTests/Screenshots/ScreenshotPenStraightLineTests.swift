import AppKit
import XCTest
@testable import Sidekey

/// Pen with Shift held draws one straight line from the press, snapped to
/// 45 degrees, like line tools in common image editors.
@MainActor
final class ScreenshotPenStraightLineTests: XCTestCase {
    private let crop = CGRect(x: 20, y: 20, width: 740, height: 360)

    // MARK: - Geometry

    func testAShakyHorizontalDragBecomesExactlyHorizontal() {
        let end = ScreenshotGeometry.straightLineEnd(from: CGPoint(x: 100, y: 100), toward: CGPoint(x: 300, y: 112), within: crop)
        XCTAssertEqual(end.y, 100, accuracy: 0.0001)
        XCTAssertEqual(end.x, 300, accuracy: 0.0001)
    }

    func testANearlyVerticalDragBecomesExactlyVertical() {
        let end = ScreenshotGeometry.straightLineEnd(from: CGPoint(x: 100, y: 100), toward: CGPoint(x: 92, y: 40), within: crop)
        XCTAssertEqual(end.x, 100, accuracy: 0.0001)
        XCTAssertEqual(end.y, 40, accuracy: 0.0001)
    }

    func testADiagonalDragSnapsToFortyFiveDegrees() {
        let end = ScreenshotGeometry.straightLineEnd(from: CGPoint(x: 100, y: 100), toward: CGPoint(x: 200, y: 180), within: crop)
        XCTAssertEqual(end.x - 100, end.y - 100, accuracy: 0.0001)
        XCTAssertGreaterThan(end.x, 100)
    }

    /// The pointer leaves the crop on a diagonal: the line is shortened
    /// along its own direction, never bent by clamping x and y separately.
    func testALineLeavingTheCropIsShortenedNotBent() {
        let end = ScreenshotGeometry.straightLineEnd(from: CGPoint(x: 700, y: 300), toward: CGPoint(x: 900, y: 520), within: crop)
        XCTAssertEqual(end.x - 700, end.y - 300, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(end.x, crop.maxX + 0.0001)
        XCTAssertLessThanOrEqual(end.y, crop.maxY + 0.0001)
        XCTAssertEqual(end.x, crop.maxX, accuracy: 0.0001)
    }

    func testNoMovementStaysAtTheStart() {
        let start = CGPoint(x: 100, y: 100)
        XCTAssertEqual(ScreenshotGeometry.straightLineEnd(from: start, toward: start, within: crop), start)
    }

    // MARK: - Canvas

    func testShiftDragWithPenCommitsOneStraightStroke() throws {
        try withCanvas { canvas, window in
            canvas.selectTool(.pen)
            let start = CGPoint(x: 100, y: 200)
            canvas.mouseDown(with: try event(.leftMouseDown, at: start, window: window))
            for (x, y) in [(150.0, 206.0), (210.0, 193.0), (260.0, 209.0)] {
                canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: x, y: y), shift: true, window: window))
            }
            canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 300, y: 204), shift: true, window: window))

            let stroke = try XCTUnwrap(canvas.annotations.last)
            XCTAssertEqual(stroke.tool, .pen)
            XCTAssertEqual(stroke.points.count, 2)
            XCTAssertEqual(stroke.points[0], start)
            XCTAssertEqual(stroke.points[1].y, start.y, accuracy: 0.0001)
            XCTAssertEqual(stroke.points[1].x, 300, accuracy: 0.0001)
        }
    }

    func testPenWithoutShiftStillDrawsFreehand() throws {
        try withCanvas { canvas, window in
            canvas.selectTool(.pen)
            canvas.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 200), window: window))
            for (x, y) in [(150.0, 206.0), (210.0, 193.0), (260.0, 209.0)] {
                canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: x, y: y), window: window))
            }
            canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 300, y: 204), window: window))

            let stroke = try XCTUnwrap(canvas.annotations.last)
            XCTAssertEqual(stroke.tool, .pen)
            XCTAssertGreaterThan(stroke.points.count, 2)
            XCTAssertTrue(stroke.points.contains(CGPoint(x: 210, y: 193)))
        }
    }

    /// Shift keeps its own meaning for other tools: an arrow is unchanged.
    func testShiftDoesNotChangeArrows() throws {
        try withCanvas { canvas, window in
            canvas.selectTool(.arrow)
            canvas.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 200), window: window))
            canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 300, y: 215), shift: true, window: window))
            let arrow = try XCTUnwrap(canvas.annotations.last)
            XCTAssertEqual(arrow.points, [CGPoint(x: 100, y: 200), CGPoint(x: 300, y: 215)])
        }
    }

    // MARK: - Helpers

    private func withCanvas(_ body: (ScreenshotCanvas, NSWindow) throws -> Void) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvas = ScreenshotCanvas(image: try XCTUnwrap(context.makeImage()), size: CGSize(width: 800, height: 400))
        let window = ScreenshotCapturePanel(contentRect: CGRect(x: -20_000, y: -20_000, width: 800, height: 400),
                                            styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false; window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        canvas.selection = crop
        try body(canvas, window)
        XCTAssertFalse(window.isVisible)
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, shift: Bool = false, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
