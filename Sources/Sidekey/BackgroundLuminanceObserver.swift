import AppKit
import Combine
import CoreGraphics
import Foundation
import os.log

/// Pure orb-palette helper. Sidekey used to sample pixels behind the orb,
/// but that required Screen Recording and produced the system "screen is
/// being observed" indicator. The orb now falls back to system appearance
/// and direct luminance test hooks only.
@MainActor
final class BackgroundLuminanceObserver: ObservableObject {

    static let shared = BackgroundLuminanceObserver()

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "luminance")

    @Published private(set) var isDarkBackground: Bool = false
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var needsCaptureRestart: Bool = false

    private(set) var currentSampleRegion: CGRect?
    private(set) var lastReportedPanelVisible: Bool = true

    static let darkThreshold: Double = 0.40
    static let lightThreshold: Double = 0.60
    static let sampleEdgePt: CGFloat = 100

    private var excludedWindowID: CGWindowID?
    private var sampleScreenFrame: CGRect?
    private var capturedDisplayID: CGDirectDisplayID = 0

    /// Converts a global AppKit/Cocoa rect into a display-local top-left
    /// coordinate rect. Kept for geometry tests and possible future visual
    /// sampling that does not require Screen Recording.
    nonisolated static func displayLocalSourceRect(
        sampleScreenFrame: CGRect,
        displayFrame: CGRect
    ) -> CGRect? {
        let clipped = sampleScreenFrame.intersection(displayFrame)
        guard !clipped.isNull && clipped.width > 0 && clipped.height > 0 else {
            return nil
        }

        return CGRect(
            x: clipped.minX - displayFrame.minX,
            y: displayFrame.maxY - clipped.maxY,
            width: clipped.width,
            height: clipped.height
        )
    }

    nonisolated static func luminance(ofRGBA bytes: [UInt8]) -> Double {
        let pixelCount = bytes.count / 4
        guard pixelCount > 0 else { return 0 }

        var sum: Double = 0
        for i in 0..<pixelCount {
            let base = i * 4
            let r = Double(bytes[base]) / 255.0
            let g = Double(bytes[base + 1]) / 255.0
            let b = Double(bytes[base + 2]) / 255.0
            sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return sum / Double(pixelCount)
    }

    func update(luminance: Double) {
        let before = isDarkBackground
        if isDarkBackground {
            if luminance > Self.lightThreshold {
                isDarkBackground = false
            }
        } else {
            if luminance < Self.darkThreshold {
                isDarkBackground = true
            }
        }
        if before != isDarkBackground {
            os_log(
                "luma flip lum=%.3f dark=%{public}@",
                log: Self.log, type: .info,
                luminance, isDarkBackground ? "true" : "false"
            )
        }
    }

    func applySystemAppearanceFallback(isSystemDark: Bool) {
        isDarkBackground = isSystemDark
    }

    func setExcludedWindowID(_ windowID: CGWindowID?) {
        let previous = excludedWindowID
        excludedWindowID = windowID
        if capturedDisplayID != 0 && previous != windowID {
            needsCaptureRestart = true
        }
    }

    func setSampleRegion(screenFrame: CGRect?) {
        let previous = sampleScreenFrame
        sampleScreenFrame = screenFrame
        currentSampleRegion = screenFrame
        if capturedDisplayID != 0 && previous != screenFrame {
            needsCaptureRestart = true
        }
    }

    func markPipelineCaptured(onDisplayID displayID: CGDirectDisplayID) {
        capturedDisplayID = displayID
        needsCaptureRestart = false
    }

    func noteScreenChanged(toDisplayID displayID: CGDirectDisplayID) {
        guard displayID != capturedDisplayID else { return }
        needsCaptureRestart = true
    }

    func notePanelVisibilityChanged(isVisible: Bool) {
        lastReportedPanelVisible = isVisible
    }

    /// No-op compatibility surface. Starting luminance no longer creates
    /// any capture session; it only applies the system appearance fallback.
    func start() async {
        guard !isRunning else { return }
        applySystemAppearanceFallback(isSystemDark: Self.systemEffectiveDark)
    }

    func stop() async {
        isRunning = false
        capturedDisplayID = 0
        needsCaptureRestart = false
    }

    func restart() async {
        await stop()
        await start()
    }

    private static var systemEffectiveDark: Bool {
        guard let appearance = NSApp?.effectiveAppearance else {
            return false
        }
        let bestMatch = appearance.bestMatch(from: [.darkAqua, .aqua])
        return bestMatch == .darkAqua
    }
}
