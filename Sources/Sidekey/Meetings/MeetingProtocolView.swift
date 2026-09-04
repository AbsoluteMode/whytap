import AppKit
import SwiftUI

/// Structured renderer for a parsed `MeetingProtocol`. Title + description,
/// then Tasks / Decisions / Other. Each task is a discrete card carrying its
/// fields. When Linear is connected the host can provide `onTaskTap`, and each
/// task gets a small action chip that opens Linear's pre-filled issue form.
/// Styled with the shared Settings tokens, same reading column as the note.
@MainActor
struct MeetingProtocolView: View {

    let note: MeetingProtocol
    /// Opens the task in an external tracker. Nil means the integration is not
    /// connected, so task cards render read-only.
    var onTaskTap: ((MeetingTask) -> Void)?

    private static let columnWidth: CGFloat = 680
    private let headingColor = MacSettingsTheme.text
    private let bodyColor = Color.white.opacity(0.82)
    private let mutedColor = Color.white.opacity(0.5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(note.name)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(headingColor)
                    .padding(.bottom, note.description.isEmpty ? 8 : 4)

                if !note.description.isEmpty {
                    Text(note.description)
                        .font(.system(size: 15))
                        .foregroundStyle(bodyColor)
                        .lineSpacing(4)
                        .padding(.bottom, 8)
                }

                if !note.tasks.isEmpty {
                    section(note.header(at: 0, fallback: "Tasks")) {
                        VStack(spacing: 8) {
                            ForEach(note.tasks) { task in
                                TaskRow(task: task, onTap: onTaskTap)
                            }
                        }
                    }
                }

                if !note.decisions.isEmpty {
                    section(note.header(at: 1, fallback: "Decisions")) {
                        items(note.decisions)
                    }
                }

                if !note.other.isEmpty {
                    section(note.header(at: 2, fallback: "Other")) {
                        items(note.other)
                    }
                }
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(headingColor)
            .padding(.top, 22)
            .padding(.bottom, 8)
        content()
    }

    private func items(_ list: [MeetingProtocolItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(list) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(.system(size: 15)).foregroundStyle(mutedColor)
                        Text(item.text)
                            .font(.system(size: 15))
                            .foregroundStyle(bodyColor)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let comment = item.comment {
                        Text(comment)
                            .font(.system(size: 12.5))
                            .foregroundStyle(mutedColor)
                            .padding(.leading, 23)
                    }
                }
            }
        }
    }
}

/// One task as a discrete card: text + assignee/deadline chips + comment.
/// `onTap` renders a compact Linear action chip when the integration is live.
private struct TaskRow: View {
    let task: MeetingTask
    var onTap: ((MeetingTask) -> Void)?

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Text(task.task)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let onTap {
                    Button {
                        onTap(task)
                    } label: {
                        HStack(spacing: 5) {
                            LinearTaskActionLogo()
                            Text("Linear")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.white.opacity(0.86))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color(red: 0.369, green: 0.416, blue: 0.824).opacity(0.86)))
                    }
                    .buttonStyle(.plain)
                    .help("Open pre-filled Linear issue")
                }
            }

            if task.assignee != nil || task.deadline != nil {
                HStack(spacing: 6) {
                    if let assignee = task.assignee {
                        chip(assignee, systemImage: "person.fill", tint: Color.white.opacity(0.7))
                    }
                    if let deadline = task.deadline {
                        chip(deadline, systemImage: "calendar", tint: MacSettingsTheme.accent)
                    }
                }
            }

            if let comment = task.comment {
                Text(comment)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(hovering && onTap != nil ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
    }

    private struct LinearTaskActionLogo: View {
        var body: some View {
            Group {
                if let image = UsefulLinkIconAsset.image(for: "linear") {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    LinearTaskFallbackLogo()
                }
            }
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
        }
    }

    private struct LinearTaskFallbackLogo: View {
        var body: some View {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.86), lineWidth: 1.1)
                VStack(alignment: .leading, spacing: 1.2) {
                    Capsule().frame(width: 5.5, height: 1.1)
                    Capsule().frame(width: 8.5, height: 1.1)
                    Capsule().frame(width: 6.5, height: 1.1)
                }
                .rotationEffect(.degrees(45))
                .foregroundStyle(Color.white.opacity(0.86))
            }
        }
    }

    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}
