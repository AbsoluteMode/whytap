import SwiftUI

struct ToolCircle: View {
    let index: Int
    @ObservedObject var state: AppState = .shared
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Circle()
            .fill(Color.white.opacity(isHovered ? 0.18 : 0.12))
            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
            .frame(width: 28, height: 28)
            .scaleEffect(isPressed ? 0.9 : 1.0)
            .onHover { isHovered = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { isPressed = true } }
                    .onEnded { _ in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isPressed = false } }
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .animation(.spring(response: 0.3, dampingFraction: 0.65).delay(Double(index) * 0.04), value: state.toolsExpanded)
            .allowsHitTesting(true)
    }
}
