import AppKit
import SwiftUI

struct MeetingAssistantButtonStyle: ButtonStyle {
    var capsule = false
    var selected = false
    var completed = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, capsule: capsule, selected: selected, completed: completed, enabled: enabled)
    }
    private struct Feedback: View {
        let configuration: Configuration
        let capsule: Bool
        let selected: Bool
        let completed: Bool
        let enabled: Bool
        @State private var hover = false
        @Environment(\.isFocused) private var focused
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: capsule ? 12 : 6, style: .continuous)
            configuration.label
                .padding(.horizontal, capsule ? 9 : 6)
                .padding(.vertical, capsule ? 6 : 4)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .background {
                    if capsule { shape.fill(.thickMaterial) }
                    shape.fill(Color.primary.opacity(!enabled ? 0 : configuration.isPressed ? 0.14 : hover ? 0.09 : selected ? 0.045 : 0))
                }
                .overlay {
                    shape.strokeBorder(focused ? Color.accentColor : Color.primary.opacity(capsule ? (selected ? 0.35 : 0.12) : 0), lineWidth: focused ? 2 : 0.5)
                }
                .contentShape(shape)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hover = $0 }
        }
    }
}

struct MeetingAssistantQuestionHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MeetingAssistantView: View {
    @ObservedObject var model: MeetingAssistantModel
    var openSettings: (AIFeature) -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            MeetingAssistantQuestionsView(model: model, openSettings: openSettings)
                .background(GeometryReader { proxy in Color.clear.preference(key: MeetingAssistantQuestionHeight.self, value: proxy.size.height) })
            if model.answerVisible {
                MeetingAssistantAnswerView(model: model)
            }
        }
        .frame(width: 354, alignment: .topTrailing)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            shape.fill(.regularMaterial)
            shape.fill(Color.black.opacity(0.075))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onPreferenceChange(MeetingAssistantQuestionHeight.self) { height in
            if abs(model.questionsHeight - height) > 0.5 {
                DispatchQueue.main.async { model.questionsHeight = height; model.onChange?() }
            }
        }
    }
}

struct MeetingAssistantQuestionsView: View {
    @ObservedObject var model: MeetingAssistantModel
    var openSettings: (AIFeature) -> Void
    @FocusState private var typing: Bool
    @State private var inputHover = false
    @Namespace private var movement
    var body: some View {
        VStack(alignment: .trailing, spacing: model.layoutHeight < 800 ? 7 : 9) {
            MeetingAssistantSpaceSelector(model: model)
            HStack(spacing: 6) {
                if model.releasingAudio || model.startRequested || model.audioConnecting || model.listening {
                    Label(model.releasingAudio ? "Останавливаю…" : model.startRequested || model.audioConnecting ? "Подключение…" : "Слушаю встречу", systemImage: model.listening ? "waveform" : "ear")
                        .foregroundStyle(.secondary)
                }
                if !model.answerVisible, model.selected != nil {
                    Button("Вернуть ответ") { model.restoreAnswer() }.buttonStyle(MeetingAssistantButtonStyle())
                }
            }.font(.system(size: 10))
            if model.spaces.isEmpty {
                Text("Попроси Codex или Claude Code создать Space для проекта.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.spaceError.isEmpty { Text(model.spaceError).font(.system(size: 11)).foregroundStyle(.secondary) }
            if !model.audioIssue.isEmpty { Text(model.audioIssue).font(.system(size: 11)).foregroundStyle(.secondary) }
            if model.audioIssue.hasPrefix("Настрой") || model.audioIssue.hasPrefix("Выбери") || model.notice.hasPrefix("Выбери") {
                Button("Настроить модели…") { openSettings(model.audioIssue.contains("audio") ? .meetingAssistantAudio : .meetingAssistant) }.buttonStyle(MeetingAssistantButtonStyle()).font(.system(size: 10))
            }
            HStack(spacing: 6) {
                MeetingAssistantInput(placeholder: "Спросить о \(model.currentSpace?.name ?? "проекте")…", text: $model.draft, submit: model.submit, focusChanged: { focused in typing = focused; model.mutate { model.editing = focused } })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)


                    .padding(.vertical, 6)
                    .padding(.horizontal, 5)
                    .background(Color.primary.opacity(inputHover ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(alignment: .bottom) {
                        if typing { Rectangle().fill(Color.accentColor.opacity(0.65)).frame(height: 1) }
                    }
                    .onHover { inputHover = $0 }
                    .accessibilityLabel("Вопрос Meeting Assistant, Enter для отправки")
                MeetingAssistantAttachButton(model: model)
                Button { model.dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium)).frame(width: 16, height: 16)
                }
                .buttonStyle(MeetingAssistantButtonStyle())
                .help("Закрыть Meeting Assistant")
                .accessibilityLabel("Закрыть весь Meeting Assistant")
            }

            if !model.screenshots.isEmpty { MeetingAssistantScreenshotTray(model: model) }
            if !model.screenError.isEmpty {
                Text(model.screenError).font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            MeetingAssistantBoundedList(limit: model.layoutHeight < 800 ? 64 : 96, onResize: { model.onChange?() }) {
                ForEach(Array(model.pending.enumerated()), id: \.element.id) { index, example in
                    question(example, done: false)
                        .matchedGeometryEffect(id: example.id, in: movement)
                        .scaleEffect(max(0.94, 1 - Double(index) * 0.018), anchor: .trailing)
                        .opacity(max(0.65, 1 - Double(index) * 0.13))
                        .transition(.asymmetric(insertion: .offset(y: 12).combined(with: .opacity), removal: .opacity))
                }
            }

            if !model.completed.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Ответы · \(model.completed.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 8)
                        .padding(.top, 6)
                    MeetingAssistantBoundedList(limit: model.layoutHeight < 800 ? 34 : 64, onResize: { model.onChange?() }) {
                        ForEach(model.completed) { example in
                            question(example, done: true)
                                .matchedGeometryEffect(id: example.id, in: movement)
                        }
                    }
                }
            }
            if model.pending.isEmpty {
                Text(model.listening ? "Жду вопросы из встречи…" : "Можно задать вопрос").font(.system(size: 11)).foregroundStyle(.secondary).padding(.trailing, 8)
            }
        }
        .padding(10)
        .frame(width: 354, alignment: .topTrailing)
        .fixedSize(horizontal: false, vertical: true)

        .onAppear { typing = false }


    }

    private func question(_ example: MeetingAssistantQuestion, done: Bool) -> some View {
        Button { model.ask(example) } label: {
            HStack(spacing: 6) {
                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary) }
                Text(example.question)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if model.busy == example.id {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                }
            }
        }
        .buttonStyle(MeetingAssistantButtonStyle(capsule: true, selected: model.selectedRootID == example.id && model.answerVisible, completed: done))
        .accessibilityLabel("\(done ? "Ответ" : "Новый вопрос"): \(example.question)")
    }
}

struct MeetingAssistantBodyHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MeetingAssistantAnswerView: View {
    @ObservedObject var model: MeetingAssistantModel
    @State private var bodyHeight: CGFloat = 220
    @State private var inputHover = false
    @FocusState private var clarifying: Bool
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if !model.previous.isEmpty {
                    Button { model.back() } label: {
                        Image(systemName: "arrow.left").font(.system(size: 10))
                    }.buttonStyle(MeetingAssistantButtonStyle()).help("Предыдущий ответ").accessibilityLabel("Предыдущий ответ")
                }
                if model.busy != nil {
                    Button("Остановить") { model.cancel() }.buttonStyle(MeetingAssistantButtonStyle())
                }
                Button { model.mutate { model.answerVisible = false } } label: {
                    Image(systemName: "minus").font(.system(size: 11)).frame(width: 14, height: 14)
                }.buttonStyle(MeetingAssistantButtonStyle()).help("Свернуть ответ").accessibilityLabel("Свернуть ответ")
            }
            .font(.system(size: 10))
            .padding(.horizontal, 4)

            if !model.notice.isEmpty {
                Text(model.notice).font(.system(size: 12)).lineSpacing(3).padding(12).meetingAssistantSurface()
            } else if let answer = model.selected {
                Text(answer.question)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.thickMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if model.busy != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Готовлю ответ…").font(.system(size: 12))
                        Spacer()
                    }.padding(12).meetingAssistantSurface()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 11) {
                                Text(answer.conclusion).font(.system(size: 14, weight: .semibold)).lineSpacing(3)
                                ForEach(Array(answer.points.enumerated()), id: \.offset) { index, point in
                                    HStack(alignment: .top, spacing: 9) {
                                        Text(String(index + 1)).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).frame(width: 10).padding(.top, 2)
                                        Text(.init(point)).font(.system(size: 12)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }

                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { proxy in Color.clear.preference(key: MeetingAssistantBodyHeight.self, value: proxy.size.height) })
                        }
                        .frame(height: min(max(bodyHeight, 32), model.bodyLimit))
                        .onPreferenceChange(MeetingAssistantBodyHeight.self) { value in
                            if abs(bodyHeight - value) > 1 { bodyHeight = value; model.onChange?() }
                        }

                        Divider().opacity(0.5)
                        MeetingAssistantInput(placeholder: "Уточнить ответ…", text: $model.followupDraft, submit: model.submitFollowup, focusChanged: { focused in clarifying = focused; model.mutate { model.editing = focused } })
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.leading)


                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(inputHover ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 5))
                            .onHover { inputHover = $0 }
                            .overlay(alignment: .bottom) {
                                if clarifying { Rectangle().fill(Color.accentColor.opacity(0.65)).frame(height: 1) }
                            }
                            .accessibilityLabel("Уточнить ответ, Enter для отправки")
                        ForEach(answer.followups.prefix(2)) { followup in
                            Button { model.follow(followup) } label: {
                                Text(followup.title).frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
                            }
                            .buttonStyle(MeetingAssistantButtonStyle())
                            .font(.system(size: 11))
                            .padding(.horizontal, -6)
                        }

                    }
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .meetingAssistantSurface()
                    .transition(.opacity)
                }
            }
        }
        .padding(10)
        .frame(width: 354, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)

        .onAppear { clarifying = false }

    }
}

extension View {
    func meetingAssistantSurface() -> some View {
        self.background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
