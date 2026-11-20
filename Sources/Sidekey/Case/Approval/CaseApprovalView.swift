import AppKit
import Combine
import SwiftUI

/// The Case Approve prompt: one compact black card attached under the island, at
/// the island's width. App, project with key names, the command on one line, and
/// two bottom answers and a separate temporary Bypass action.
struct CaseApprovalView: View {
    let request: CaseApprovalRequest
    let width: CGFloat
    let pendingCount: Int
    let isArmed: Bool
    let onChoose: (CaseApprovalOutcome) -> Void
    var timedMinutes: Int? = nil
    var onTimedMinutesChange: (Int) -> Void = { _ in }
    var onMinutesEditingChange: (Bool) -> Void = { _ in }
    /// Whytap's own icon on the harness card; the running app's by default.
    var appIcon: NSImage? = nil

    @State private var validTimedInput = true
    @State private var editingMinutes = false
    @State private var hoveringMinutes = false
    @State private var hoveringCommand = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let bottomCornerRadius: CGFloat = 18
    static let accent = Color(red: 0.18, green: 0.43, blue: 0.96)

    // MARK: Copy (pure, tested)

    static func titleText(_ r: CaseApprovalRequest) -> String {
        "\(r.appName) wants to run a command"
    }

    static func keysText(_ r: CaseApprovalRequest) -> String {
        "\(r.projectName): \(r.keyNames.joined(separator: ", "))"
    }

    /// The harness access prompt. WHY: .project-docs/decisions/2026-11-20-harness-access.md
    static func harnessTitle(_ client: HarnessClient) -> String {
        "Give \(client.name) access to Whytap?"
    }

    /// Not shown on the card (the user asked for one line); read by VoiceOver.
    static let harnessDetail = "It can read your meetings and change settings for you. Case keys keep their own approval."

    /// The card overlaps the island's bottom edge by this much, so no line of
    /// the island's rim or of the desktop shows between the two surfaces.
    static let islandSeam: CGFloat = 1

    static func harnessConnectedTitle(_ client: HarnessClient) -> String {
        "\(client.name) connected"
    }

    /// The bundled brand mark and its tint on the black card.
    static func harnessMark(_ client: HarnessClient) -> (asset: String?, tint: Color) {
        switch client.identity.signingIdentifier {
        case "com.anthropic.claude-code": return ("claude-code", Color(red: 0.85, green: 0.47, blue: 0.34))
        case "codex": return ("codex", .white)
        default: return (nil, .white)
        }
    }

    static func timedTitle(minutes: Int) -> String {
        "Bypass for \(minutes) min"
    }

    /// The command on a single line: line breaks and runs of whitespace collapse to
    /// one space; the view truncates the tail with «…».
    static func commandLine(_ command: String) -> String {
        command.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    // MARK: Body

    var body: some View {
        Group {
            if let harness = request.harness {
                harnessContent(harness)
            } else {
                secretsContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8 + Self.islandSeam)
        .padding(.bottom, 12)
        .frame(width: width, alignment: .leading)
        .background(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: Self.bottomCornerRadius,
                bottomTrailingRadius: Self.bottomCornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.harness.map { "\(Self.harnessTitle($0)) \(Self.harnessDetail)" }
            ?? "\(Self.titleText(request)). \(Self.keysText(request))")
    }

    private var secretsContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            VStack(alignment: .leading, spacing: 6) {
                keysLine
                commandBox
            }
            if request.timedMinutes > 0 {
                HStack(spacing: 8) {
                    CaseApprovalButton(title: "Temporary Bypass", key: CaseApprovalKey.timed.keycap, prominent: false) {
                        onChoose(.allowTimed(minutes: selectedMinutes))
                    }
                    .disabled(!isArmed || !validTimedInput)
                    .opacity(isArmed && validTimedInput ? 1 : 0.5)
                    .accessibilityLabel(Self.timedTitle(minutes: selectedMinutes))
                    .help("No prompts for this agent and project for \(selectedMinutes) min")
                    .accessibilityIdentifier("case.approval.timed")
                    HStack(spacing: 4) {
                        CaseApprovalMinutesField(value: selectedMinutes, onChange: onTimedMinutesChange,
                                                 onEditingChange: {
                                                     editingMinutes = $0
                                                     onMinutesEditingChange($0)
                                                 }, onValidityChange: { validTimedInput = $0 })
                            .frame(width: 34, height: 24)
                            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(hoveringMinutes ? 0.15 : 0.08)))
                            .onHover { hoveringMinutes = $0 }
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(editingMinutes ? .white.opacity(0.75) : .white.opacity(0.16), lineWidth: 1))
                        Text("min")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }
            }
            buttons
        }
    }

    /// Who asks, in one glance: the harness's mark joined to Whytap's icon,
    /// the question and the two answers.
    private func harnessContent(_ client: HarnessClient) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                CaseApprovalHarnessLink(client: client, appIcon: appIcon, lit: 0)
                    .frame(maxWidth: .infinity)
                if pendingCount > 0 { pendingBadge }
            }
            .padding(.top, 4)
            Text(Self.harnessTitle(client))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                CaseApprovalButton(title: "No", key: CaseApprovalKey.no.keycap, prominent: false) { onChoose(.deny) }
                CaseApprovalButton(title: "Yes", key: CaseApprovalKey.yes.keycap, prominent: true) { onChoose(.allow) }
            }
            .opacity(isArmed ? 1 : 0.5)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isArmed)
            .disabled(!isArmed)
            .padding(.top, 2)
        }
    }

    private var pendingBadge: some View {
        Text("+\(pendingCount)")
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .accessibilityLabel("\(pendingCount) more in queue")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
            // The app name gives way first; the phrase always stays readable.
            HStack(spacing: 3.5) {
                Text(request.appName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("wants to run a command")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(0.62))
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 4)
            if pendingCount > 0 {
                Text("+\(pendingCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .accessibilityLabel("\(pendingCount) more in queue")
            }
        }
        .frame(height: 16)
    }

    private var keysLine: some View {
        (Text(request.projectName).fontWeight(.semibold).foregroundColor(Color.white.opacity(0.9))
            + Text(": " + request.keyNames.joined(separator: ", ")).foregroundColor(Color.white.opacity(0.6)))
            .font(.system(size: 11.5))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var commandBox: some View {
        Text(Self.commandLine(request.command))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.88))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hoveringCommand ? 0.13 : 0.08)))
            .onHover { hoveringCommand = $0 }
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .help(request.command)
            .accessibilityLabel("Command: \(request.command)")
    }

    private var buttons: some View {
        HStack(spacing: 6) {
            CaseApprovalButton(title: "Deny", key: CaseApprovalKey.no.keycap, prominent: false) { onChoose(.deny) }
            CaseApprovalButton(title: "Allow", key: CaseApprovalKey.yes.keycap, prominent: true) { onChoose(.allow) }
        }
        .opacity(isArmed ? 1 : 0.5)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isArmed)
        .disabled(!isArmed)
    }

    private var selectedMinutes: Int { timedMinutes ?? request.timedMinutes }
}

/// Native text editing in the nonactivating panel. Intermediate invalid input
/// stays visible, disables timed approval and reverts to the last valid value on
/// blur/Return. Escape restores the value from before editing, without denial.
struct CaseApprovalMinutesField: NSViewRepresentable {
    let value: Int
    let onChange: (Int) -> Void
    let onEditingChange: (Bool) -> Void
    let onValidityChange: (Bool) -> Void

    static func minutes(from text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(text), CaseViewModel.timedApprovalRange.contains(value) else { return nil }
        return value
    }

    func makeNSView(context: Context) -> CaseApprovalMinutesTextField {
        let field = CaseApprovalMinutesTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        field.textColor = .white
        field.stringValue = String(value)
        field.delegate = context.coordinator
        field.onEditingChange = onEditingChange
        field.setAccessibilityLabel("Temporary Bypass, minutes")
        field.setAccessibilityHelp("1 to 240 minutes. Return confirms, Escape restores the previous value.")
        field.setAccessibilityIdentifier("case.approval.minutes")
        field.toolTip = "1 to 240 minutes"
        return field
    }

    func updateNSView(_ field: CaseApprovalMinutesTextField, context: Context) {
        context.coordinator.parent = self
        field.onEditingChange = onEditingChange
        if field.currentEditor() == nil { field.stringValue = String(value) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    static func dismantleNSView(_ field: CaseApprovalMinutesTextField, coordinator: Coordinator) {
        field.removeWindowObserver()
        field.delegate = nil
        field.onEditingChange = { _ in }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CaseApprovalMinutesField
        private var initialValue: Int
        private var lastValidValue: Int
        init(parent: CaseApprovalMinutesField) {
            self.parent = parent
            self.initialValue = parent.value
            self.lastValidValue = parent.value
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            initialValue = parent.value
            lastValidValue = parent.value
            parent.onEditingChange(true)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let minutes = CaseApprovalMinutesField.minutes(from: field.stringValue)
            parent.onValidityChange(minutes != nil)
            field.textColor = minutes == nil ? .systemOrange : .white
            if let minutes {
                lastValidValue = minutes
                parent.onChange(minutes)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            field.stringValue = String(lastValidValue)
            field.textColor = .white
            parent.onValidityChange(true)
            parent.onEditingChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                lastValidValue = initialValue
                parent.onChange(initialValue)
                (control as? NSTextField)?.stringValue = String(initialValue)
            case #selector(NSResponder.insertNewline(_:)):
                break
            default: return false
            }
            control.window?.makeFirstResponder(nil)
            control.window?.resignKey()
            return true
        }
    }
}

/// Reject non-digits during typing and paste, before they appear in the editor.
/// Empty/out-of-range digit drafts remain editable; the coordinator validates 1...240.
final class CaseApprovalMinutesFormatter: Formatter {
    override func string(for obj: Any?) -> String? {
        (obj as? String) ?? (obj as? NSNumber)?.stringValue
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard Self.accepts(string) else { return false }
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialString: String,
                                       newEditingString newString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                       errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        Self.accepts(partialString)
    }

    private static func accepts(_ text: String) -> Bool {
        text.utf8.allSatisfy { (48...57).contains($0) }
    }
}

@MainActor
final class CaseApprovalMinutesTextField: NSTextField {
    var onEditingChange: (Bool) -> Void = { _ in }
    private var resignKeyObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        formatter = CaseApprovalMinutesFormatter()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        formatter = CaseApprovalMinutesFormatter()
    }
    override var needsPanelToBecomeKey: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onEditingChange(true) }
        return accepted
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onEditingChange(true)
        window?.makeKey()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeWindowObserver()
        guard let window else { return }
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.makeFirstResponder(nil)
                self?.onEditingChange(false)
            }
        }
    }

    func removeWindowObserver() {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
    }

    deinit {
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
    }
}

/// One answer: a capsule with its title and its key, the key drawn by `HotkeyHintView`.
private struct CaseApprovalButton: View {
    let title: String
    let key: String
    let prominent: Bool
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                HotkeyHintView(keys: [key], style: .keycaps, size: .compact)
            }
            .foregroundStyle(Color.white.opacity(prominent ? 1 : 0.88))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(CaseApprovalButtonStyle(prominent: prominent))
        .focused($focused)
        .overlay(Capsule().strokeBorder(focused && isEnabled ? .white.opacity(0.9) : .clear, lineWidth: 1))
        .accessibilityLabel(title)
        .accessibilityHint("Press \(key)")
    }

}

private struct CaseApprovalButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Capsule().fill(fill(pressed: configuration.isPressed)))
            .onHover { hovering = $0 }
    }

    private func fill(pressed: Bool) -> Color {
        let active = isEnabled && hovering
        if prominent {
            return CaseApprovalView.accent.opacity(isEnabled && pressed ? 0.72 : (active ? 1 : 0.9))
        }
        return .white.opacity(isEnabled && pressed ? 0.25 : (active ? 0.18 : 0.11))
    }
}

/// The harness's brand mark on a soft disk; a generic glyph for an unknown one.
private struct CaseApprovalHarnessMark: View {
    let client: HarnessClient
    var size: CGFloat = 34

    var body: some View {
        let mark = CaseApprovalView.harnessMark(client)
        ZStack {
            Circle().fill(Color.white.opacity(0.1))
            Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            if let asset = mark.asset {
                ProviderBrandIcon(assetName: asset, size: size * 0.56, color: mark.tint)
            } else {
                ProviderBrandIcon(systemName: "terminal.fill", size: size * 0.56, color: mark.tint)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The harness's mark, three dots and Whytap's icon. `lit` dots are green:
/// the connection being made, one dot at a time.
struct CaseApprovalHarnessLink: View {
    static let connectedColor = Color(red: 0.2, green: 0.78, blue: 0.35)

    let client: HarnessClient
    var appIcon: NSImage?
    let lit: Int

    var body: some View {
        HStack(spacing: 9) {
            CaseApprovalHarnessMark(client: client)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index < lit ? Self.connectedColor : Color.white.opacity(0.32))
                        .frame(width: 3, height: 3)
                        .scaleEffect(index < lit ? 1.35 : 1)
                }
            }
            Image(nsImage: appIcon ?? NSApp?.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 40, height: 40)
                // Whytap's icon is black: a hairline keeps its shape on the black card.
                .overlay(RoundedRectangle(cornerRadius: 7.6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                    .padding(3.9))
        }
        .accessibilityHidden(true)
    }
}

/// Shown after Yes in place of the question: the same two marks, the dots
/// between them lighting up one by one, then the name with a checkmark.
struct CaseApprovalConnectedView: View {
    /// Dots, then the checkmark.
    static let steps = 4
    static let dotInterval: TimeInterval = 0.11

    let client: HarnessClient
    let width: CGFloat
    var appIcon: NSImage? = nil
    /// A fixed moment of the animation, for pictures; nil plays it.
    var fixedStep: Int? = nil

    @State private var played = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var step: Int { fixedStep ?? played }
    private var done: Bool { step >= Self.steps }

    var body: some View {
        VStack(spacing: 10) {
            CaseApprovalHarnessLink(client: client, appIcon: appIcon, lit: min(step, 3))
                .scaleEffect(done ? 1 : 0.97)
                .padding(.top, 4)
            HStack(spacing: 6) {
                Text(CaseApprovalView.harnessConnectedTitle(client))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CaseApprovalHarnessLink.connectedColor)
                    .scaleEffect(done ? 1 : 0.2)
                    .opacity(done ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .opacity(step == 0 ? 0.55 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8 + CaseApprovalView.islandSeam)
        .padding(.bottom, 14)
        .frame(width: width)
        .background(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: CaseApprovalView.bottomCornerRadius,
                bottomTrailingRadius: CaseApprovalView.bottomCornerRadius, topTrailingRadius: 0, style: .continuous
            )
            .fill(Color.black)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .task {
            guard fixedStep == nil else { return }
            guard !reduceMotion else { return played = Self.steps }
            for next in 1...3 {
                try? await Task.sleep(nanoseconds: UInt64(Self.dotInterval * 1_000_000_000))
                withAnimation(.easeOut(duration: 0.14)) { played = next }
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.dotInterval * 1_000_000_000))
            withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) { played = Self.steps }
        }
    }
}

/// Hosts `CaseApprovalView` for the controller's visible prompt.
struct CaseApprovalHostView: View {
    @ObservedObject var controller: CaseApprovalController
    let width: CGFloat

    var body: some View {
        if let request = controller.current {
            CaseApprovalView(
                request: request,
                width: width,
                pendingCount: controller.pendingCount,
                isArmed: controller.isArmed,
                onChoose: { controller.choose($0) },
                timedMinutes: controller.selectedTimedMinutes,
                onTimedMinutesChange: { controller.setTimedMinutes($0) },
                onMinutesEditingChange: { controller.setEditingMinutes($0) }
            )
            // A new prompt is a new card (resets hover and the countdown).
            .id(controller.promptSerial)
        } else if let connected = controller.connected {
            CaseApprovalConnectedView(client: connected, width: width)
        }
    }
}

/// Borderless non-activating panel that attaches the prompt directly under the
/// island (under the meeting nudge or the agent answer card when one is up), at
/// the island's width. A
/// separate panel like `MeetingPillPanel`, so its buttons get clicks without
/// widening the island window's hit zones. It becomes key only for an explicit
/// click in the minutes field; otherwise answer keys come from `CaseApprovalKeyTap`.
@MainActor
final class CaseApprovalPanel: NSPanel {
    private let controller: CaseApprovalController
    private let host: CaseApprovalHostingView
    private let present: (NSPanel) -> Void
    private var cancellables = Set<AnyCancellable>()

    init(controller: CaseApprovalController, present: @escaping (NSPanel) -> Void = { $0.orderFrontRegardless() }) {
        self.controller = controller
        self.present = present
        host = CaseApprovalHostingView(rootView: AnyView(EmptyView()))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 312, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllApplications, .canJoinAllSpaces, .stationary, .ignoresCycle,
                              .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = host
        // A request must not select its only text field when the panel gets key status.
        // WHY: docs/decisions/2026-10-21-case-approval-minutes-input.md
        initialFirstResponder = host

        // Release the old field editor synchronously before a queued prompt
        // replaces its view. Visibility can stay true across that transition.
        controller.$promptSerial
            .removeDuplicates()
            .sink { [weak self] _ in self?.finishMinutesEditing() }
            .store(in: &cancellables)
        controller.$current
            .combineLatest(controller.$connected)
            .map { $0 != nil || $1 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in self?.apply(visible: visible) }
            .store(in: &cancellables)
        // The prompt gives way to its shorter confirmation: fit the panel to it.
        controller.$connected
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrameIfVisible() }
            .store(in: &cancellables)
        AppState.shared.$meetingSuggestionActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrameIfVisible() }
            .store(in: &cancellables)
        AppState.shared.$agentAnswerCardHeight
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshFrameIfVisible() }
            .store(in: &cancellables)
        for name in [NSApplication.didChangeScreenParametersNotification,
                     IslandScreenResolver.selectionDidChangeNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshFrameIfVisible() }
                .store(in: &cancellables)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Gap between the agent answer card and the prompt under it.
    static let agentCardGap: CGFloat = 6

    /// Where the card goes: centered under the island, below the meeting nudge or
    /// the agent answer card (which hangs `agentWingGap` under the island) if shown.
    /// The built-in agent running `whytap case run` shows both at once.
    static func frame(islandFrame: NSRect, cardHeight: CGFloat, meetingNudgeVisible: Bool,
                      agentAnswerHeight: CGFloat = 0) -> NSRect {
        let nudge = meetingNudgeVisible ? MeetingPillPanel.suggestionNudgeHeight : 0
        let agent = agentAnswerHeight > 0
            ? IslandFrameLayout.agentWingGap + agentAnswerHeight + agentCardGap : 0
        // Attached surfaces overlap by the seam; under the agent card the
        // prompt keeps its own gap.
        let top = islandFrame.minY - max(nudge, agent) + (agent > 0 ? 0 : CaseApprovalView.islandSeam)
        return NSRect(x: islandFrame.midX - islandFrame.width / 2, y: top - cardHeight,
                      width: islandFrame.width, height: cardHeight)
    }

    private func apply(visible: Bool) {
        if visible {
            sharingType = PrivacyPreferences.shared.screenshotProtectionEnabled ? .none : .readOnly
            refreshFrame()
            finishMinutesEditing()
            present(self)
        } else {
            finishMinutesEditing()
            orderOut(nil)
        }
    }

    private func finishMinutesEditing() {
        makeFirstResponder(host)
        if isKeyWindow { resignKey() }
        controller.setEditingMinutes(false)
    }

    private func refreshFrameIfVisible() {
        guard isVisible else { return }
        refreshFrame()
    }

    private func refreshFrame() {
        let islandFrame = IslandFrameLayout.islandFrame(on: IslandScreenResolver.currentDescriptor())
        host.rootView = AnyView(CaseApprovalHostView(controller: controller, width: islandFrame.width))
        let height = ceil(host.fittingSize.height)
        let target = Self.frame(islandFrame: islandFrame, cardHeight: max(height, 1),
                                meetingNudgeVisible: AppState.shared.meetingSuggestionActive,
                                agentAnswerHeight: AppState.shared.agentAnswerCardHeight)
        setFrame(target, display: true, animate: false)
        host.frame = NSRect(origin: .zero, size: target.size)
    }
}

/// Buttons work on first click without acquiring keyboard focus. The native
/// minutes field explicitly requests key status when the person edits it.
private final class CaseApprovalHostingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
