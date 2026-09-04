import SwiftUI

/// Compact card surfaced in the pill when Claude Code asks to use a gated tool
/// (Bash / network / MCP-write). The user taps Allow or Deny; the choice is
/// forwarded through AskResponseStore.decide(_:) → AgentController →
/// ClaudeCodeProvider.respondToPermission(requestId:decision:).
struct PermissionPromptView: View {
    let prompt: PermissionPrompt
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(prompt.toolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: Capsule())
                Text("wants to run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(prompt.summary)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundStyle(.primary)
            HStack(spacing: 8) {
                Button("Deny", action: onDeny)
                    .keyboardShortcut(.cancelAction)
                Button("Allow", action: onAllow)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}
