import AppKit
import SwiftUI

/// One horizontal tool capsule. Motion belongs to the foreground content;
/// the outer button and measured pointer target keep their fixed geometry.
struct IslandHoverPanelControl: View {
    let title: String
    let systemImage: String
    /// Optional bundled-PDF resource name (without `.pdf` extension).
    /// When present, the tile renders the PDF orb directly and ignores
    /// `systemImage`; the white background circle is suppressed.
    let pdfResource: String?
    /// Optional dynamic icon body. Used by Language so the same control
    /// can show a planet in Auto mode and a selected-language flag
    /// inside the same orb footprint.
    var iconPresentation: IslandHoverIconPresentation? = nil
    /// Current value for VoiceOver; capsules show only their icon and title.
    let label: String?
    let circleSize: CGFloat
    let accessibilityLabel: String
    /// Retained for call-site compatibility; every capsule now centers its icon.
    var centersIcon: Bool = false
    /// Renders the tile faded + non-emphasised. Used by Output Language in
    /// Fast mode, where the tile is inactive (tap shows a notice).
    var isDimmed: Bool = false
    /// Light the Record icon while a meeting recording is active.
    var isRecording: Bool = false
    /// When `true`, a small red unread dot sits on the tile's top-trailing
    /// edge. Used only by the Notify tile to flag unread notifications.
    var showsDot: Bool = false
    /// A "Soon" plaque on the tile's top-trailing edge for a tool that cannot be used yet.
    var badge: String? = nil
    /// Hide the title while preserving the capsule footprint.
    var showsLabel: Bool = true
    /// The grid supplies its exact available cell width, including fractional
    /// widths from the current screen's notch geometry.
    var width: CGFloat = Self.tileWidth
    let action: () -> Void

    static let tileWidth: CGFloat = 90
    static let tileHeight: CGFloat = 52
    static let iconSize: CGFloat = 30
    private static let horizontalPadding: CGFloat = 6
    private static let contentSpacing: CGFloat = 5
    private static let iconScale: CGFloat = iconSize / 36

    /// Preserve the caller's title casing without forced uppercase or line breaks.
    static func displayTitle(_ title: String) -> String {
        title.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    @State private var pointerInside = false
    @State private var pull: CGSize = .zero
    @GestureState private var pressed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandHoverNativePressed) private var nativePressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var hovering: Bool { isEnabled && pointerInside }
    private var isPressed: Bool { isEnabled && (pressed || nativePressed) }

    private var statusText: String? {
        guard let label else { return nil }
        let status = Self.displayTitle(label)
        return status.isEmpty || status.caseInsensitiveCompare(Self.displayTitle(title)) == .orderedSame
            ? nil : status
    }

    var spokenAccessibilityLabel: String {
        guard let statusText,
              accessibilityLabel.range(of: statusText, options: [.caseInsensitive, .diacriticInsensitive]) == nil else {
            return accessibilityLabel
        }
        return "\(accessibilityLabel), \(statusText)"
    }

    private var spokenLabel: String {
        guard let badge else { return spokenAccessibilityLabel }
        return "\(spokenAccessibilityLabel), \(badge)"
    }

    /// Less travel than an orb: keep the visible pill within the column gap.
    private var visualScale: CGFloat {
        1 + (IslandGraphiteHoverControlStyle.feedbackScale(
            hovering: hovering, pressed: isPressed, reduceMotion: reduceMotion
        ) - 1) * 0.5
    }

    var body: some View {
        Button(action: action) {
            content
                .offset(isEnabled ? pull : .zero)
                .scaleEffect(visualScale)
                .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.76), value: hovering)
        }
        .buttonStyle(.plain)
            .frame(width: width, height: Self.tileHeight, alignment: .center)
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if let badge {
                    IslandSoonBadge(text: badge)
                        .padding(.trailing, 4)
                        .padding(.top, 2)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointerInside = true
                    let rawPull = IslandGraphiteHoverControlStyle.magneticPull(
                            location: location,
                            bounds: CGSize(width: width, height: Self.tileHeight),
                            presentation: resolvedIconPresentation
                        )
                    pull = reduceMotion ? .zero : CGSize(width: rawPull.width * 0.35, height: rawPull.height * 0.35)
                case .ended:
                    pointerInside = false
                    pull = .zero
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { value, isPressed, _ in
                        isPressed = CGRect(x: 0, y: 0, width: width, height: Self.tileHeight)
                            .contains(value.location)
                    }
            )
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.74), value: pull)
            .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.70), value: isPressed)
            .animation(.easeOut(duration: 0.22), value: hovering)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
            .accessibilityValue(showsDot ? "New notifications" : "")
            .accessibilityAddTraits(.isButton)
    }

    private var content: some View {
        HStack(spacing: Self.contentSpacing) {
            iconDisk
                .frame(width: Self.iconSize, height: Self.iconSize)

            if showsLabel {
                Text(Self.displayTitle(title))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)
                    .layoutPriority(1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(Self.horizontalPadding)
        .frame(width: width, height: Self.tileHeight, alignment: .leading)
        .background {
            Capsule()
                .fill(LinearGradient(
                    colors: hovering
                        ? [.white.opacity(0.18), .white.opacity(0.075)]
                        : [.white.opacity(0.11), .white.opacity(0.035)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay { IslandHoverGlassRim(shape: Capsule(), highlighted: hovering) }
                .shadow(color: .black.opacity(hovering ? 0.20 : 0.12), radius: hovering ? 5 : 3, x: 0, y: 2)
                .allowsHitTesting(false)
        }
        .opacity(isDimmed ? 0.4 : 1)
    }

    private var iconDisk: some View {
        ZStack {
            if !usesBundledOrb {
                Circle()
                    .fill(.white.opacity(hovering ? 0.98 : 0.90))
                    .shadow(color: .black.opacity(0.08), radius: 1, x: 0, y: 1)
            }
            iconView.frame(width: Self.iconSize, height: Self.iconSize)
        }
        .shadow(color: isRecording ? .red.opacity(0.65) : .clear, radius: 5)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isRecording)
        .overlay(alignment: .topTrailing) {
            if showsDot {
                Circle()
                    .fill(Color(red: 1, green: 0.27, blue: 0.23))
                    .frame(width: 5, height: 5)
                    .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 1))
                    .offset(x: 1, y: -1)
            }
        }
    }

    private var usesBundledOrb: Bool {
        switch resolvedIconPresentation {
        case .pdfResource, .pdfRingedSystemImage, .pdfRingedFlag: return true
        default: return false
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch resolvedIconPresentation {
        case .pdfResource(let pdfResource):
            if let nsImage = IslandControlIcon.image(named: pdfResource) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackSystemIcon
            }

        case .systemImage(let systemImage):
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isRecording ? Color.red : Color.blue)
                .symbolRenderingMode(.monochrome)
                // A changed symbol (Drop Mode bolt <-> sparkles) replaces itself
                // natively inside the caller's animation.
                // WHY: .project-docs/decisions/2026-11-28-drop-mode-switch-motion.md
                .contentTransition(.symbolEffect(.replace))
                .animation(IslandDropModeControl.switchAnimation(reduceMotion: reduceMotion), value: systemImage)

        case .flag(let flag):
            Text(flag)
                .font(.system(size: IslandHoverPanelIconStyle.dynamicFlagFontSize * Self.iconScale, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.74)

        case .text(let text):
            Text(text)
                .font(.system(
                    size: 11,
                    weight: .semibold,
                    design: .monospaced
                ))
                .tracking(0.3)
                .foregroundStyle(Color.blue)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(
                    width: Self.iconSize - 6,
                    height: 18
                )
                .offset(y: IslandGraphiteHoverControlStyle.textIconOpticalYOffset)
                .drawingGroup(opaque: false, colorMode: .linear)

        case .pdfRingedSystemImage(let ringResource, let systemImage):
            pdfRingedIcon(ringResource: ringResource) {
                Image(systemName: systemImage)
                    .font(.system(size: IslandHoverPanelIconStyle.ringSystemFontSize * Self.iconScale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            }

        case .pdfRingedFlag(let ringResource, let flag):
            pdfRingedIcon(ringResource: ringResource) {
                Text(flag)
                    .font(.system(size: IslandHoverPanelIconStyle.ringFlagFontSize * Self.iconScale, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

        case .none:
            fallbackSystemIcon
        }
    }

    private var resolvedIconPresentation: IslandHoverIconPresentation? {
        iconPresentation ?? pdfResource.map(IslandHoverIconPresentation.pdfResource)
    }

    @ViewBuilder
    private func pdfRingedIcon<Content: View>(
        ringResource: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ZStack {
            if let nsImage = IslandControlIcon.image(named: ringResource) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Circle()
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
            }

            content()
                .frame(
                    width: min(circleSize, Self.iconSize) * IslandHoverPanelIconStyle.ringContentScale,
                    height: min(circleSize, Self.iconSize) * IslandHoverPanelIconStyle.ringContentScale
                )
        }
    }

    @ViewBuilder
    private var fallbackSystemIcon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(isRecording ? Color.red : Color.blue)
            .symbolRenderingMode(.monochrome)
    }
}

/// The small "Soon" plaque on a tool that is listed but cannot be used yet.
/// Always readable on the island's dark glass, also on a dimmed tile.
struct IslandSoonBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 6)
            .frame(minHeight: 14)
            .background(
                Capsule()
                    .fill(.white.opacity(0.16))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 0.5))
            )
            .accessibilityHidden(true)
    }
}
