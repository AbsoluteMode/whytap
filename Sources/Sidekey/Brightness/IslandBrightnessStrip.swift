import SwiftUI

/// The Brightness hover tool: one row with the backlight slider and the Extra
/// switch, with a status line only when brightness needs attention.
// WHY: .project-docs/decisions/2026-10-18-brightness-tool.md
@MainActor
struct IslandBrightnessStrip: View {
    /// Fits 10 pt padding, a 24 pt control row and an optional 16 pt notice with 8 pt spacing.
    static let contentHeight: CGFloat = 68
    static let unavailableText = "Brightness isn't adjustable on this display."

    @ObservedObject private var controller: ScreenBrightnessController
    private let onBack: () -> Void

    /// Nil uses the shared instance; a default argument would read it outside the main actor.
    init(controller: ScreenBrightnessController? = nil,
         onBack: @escaping () -> Void) {
        self.controller = controller ?? .shared
        self.onBack = onBack
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IslandHoverBackButton(destination: "brightness", action: onBack)

                BrightnessCapsuleSlider(level: controller.level, isEnabled: controller.isAvailable,
                                        onChange: controller.setLevel,
                                        onEditingChanged: { editing in
                                            if editing { controller.beginLevelDrag() }
                                            else { controller.endLevelDrag() }
                                        })

                if controller.supportsExtra {
                    // The island is never the active app's key window, where the native switch
                    // draws its on state gray; MacSwitch keeps its blue.
                    HStack(spacing: 8) {
                        Text("Extra")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .accessibilityHidden(true)
                        MacSwitch(isOn: Binding(get: { controller.isExtraOn }, set: { controller.setExtra($0) }),
                                  size: .compact)
                            .accessibilityLabel("Extra brightness")
                    }
                    .fixedSize()
                    .help("Adds brightness on top of the current level. Uses more battery.")
                }
            }
            .frame(height: BrightnessCapsuleSlider.height)

            if let line = statusLine {
                HStack(spacing: 5) {
                    if let symbol = line.systemImage {
                        Image(systemName: symbol).font(.system(size: 11))
                    }
                    Text(line.text)
                        .font(.system(size: line.isNotice ? 10 : 11))
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(line.isNotice ? AnyShapeStyle(.orange) : AnyShapeStyle(.white.opacity(0.55)))
                .frame(height: 16)
                // Under the slider, not the back button.
                .padding(.leading, 40)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(10)
        // Without a status line the control row stays centered in the strip.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            controller.beginInteraction()
        }
        .onDisappear {
            controller.endInteraction()
        }
    }

    private var statusLine: (text: String, systemImage: String?, isNotice: Bool)? {
        if let notice = controller.notice { return (notice, "exclamationmark.triangle.fill", true) }
        if !controller.isAvailable { return (Self.unavailableText, nil, false) }
        return nil
    }
}

/// A Control Center style capsule: white fill from the leading edge with the
/// sun at its start. Clicking or dragging anywhere on it sets the level.
struct BrightnessCapsuleSlider: View {
    static let height: CGFloat = 24
    /// One brightness-key step.
    static let accessibilityStep = 1.0 / 16

    let level: Double
    let isEnabled: Bool
    let onChange: @MainActor (Double) -> Void
    var onEditingChanged: @MainActor (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragging = false
    @GestureState private var dragActive = false

    /// The fill always covers the sun at the start, so the pointer maps from
    /// the middle of that start to the middle of the end.
    static func level(atX x: CGFloat, width: CGFloat) -> Double {
        let span = width - height
        guard span > 0 else { return 0 }
        return ScreenBrightnessScale.clampedLevel(Double((x - height / 2) / span))
    }

    static func fillWidth(level: Double, width: CGFloat) -> CGFloat {
        height + max(0, width - height) * CGFloat(ScreenBrightnessScale.clampedLevel(level))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule()
                    .fill(.white.opacity(isEnabled ? 0.95 : 0.4))
                    .frame(width: Self.fillWidth(level: level, width: width))
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.55))
                    .frame(width: Self.height, height: Self.height)
            }
            // The fill follows the pointer directly while dragging.
            .animation(dragging || reduceMotion ? nil : .easeOut(duration: 0.15), value: level)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragActive) { _, active, _ in active = true }
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        onChange(Self.level(atX: value.location.x, width: width))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: Self.height)
        .opacity(isEnabled ? 1 : 0.6)
        .allowsHitTesting(isEnabled)
        .onChange(of: dragActive) { _, active in
            // GestureState also resets when macOS cancels a drag without an onEnded.
            if !active, dragging {
                dragging = false
                onEditingChanged(false)
            }
        }
        .onDisappear {
            if dragging {
                dragging = false
                onEditingChanged(false)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Brightness")
        .accessibilityValue("\(Int((ScreenBrightnessScale.clampedLevel(level) * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(level + Self.accessibilityStep)
            case .decrement: onChange(level - Self.accessibilityStep)
            @unknown default: break
            }
        }
    }
}
