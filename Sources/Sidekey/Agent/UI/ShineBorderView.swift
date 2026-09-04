import SwiftUI

/// Plain border wrapper for legacy `ShineBorderView` call sites. The type
/// name is kept so response/input layout code does not need a broad rename.
struct ShineBorderView<S: Shape>: View {
    let shape: S
    let lineWidth: CGFloat
    let color: Color

    init(shape: S, lineWidth: CGFloat = 1.5, color: Color = Self.defaultColor) {
        self.shape = shape
        self.lineWidth = lineWidth
        self.color = color
    }

    static var defaultColor: Color {
        Color.primary.opacity(0.12)
    }

    var body: some View {
        shape.stroke(color, lineWidth: lineWidth)
    }
}

extension ShineBorderView where S == Capsule {
    static func capsule(lineWidth: CGFloat = 1.5, color: Color = ShineBorderView<Capsule>.defaultColor) -> ShineBorderView<Capsule> {
        ShineBorderView<Capsule>(shape: Capsule(style: .continuous), lineWidth: lineWidth, color: color)
    }
}
