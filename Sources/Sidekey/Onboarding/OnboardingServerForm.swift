import SwiftUI

/// What the own-server fields hold: an address, an optional key and one
/// model. The step says what the model is for: Transcription on the speech
/// step, LLM on the language model step.
struct OnboardingServerDraft: Equatable {
    var address = ""
    var key = ""
    var model = ""

    /// The base URL: http(s) with a host; "localhost:11434/v1" gets http://.
    var url: URL? { Self.url(from: address) }
    /// The server's name comes from its address.
    var name: String { url.map(Self.name(for:)) ?? "" }
    var canSave: Bool { url != nil && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
}

/// "Use your own server →" on a key step: the key field becomes three
/// fields of the same family in the same place (Base URL, an optional key,
/// one model: a transcription model on the speech step, an LLM on the
/// language model step), over the same key and padlock.
/// Return moves down the fields and, on the model, adds the server; the
/// padlock answers like it does for a key, and success moves straight on.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
struct OnboardingServerFields: View {
    static let pillHeight: CGFloat = 40

    let kind: OnboardingKeyStageKind
    @ObservedObject var model: OnboardingJourneyModel
    let scene: OnboardingWireScene
    /// The key field's capsule, so it reshapes into the first field.
    let morph: Namespace.ID
    /// The two lower fields unfold out of the first one, and fold back
    /// into it before "Back to keys" turns it into the key field again.
    @Binding var grown: Bool

    @State private var draft: OnboardingServerDraft
    @FocusState private var focus: Field?

    private enum Field { case address, key, model }

    init(kind: OnboardingKeyStageKind, model: OnboardingJourneyModel, scene: OnboardingWireScene,
         morph: Namespace.ID, grown: Binding<Bool>) {
        self.kind = kind
        self.model = model
        self.scene = scene
        self.morph = morph
        _grown = grown
        // The server added on the other key step comes back filled in.
        _draft = State(initialValue: model.serverPrefill(for: kind) ?? OnboardingServerDraft())
    }

    private var step: OnboardingStep { kind.step }
    private var outcome: OnboardingStepOutcome { model.outcome(step) }
    private var checking: Bool { if case .working = outcome { return true } else { return false } }
    private var accepted: Bool { outcome.isDone }
    private var failure: String? { if case .failed = outcome { return outcome.failureText } else { return nil } }

    var body: some View {
        VStack(spacing: 6) {
            pill(icon: "server.rack", first: true) {
                TextField("", text: $draft.address,
                          prompt: Text("Base URL · http://localhost:11434/v1").foregroundColor(OnboardingTheme.faint))
                    .textFieldStyle(.plain)
                    .font(OnboardingTheme.sans(13.5))
                    .foregroundColor(OnboardingTheme.ink)
                    .focused($focus, equals: .address)
                    .onSubmit { focus = .key }
                    .accessibilityLabel("Base URL")
            }
            pill(icon: "key") {
                SecureField("", text: $draft.key,
                            prompt: Text("API key · optional").foregroundColor(OnboardingTheme.faint))
                    .textFieldStyle(.plain)
                    .font(OnboardingTheme.sans(13.5))
                    .foregroundColor(OnboardingTheme.ink)
                    .focused($focus, equals: .key)
                    .onSubmit { focus = .model }
                    .accessibilityLabel("API key, optional")
            }
            .opacity(grown ? 1 : 0)
            .offset(y: grown ? 0 : -(Self.pillHeight + 6))
            pill(icon: "cube") {
                TextField("", text: $draft.model,
                          prompt: Text(kind == .speech ? "Transcription model · e.g. whisper-large-v3-turbo"
                                       : "LLM · e.g. qwen3:8b").foregroundColor(OnboardingTheme.faint))
                    .textFieldStyle(.plain)
                    .font(OnboardingTheme.sans(13.5))
                    .foregroundColor(OnboardingTheme.ink)
                    .focused($focus, equals: .model)
                    .onSubmit(save)
                    .accessibilityLabel(kind == .speech ? "Transcription model name" : "LLM name")
                trailing
            }
            .opacity(grown ? 1 : 0)
            .offset(y: grown ? 0 : -2 * (Self.pillHeight + 6))
            line
                .font(OnboardingTheme.sans(12))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .frame(height: 18, alignment: .top)
                .padding(.top, 2)
                .opacity(grown ? 1 : 0)
        }
        .disabled(checking || accepted)
        .onChange(of: draft) { _, _ in model.keyEdited(on: step) }
        .onAppear { focus = draft.url == nil ? .address : .model }
    }

    @ViewBuilder private var line: some View {
        if checking {
            Text("Checking \(draft.name) and \(draft.model)…").foregroundColor(OnboardingTheme.muted)
        } else if accepted, case .done(let what) = outcome {
            Text("\(what) · added").foregroundColor(OnboardingTheme.green)
        } else if let failure {
            Text(failure).foregroundColor(OnboardingTheme.orange)
        } else if !draft.address.trimmingCharacters(in: .whitespaces).isEmpty, draft.url == nil {
            Text("Enter an address like http://localhost:11434/v1").foregroundColor(OnboardingTheme.orange)
        } else if draft.url != nil {
            Text("\(draft.name) · any OpenAI-compatible server").foregroundColor(OnboardingTheme.muted)
        } else {
            Text("Ollama, LM Studio, vLLM or any OpenAI-compatible server").foregroundColor(OnboardingTheme.faint)
        }
    }

    private var trailing: some View {
        let ready = draft.canSave
        return Button(action: save) {
            Image(systemName: accepted ? "checkmark" : checking ? "ellipsis" : "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accepted ? OnboardingTheme.green : ready && !checking ? .black : OnboardingTheme.muted)
                .frame(width: 28, height: 28)
                .background(Circle().fill(accepted ? OnboardingTheme.green.opacity(0.16)
                                          : checking ? Color.clear : ready ? Color.white : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .disabled(!ready || checking || accepted)
        .accessibilityLabel(accepted ? "Server added" : checking ? "Checking" : "Add server")
    }

    private func save() {
        guard draft.canSave, !checking, !accepted else {
            if draft.url == nil { focus = .address } else if draft.model.isEmpty { focus = .model }
            return
        }
        let draft = self.draft
        let kind = self.kind
        Task { await model.saveServer(draft, on: kind) }
    }

    private var border: Color {
        if accepted { return OnboardingTheme.green.opacity(0.55) }
        if failure != nil { return OnboardingTheme.orange.opacity(0.50) }
        if checking { return OnboardingWireframeInk.roseColor.opacity(0.45) }
        return Color.white.opacity(0.10)
    }

    private func pill<Content: View>(icon: String, first: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(OnboardingTheme.ink)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.07)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .accessibilityHidden(true)
            content()
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: Self.pillHeight)
        .background(Capsule().fill(Color(red: 0.086, green: 0.086, blue: 0.098))
            .matchedGeometryEffect(id: first ? "field" : "field-\(icon)", in: morph))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 10)
        .background(GeometryReader { proxy in
            let y = proxy.frame(in: .named(OnboardingWireScene.space)).midY
            Color.clear
                .onAppear { if first { scene.fieldY = y } }
                .onChange(of: y) { _, new in if first { scene.fieldY = new } }
        })
    }
}
