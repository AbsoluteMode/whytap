import AppKit
import SwiftUI

@MainActor
final class SidekeyQuitConfirmationController: NSWindowController, NSWindowDelegate {
    private static let contentSize = NSSize(width: 380, height: 196)

    private let onConfirmQuit: () -> Void

    init(onConfirmQuit: @escaping () -> Void) {
        self.onConfirmQuit = onConfirmQuit

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Quit Whytap"
        window.isReleasedWhenClosed = false
        SidekeyWindowChrome.configureHoverOverlayPolicy(window)
        SidekeyWindowChrome.configure(window)

        super.init(window: window)
        window.delegate = self

        window.contentViewController = NSHostingController(
            rootView: SidekeyQuitConfirmationView(
                onCancel: { [weak self] in
                    self?.close()
                },
                onConfirm: { [weak self] in
                    self?.confirmQuit()
                }
            )
        )
        window.setContentSize(Self.contentSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidekeyQuitConfirmationController only supports programmatic init.")
    }

    func show() {
        guard let window else { return }
        window.setContentSize(Self.contentSize)
        // Pin the display before ordering. Re-resolving after the window
        // becomes key can choose a different screen and create a visible jump.
        guard let openingVisibleFrame = SidekeyWindowChrome.preferredVisibleFrame(for: window) else { return }
        NSApp.activate(ignoringOtherApps: true)
        SidekeyWindowChrome.center(window, inVisibleFrame: openingVisibleFrame)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        SidekeyWindowChrome.center(window, inVisibleFrame: openingVisibleFrame)
    }

    private func confirmQuit() {
        close()
        onConfirmQuit()
    }
}

@MainActor
private struct SidekeyQuitConfirmationView: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        SidekeyAuroraWindow(title: "Quit Whytap") {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Are you sure you want to quit Whytap?")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))

                    Text("Voice shortcuts, meeting notes, and the Whytap menu will stop until you open the app again.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)

                    Button("Cancel", action: onCancel)
                        .buttonStyle(SecondaryQuitButtonStyle())

                    Button("Quit", action: onConfirm)
                        .buttonStyle(ConfirmQuitButtonStyle())
                }
            }
            .padding(18)
            .frame(width: 380, height: 156)
        }
    }
}

@MainActor
private struct SecondaryQuitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.66 : 0.82))
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.10 : 0.075))
            )
    }
}

@MainActor
private struct ConfirmQuitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.76 : 0.95))
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.72, green: 0.18, blue: 0.22).opacity(configuration.isPressed ? 0.82 : 0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }
}
