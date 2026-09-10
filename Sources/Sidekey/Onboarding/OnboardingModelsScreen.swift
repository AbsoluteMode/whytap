import SwiftUI
import Combine

/// Uses the same provider validation, Keychain and model downloads as Settings.
/// WHY: .project-docs/decisions/2026-09-10-onboarding-models.md
@MainActor
final class OnboardingModelsController: ObservableObject {
    enum Stage { case speech, smart }

    let models: SettingsModelsViewModel
    @Published private(set) var stage: Stage = .speech
    @Published private(set) var isSaving = false
    private var modelChanges: AnyCancellable?

    init(models: SettingsModelsViewModel) {
        self.models = models
        // Presentation only: no route or credential changes until Save.
        models.selectLevel(.yourKey)
        models.selectLLMTopLevel(.yourKey)
        modelChanges = models.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// True only when both steps have been saved. Smart may also be skipped.
    func continueSetup() async -> Bool {
        guard !isSaving,
              models.connectionStatus != .testing,
              models.llmConnectionStatus != .testing else { return false }
        isSaving = true
        defer { isSaving = false }
        switch stage {
        case .speech:
            guard await models.saveCurrentSelection(), !Task.isCancelled else { return false }
            stage = .smart
            return false
        case .smart:
            return await models.saveCurrentLLMSelection() && !Task.isCancelled
        }
    }

    func backToSpeech() {
        guard !isSaving else { return }
        stage = .speech
    }
}

@MainActor
struct OnboardingModelsScreen: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    let onSkip: () -> Void

    @StateObject private var controller: OnboardingModelsController
    private var models: SettingsModelsViewModel { controller.models }
    @EnvironmentObject private var locale: OnboardingLocale
    @State private var saveTask: Task<Void, Never>?

    init(
        controller: OnboardingModelsController? = nil,
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        let controller = controller ?? OnboardingModelsController(models: SettingsModelsViewModel())
        _controller = StateObject(wrappedValue: controller)
        self.onBack = onBack
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    private var isSpeech: Bool { controller.stage == .speech }
    private var isBusy: Bool {
        controller.isSaving || models.connectionStatus == .testing || models.llmConnectionStatus == .testing
    }
    private func text(_ en: String, _ ru: String) -> String { locale.language == .ru ? ru : en }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                introduction
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(OnboardingTheme.border).frame(width: 1)
                    }
                SettingsModelsView(viewModel: models, section: isSpeech ? .transcription : .smart)
                    .padding(.top, 28)
                    .disabled(isBusy)
            }
            Rectangle().fill(OnboardingTheme.border).frame(height: 1)
            HStack(spacing: 16) {
                MacButton(title: text("Back", "Назад")) {
                    if isSpeech { onBack() } else { controller.backToSpeech() }
                }
                Spacer()
                MacButton(
                    title: isSpeech
                        ? text("Set up later", "Настроить позже")
                        : text("Skip text cleanup", "Пропустить обработку текста"),
                    style: .ghost
                ) {
                    if isSpeech { onSkip() } else { onContinue() }
                }
                MacButton(
                    title: isBusy ? text("Saving…", "Сохранение…") : text("Save & continue", "Сохранить и продолжить"),
                    style: .primary
                ) {
                    saveTask = Task {
                        if await controller.continueSetup(), !Task.isCancelled { onContinue() }
                    }
                }
            }
            .disabled(isBusy)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .background(OnboardingTheme.bg)
        .onDisappear { saveTask?.cancel() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(isSpeech ? text("YOUR MODELS · 1 / 2", "ВАШИ МОДЕЛИ · 1 / 2") : text("YOUR MODELS · 2 / 2", "ВАШИ МОДЕЛИ · 2 / 2"))
                .font(.system(size: 11, weight: .semibold)).tracking(1.5)
                .foregroundStyle(OnboardingTheme.muted)
            Text(isSpeech ? text("Connect your voice.", "Подключите голос.") : text("Polish your words.", "Приведите текст в порядок."))
                .font(OnboardingTheme.serif(36, language: locale.language))
                .foregroundStyle(OnboardingTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(isSpeech
                 ? text("Add your speech provider’s API key. Your audio goes directly to that provider. Or choose Local to download a model for this Mac.", "Добавьте API-ключ сервиса распознавания. Аудио отправляется напрямую выбранному сервису. Или выберите Local и скачайте модель на этот Mac.")
                 : text("Optional: add an OpenRouter key or your own endpoint for text cleanup and meeting summaries. Local models are available here too.", "Необязательно: добавьте ключ OpenRouter или свой сервер для обработки текста и итогов встреч. Здесь также доступны локальные модели."))
                .font(.system(size: 14)).foregroundStyle(OnboardingTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Label(text("Keys stay in macOS Keychain.", "Ключи хранятся в Связке ключей macOS."), systemImage: "lock.shield")
                .font(.system(size: 12)).foregroundStyle(OnboardingTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(30)
        .padding(.top, 24)
    }
}
