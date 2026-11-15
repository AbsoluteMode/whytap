import SwiftUI

/// Dark glass background for the Copied toast.
struct DarkGlassCard<Content: View>: View {
    var width: CGFloat?
    var height: CGFloat?
    var cornerRadius: CGFloat = 28
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content()
            .frame(width: width, height: height)
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(.black.opacity(0.25)))
            }
            .overlay {
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.55),
                                .white.opacity(0.10),
                                .white.opacity(0.30),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .clipShape(shape)
    }
}
