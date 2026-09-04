import AppKit
import CoreText
import SwiftUI

/// Standalone preview app for the onboarding screens. No menu bar,
/// no hotkey, no backend — just one floating window cycling through
/// the welcome → agent screens against the real production
/// `VoiceOrbView` fed by scripted controllers. Close the window to
/// quit.

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private let welcomeOrb: OnboardingOrbController
    private let dropOrb: OnboardingOrbController
    private let agentOrb: OnboardingAgentController
    private let permissions: MockPermissionsSurface
    // Screenshot harness controls (preview-only). `PREVIEW_LANG` forces the
    // onboarding UI language (en/ru) at launch; `PREVIEW_STEP` forces the
    // flow to start on a specific step so a screen can be captured without
    // clicking through. Both default to nil → normal preview behaviour.
    private let uiLocale: OnboardingLocale
    private let initialStep: PreviewRoot.Step

    override init() {
        self.uiLocale = PreviewLaunchOptions.makeLocale()
        self.initialStep = PreviewLaunchOptions.initialStep()
        let welcomeURL = Bundle.module.url(
            forResource: "welcome-voice",
            withExtension: "mp3",
            subdirectory: "Audio"
        )
        if welcomeURL == nil {
            NSLog("OnboardingPreview: welcome-voice.mp3 missing — falling back to synthetic envelope")
        }
        self.welcomeOrb = OnboardingOrbController(audioURL: welcomeURL)
        self.dropOrb = OnboardingOrbController(
            transcript: "Hey, just confirming our sync moved to Thursday at 3 — I’ll send an updated invite shortly. Thanks!",
            audioURL: welcomeURL
        )
        self.agentOrb = OnboardingAgentController(
            samples: OnboardingAgentController.Sample.demoSet,
            audioURLProvider: { name in
                // Most demo clips are mp3; the agent demo's bespoke clip is an
                // m4a (generated via macOS `say`), so fall back to that.
                Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Audio")
                    ?? Bundle.module.url(forResource: name, withExtension: "m4a", subdirectory: "Audio")
            }
        )
        self.permissions = MockPermissionsSurface()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerBundledFonts()

        NSApp.setActivationPolicy(.regular)

        let root = PreviewRoot(
            welcomeOrb: welcomeOrb,
            dropOrb: dropOrb,
            agentOrb: agentOrb,
            permissions: permissions,
            uiLocale: uiLocale,
            initialStep: initialStep
        )
            .frame(
                width: OnboardingTheme.canvasWidth,
                height: OnboardingTheme.canvasHeight
            )
            .background(OnboardingTheme.bg)
            .preferredColorScheme(.dark)

        let hosting = NSHostingController(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: OnboardingTheme.canvasWidth,
                height: OnboardingTheme.canvasHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Onboarding Preview"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.contentViewController = hosting
        win.center()
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(
            red: 0.047, green: 0.047, blue: 0.063, alpha: 1.0
        )

        window = win

        // Reliable foreground activation for deterministic screenshots:
        // bring the app to a regular (Dock) policy, force it active even if
        // another app was frontmost, and order the window front regardless
        // of activation race so it never opens behind other windows.
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func registerBundledFonts() {
        let names = [
            "InstrumentSerif-Regular", "InstrumentSerif-Italic",
            // Cyrillic-capable serif for the Russian onboarding headlines
            // (Instrument Serif has no Cyrillic glyphs). ROO-261.
            "PlayfairDisplay-Regular", "PlayfairDisplay-Italic"
        ]
        for name in names {
            guard let url = Bundle.module.url(
                forResource: name,
                withExtension: "ttf",
                subdirectory: "Fonts"
            ) else {
                NSLog("OnboardingPreview: font missing — %@.ttf", name)
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                NSLog("OnboardingPreview: failed to register %@: %@",
                      name,
                      String(describing: error?.takeRetainedValue()))
            }
        }
    }
}

/// Routes welcome → agent. Agent's "Next" terminates the preview
/// (production goes on to permissions; preview stops at the demo
/// screens).
struct PreviewRoot: View {
    enum Step: String, CaseIterable {
        case welcome, agent, permissions, language, drop, tryDrop, tryAgent, skills, helpers
    }

    @ObservedObject var welcomeOrb: OnboardingOrbController
    @ObservedObject var dropOrb: OnboardingOrbController
    @ObservedObject var agentOrb: OnboardingAgentController
    @ObservedObject var permissions: MockPermissionsSurface
    // Injected from `PreviewDelegate` so `PREVIEW_LANG` / `PREVIEW_STEP`
    // can seed the language and starting step before the view appears.
    @ObservedObject var uiLocale: OnboardingLocale
    let initialStep: Step
    @StateObject private var agentSetup = MockAgentSetupSurface()
    @State private var step: Step
    @State private var selectedLanguage: AppLanguage? = nil

    init(
        welcomeOrb: OnboardingOrbController,
        dropOrb: OnboardingOrbController,
        agentOrb: OnboardingAgentController,
        permissions: MockPermissionsSurface,
        uiLocale: OnboardingLocale,
        initialStep: Step = .welcome
    ) {
        self.welcomeOrb = welcomeOrb
        self.dropOrb = dropOrb
        self.agentOrb = agentOrb
        self.permissions = permissions
        self.uiLocale = uiLocale
        self.initialStep = initialStep
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            stepBody
                .environmentObject(uiLocale)
            // Mirror the production flow's top-trailing controls: EN/RU
            // toggle in the far corner (always present), mute button to
            // its left when a demo is playing.
            HStack(spacing: 10) {
                if step == .welcome || step == .agent || step == .drop {
                    PreviewMuteButton(step: step,
                                      welcomeOrb: welcomeOrb,
                                      dropOrb: dropOrb,
                                      agentOrb: agentOrb)
                }
                OnboardingLanguageToggle()
                    .environmentObject(uiLocale)
            }
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
    }

    /// Extracted from `body` because the inline `Group { switch step }`
    /// pattern hits an "ambiguous use of `init(content:)`" error in
    /// release builds (SwiftUI vs SwiftUICore `Group` overloads —
    /// debug builds resolve it, release does not). A standalone
    /// `@ViewBuilder` computed property fixes the disambiguation
    /// without needing an explicit `Group<…>` type annotation.
    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeScreen(
                orb: welcomeOrb,
                onNext: { advance(to: .agent) }
            )
        case .agent:
            OnboardingAgentScreen(
                orb: agentOrb,
                onBack: { advance(to: .tryDrop) },
                onNext: { advance(to: .skills) }
            )
        case .tryAgent:
            OnboardingAgentTryScreen(
                surface: agentSetup,
                onBack: { advance(to: .agent) },
                onContinue: { advance(to: .helpers) }
            )
        case .skills:
            OnboardingSkillsScreen(
                agentSurface: agentSetup,
                initialAgentEnabled: false,
                initialMeetingsEnabled: false,
                initialGoogleEnabled: false,
                onToggle: { _, _ in },
                onBack: { advance(to: .tryDrop) },
                onContinue: { advance(to: .helpers) }
            )
        case .helpers:
            // Mirrors production (OnboardingFlowView): the helpers step renders
            // the localized Super-assistant showcase. The preview hosts it by
            // symlinking its Settings deps (HoverTool → SettingsWindowTab /
            // TranscriptionMode). ROO-261.
            OnboardingSuperAssistantScreen(
                onBack: { advance(to: .skills) },
                onContinue: { NSApp.terminate(nil) }
            )
        case .permissions:
            OnboardingPermissionsScreen(
                surface: permissions,
                onBack: { advance(to: .welcome) },
                onContinue: { advance(to: .tryDrop) }
            )
        case .language:
            OnboardingLanguageScreen(
                selected: $selectedLanguage,
                onBack: { advance(to: .permissions) },
                onContinue: { advance(to: .drop) }
            )
        case .drop:
            OnboardingDropScreen(
                orb: dropOrb,
                onBack: { advance(to: .language) },
                onContinue: { advance(to: .tryDrop) }
            )
        case .tryDrop:
            OnboardingTryDropScreen(
                onBack: { advance(to: .permissions) },
                onContinue: { advance(to: .skills) }
            )
        }
    }

    private func advance(to next: Step) {
        withAnimation(.easeInOut(duration: 0.24)) {
            step = next
        }
    }
}

/// Preview-only mute toggle. Sits in the top-right corner so it does
/// not interfere with the onboarding content. Acts on whichever
/// controller is currently driving the screen.
private struct PreviewMuteButton: View {
    let step: PreviewRoot.Step
    @ObservedObject var welcomeOrb: OnboardingOrbController
    @ObservedObject var dropOrb: OnboardingOrbController
    @ObservedObject var agentOrb: OnboardingAgentController

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute preview audio" : "Mute preview audio")
    }

    private var isMuted: Bool {
        switch step {
        case .welcome: return welcomeOrb.isMuted
        case .agent: return agentOrb.isMuted
        case .drop: return dropOrb.isMuted
        case .permissions, .language, .tryDrop, .tryAgent, .skills, .helpers: return welcomeOrb.isMuted
        }
    }

    private func toggle() {
        // Keep all controllers in sync so the user only flips one
        // switch — moving between demo screens doesn't bring audio
        // back unexpectedly.
        let next = !isMuted
        welcomeOrb.isMuted = next
        dropOrb.isMuted = next
        agentOrb.isMuted = next
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = PreviewDelegate()
    app.delegate = delegate
    app.run()
}
