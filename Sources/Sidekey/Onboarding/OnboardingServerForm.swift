import SwiftUI

/// What the server form holds: an address, an optional key and the models
/// the person names, each with what it is for.
struct OnboardingServerDraft: Equatable {
    enum Use: String, CaseIterable, Equatable {
        case llm, transcription
        var title: String { self == .llm ? "LLM" : "Transcription" }
    }

    struct Model: Equatable, Identifiable {
        var id = UUID()
        var name: String
        var use: Use
    }

    var address = ""
    var key = ""
    var models: [Model] = []

    /// The base URL: http(s) with a host; "localhost:11434/v1" gets http://.
    var url: URL? { Self.url(from: address) }
    /// The server's name comes from its address.
    var name: String { url.map(Self.name(for:)) ?? "" }
    var canSave: Bool { url != nil && !models.isEmpty }

    static func url(from address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let text = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// "Ollama" and "LM Studio" by their default ports, otherwise the host
    /// (with its port for a local address): "gpu-box.local:8000".
    static func name(for url: URL) -> String {
        switch url.port {
        case 11434: return "Ollama"
        case 1234: return "LM Studio"
        default: break
        }
        var host = url.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let local = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." }
        if local, let port = url.port { return "\(host):\(port)" }
        return host
    }

    /// Adds a model once per use; an empty name adds nothing.
    mutating func add(_ name: String, use: Use) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !models.contains(where: { $0.name == name && $0.use == use }) else { return }
        models.append(Model(name: name, use: use))
    }
}

/// "Use your own server →" in the preview: the server form in the same
/// window, over the onboarding. Base URL, an optional key, the models with
/// LLM or Transcription each, one Save. The name comes from the address.
/// Cancel, the back button or Escape return to the key step unchanged; Save
/// returns with the step done.
struct OnboardingServerFormView: View {
    let kind: OnboardingKeyStageKind
    let onSave: (OnboardingServerDraft) -> Void
    let onClose: () -> Void

    @State private var draft = OnboardingServerDraft()
    @State private var modelName = ""
    @State private var newUse: OnboardingServerDraft.Use
    @FocusState private var focus: Field?

    private enum Field { case address, key, model }

    init(kind: OnboardingKeyStageKind, onSave: @escaping (OnboardingServerDraft) -> Void, onClose: @escaping () -> Void) {
        self.kind = kind
        self.onSave = onSave
        self.onClose = onClose
        _newUse = State(initialValue: kind == .speech ? .transcription : .llm)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(kind == .speech ? "Speech key" : "Language model")
                    }
                    .font(OnboardingTheme.sans(12, weight: .medium))
                    .foregroundColor(OnboardingTheme.muted)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to the onboarding")
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: OnboardingTheme.compactHeaderHeight)
            .padding(.top, 24)

            VStack(spacing: 0) {
                Text("Your own server.")
                    .font(OnboardingTheme.serifItalic(28))
                    .foregroundColor(OnboardingTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Any OpenAI-compatible server: Ollama, LM Studio, vLLM.")
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    pill {
                        TextField("", text: $draft.address,
                                  prompt: Text("Base URL · http://localhost:11434/v1").foregroundColor(OnboardingTheme.faint))
                            .textFieldStyle(.plain)
                            .font(OnboardingTheme.mono(12.5))
                            .foregroundColor(OnboardingTheme.ink)
                            .focused($focus, equals: .address)
                            .onSubmit { focus = .key }
                            .accessibilityLabel("Base URL")
                    }
                    Text(addressLine)
                        .font(OnboardingTheme.sans(11.5))
                        .foregroundColor(addressIsWrong ? OnboardingTheme.orange : OnboardingTheme.faint)
                        .lineLimit(1)
                        .padding(.leading, 16)
                    pill {
                        SecureField("", text: $draft.key,
                                    prompt: Text("API key · optional").foregroundColor(OnboardingTheme.faint))
                            .textFieldStyle(.plain)
                            .font(OnboardingTheme.mono(12.5))
                            .foregroundColor(OnboardingTheme.ink)
                            .focused($focus, equals: .key)
                            .onSubmit { focus = .model }
                            .accessibilityLabel("API key, optional")
                    }
                }
                .padding(.top, 14)

                models
                    .padding(.top, 12)
            }
            .padding(.horizontal, OnboardingKeyStage.fieldInset)

            Spacer(minLength: 6)

            HStack {
                Button("Cancel", action: onClose)
                    .buttonStyle(.plain)
                    .font(OnboardingTheme.sans(12, weight: .medium))
                    .foregroundColor(OnboardingTheme.muted)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                OnboardingPrimaryButton(title: "Save", chevron: false, isEnabled: draft.canSave) { onSave(draft) }
            }
            .padding(.horizontal, OnboardingKeyStage.fieldInset)
            .frame(height: OnboardingTheme.compactFooterHeight)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnboardingTheme.bg.contentShape(Rectangle()))
        .onAppear { focus = .address }
    }

    private var addressIsWrong: Bool {
        !draft.address.trimmingCharacters(in: .whitespaces).isEmpty && draft.url == nil
    }

    private var addressLine: String {
        if addressIsWrong { return "Enter an address like http://localhost:11434/v1" }
        if draft.url != nil { return "Name: \(draft.name) · from the address" }
        return "The name comes from the address."
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models")
                .font(OnboardingTheme.sans(11.5, weight: .semibold))
                .foregroundColor(OnboardingTheme.muted)
                .padding(.leading, 16)
            if !draft.models.isEmpty {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach($draft.models) { $model in
                            HStack(spacing: 8) {
                                Text(model.name)
                                    .font(OnboardingTheme.mono(12))
                                    .foregroundColor(OnboardingTheme.ink)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                OnboardingUseToggle(use: $model.use)
                                Button {
                                    draft.models.removeAll { $0.id == model.id }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(OnboardingTheme.muted)
                                        .frame(width: 22, height: 22)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(model.name)")
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 6)
                            .frame(height: 32)
                        }
                    }
                }
                .frame(height: min(CGFloat(draft.models.count), 2.5) * 32)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
            }
            pill {
                TextField("", text: $modelName,
                          prompt: Text("Model name · e.g. qwen3:8b").foregroundColor(OnboardingTheme.faint))
                    .textFieldStyle(.plain)
                    .font(OnboardingTheme.mono(12))
                    .foregroundColor(OnboardingTheme.ink)
                    .focused($focus, equals: .model)
                    .onSubmit(addModel)
                    .accessibilityLabel("Model name")
                OnboardingUseToggle(use: $newUse)
                Button("Add", action: addModel)
                    .buttonStyle(.plain)
                    .font(OnboardingTheme.sans(12, weight: .semibold))
                    .foregroundColor(modelName.trimmingCharacters(in: .whitespaces).isEmpty ? OnboardingTheme.faint : OnboardingTheme.ink)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func addModel() {
        draft.add(modelName, use: newUse)
        modelName = ""
        focus = .model
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .frame(height: 36)
            .background(Capsule().fill(Color(red: 0.086, green: 0.086, blue: 0.098)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
    }
}

/// LLM | Transcription, one quiet two-way switch per model.
struct OnboardingUseToggle: View {
    @Binding var use: OnboardingServerDraft.Use

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingServerDraft.Use.allCases, id: \.self) { option in
                Button { use = option } label: {
                    Text(option.title)
                        .font(OnboardingTheme.sans(11, weight: .medium))
                        .foregroundColor(use == option ? OnboardingTheme.ink : OnboardingTheme.faint)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(use == option ? 0.12 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(use == option ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.04)))
        .fixedSize()
    }
}
