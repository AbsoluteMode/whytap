---
id: onboarding-journey-2026-11-22
type: decision
title: The first-launch onboarding becomes a small window of single steps that move on by themselves
summary: The five-page onboarding is replaced by one small window with a progress bar and up to fourteen single-purpose steps (speech source, speech key, optional language model, optional search, language, one screen per permission, Try Drop, shortcuts, Toolbox, help, thanks); a step whose action succeeds moves on after a short beat, steps done before the window opened are left out, Back keeps everything, and speech and the language model are set through the shared Speech and LLM rows.
status: confirmed
tags: [onboarding, first-launch, permissions, models, routing]
canonical_for: [onboarding-journey]
verified_at: 2026-11-22
sources:
  - type: user-confirmed
    reference: On 2026-11-22, after seeing three onboarding concepts, the maintainer described the flow through the orchestrating session - the user chooses local or API speech; with API they enter keys and choose an LLM plus a transcription model, or only transcription; the screen moves on by itself after a successful action, without Continue, in a small window with Back and a progress bar; the steps are local/API cards, transcription key, LLM key, search key for the Agent, language, permissions one by one (keyboard, then the rest), Screen Recording, Try Drop, a short tour of shortcuts and the Toolbox, a pointer to the whytap.ai agent for questions, and a thank-you. It must look and feel premium, with no AI-like animations. He also confirmed ("yes, for all speech") that the local model goes on every speech feature.
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingJourney.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingJourneyModel.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Tests/SidekeyTests/OnboardingJourneyModelTests.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingDwell.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingJourneyComponents.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingPreview.swift
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer asked, through the orchestrating session, to run the onboarding on its own, outside Whytap, and see all of it after every change.
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-22 the orchestrating session passed on a visual and motion pass by a separate design agent (Gemini 4 Carbon) as the base for the frame, not yet approved by the maintainer, with the instruction to move its components into the onboarding code and to check every text against what is true for all providers.
    confirmed_at: 2026-11-22
related: [2026-11-21-first-launch-onboarding.md]
---

# The first-launch onboarding becomes a small window of single steps that move on by themselves

## Context

The first-launch onboarding (2026-11-21) had five large pages, several
decisions on one page and a Continue button on each. On build 1701 the
maintainer could not tell where to go next on the speech page, and after
three concepts he described a different shape: one decision or action per
screen, the screen moving on by itself when the action succeeds, a small
window, Back and a progress bar.

## Decision

- **One small window** (520 × 440 pt): a fixed 32 × 24 pt Back slot, the
  progress rail and "NN / 13" on top; the act, a serif title and one line
  under it; the step's stage; a footer with Skip or Set up later on the left
  and the dwell pill on the right. Back also answers ← and ⌘[ outside text
  fields. The visual and motion come from the design pass (dark raised
  cards with a 1 pt top highlight, recessed key fields, near-critically
  damped springs, nothing moving at rest, opacity only under Reduce Motion).
- **Progress rail:** one equal micro-segment per step, a wider gap between
  the four acts (Engine, Access, Try Drop, Island). Done steps are green,
  the current one fills during the dwell and turns amber while held; a step
  skipped or made unnecessary is hollow, never a false "done".
- **Steps, in their only order** (`OnboardingStep`):
  1. Source: On this Mac or Your key (two cards).
  2. Speech key: Soniox, Deepgram or ElevenLabs.
  3. Language model key (optional): Anthropic, OpenAI or OpenRouter, with a
     preselected model.
  4. Search for the Agent (optional; only when a language model is set).
  5. Language.
  6. Keyboard control (Accessibility).
  7. Microphone.
  8. Input Monitoring, only when the Drop shortcut reports it needs it.
  9. Screen Recording (optional).
  10. Try Drop (only when speech is on the way).
  11. Shortcuts. 12. Toolbox. 13. Help on whytap.ai. 14. Thank you.
- **Moving on by itself, and holding (Dwell Latch).** When a shown step's
  action succeeds (a key accepted and applied, a permission turning granted,
  a dictation inserted, a language picked, a source chosen) its segment
  fills for the step's dwell (0.62 s for a choice, 0.78 s for a verified key
  or grant, 1.35 s after Try Drop; Reduce Motion adds 0.22 s) and the
  footer says "Next: …". The pointer over the stage, or the pill, holds it
  ("Paused · Stay as long as you need"); leaving resumes, Return or the pill
  goes on. Back to a step that is done, or to a tour step, shows "Continue ·
  …" and never moves by itself; Back during the dwell cancels it. The tour
  steps (Shortcuts, Toolbox, Help) move on after 4.2 s only when reached
  going forward. Required steps keep a quiet "Set up later", optional ones
  "Skip"; a step that is done without a pending move offers Next.
  Step 1 is the exception (the owner asked to remove the pill, 2026-11-22): a
  click on a figure, or Return on the figure in front, moves on at once,
  with no dwell, no pill and no Next, also after Back.
- **The page fills the whole window.** The window's content runs under its
  transparent title bar; inside the safe area the fixed 520×440 page was
  centred and its footer ran about 14 pt past the bottom edge on every step,
  so the page ignores the safe area and the header keeps its place with a
  24 pt top inset.
- **Done before means not shown.** Steps whose result already holds when the
  window opens (speech runs, an LLM is set, a Tavily key is saved, the
  language is chosen, a permission is granted) are left out; choices remove
  the steps they make unnecessary (On this Mac removes the speech key step;
  no language model removes search). A Drop press that finds a permission
  missing brings the permission steps back.
- **Speech and the LLM go through the shared rows.** A speech key, or On this
  Mac, is applied with `APIAndModelsViewModel.selectShared(kind: .speech)`;
  a language model key with `selectShared(kind: .llm)`, so one pick covers
  every feature of its kind it can serve (Meetings gets the recorded
  counterpart) and a feature it cannot serve keeps its route and is named in
  one line. Existing custom per-feature choices are kept. Local speech goes
  on every speech feature, as the maintainer confirmed.
- **The latest choice wins.** As on the 2026-11-21 speech page, every speech
  or language model action takes a new number; a key check, model check or
  download that answers after a newer action of its kind changes no route and
  moves nothing, and a late key save keeps only the key.
- **LLM preselection:** the Agent's registry model when there is one
  (Anthropic `claude-sonnet-5-5`, OpenRouter `anthropic/claude-sonnet-5.5`);
  OpenAI has none, so the newest model in its live catalog that the Agent
  can use (the catalog loads when the key is saved).
- **Permissions, one per screen**, from what the code actually needs:
  Accessibility gates the Space-hold event tap, the Right Command gesture,
  the focused-field check and Escape; the microphone gates Drop, Agent voice
  and meetings; Input Monitoring is only the tap's fallback; Post Event has
  no separate pane on current macOS and the paste engine no longer gates on
  it; System Audio Recording and Automation stay asked at first use.
- **Search, step 4.** Anthropic (Messages `web_search` server tool), OpenAI
  (Responses `web_search`) and OpenRouter (`openrouter:web_search`) each have
  built-in search at about $10 per 1,000 searches plus result tokens, so a
  user with one of those keys could search without a Tavily key. The native
  Agent cannot use it yet: it would have to round-trip server-tool blocks,
  handle `pause_turn` and mixed search/tool turns, and carry citations into
  `finish_answer.sources`. Until a separate Agent change does that, step 4
  offers a Tavily key; afterwards it offers "your model's built-in search"
  first.

- **Texts only say what holds for every provider** (corrections to the
  design pass): the API card does not promise free credit (Soniox has no
  free offer; Anthropic and OpenAI credits come with paid plans), so each
  provider tab shows its own offer from API hints or nothing; no latency
  claims for the local model, only "Free. Works offline." and its size; the
  search step offers only Tavily; shortcuts, the Agent's state and the
  Toolbox tiles come from the person's own HotkeyConfiguration, Agent switch
  and saved layout; the help example is a real answer (Settings → Hotkeys →
  Tools); the receipt reads the saved routes; nothing simulates dictation
  with the mouse, Try Drop uses the real field and shortcut.

- **OpenAI speech, once the app runs it.** The maintainer brought OpenAI
  back as a speech provider (task #73, `gpt-4o-transcribe` and
  `gpt-4o-mini-transcribe`). The speech key step offers OpenAI as a fourth
  tab as soon as the registry names an OpenAI Drop model
  (`OnboardingJourneyModel.offersOpenAISpeech`), with no separate switch.
  One OpenAI key serves both steps: a key saved on one of them opens the
  other on OpenAI with "Use saved", never asking for it again.
- **A standalone preview** (`scripts/onboarding-preview.sh`, executable
  target `OnboardingPreview`, never packaged) opens the whole onboarding from
  step 1 in the same window and model, outside Whytap: its own defaults
  suite emptied on start and quit, keys in memory, offline key checks,
  catalogs and Tavily check (a key containing "bad" is refused), Allow that
  only pretends macOS granted it, a timer for the speech model download and
  a Simulate Drop button. It starts no hotkeys, event taps, stores or island
  and never touches `com.rootwise.sidekey`, the Keychain or the network.
  It is not a Whytap instance (no bundle, shared stores, hotkeys or taps),
  so the one-running-copy rule does not cover it: the session that changed
  the onboarding opens it for the maintainer after each change.
- **Steps 1 and 2 in the wireframe language (draft, from the design pass):**
  a laptop and a key drawn as depth-sorted wire solids on a softly lit
  ground. Hover brings a figure forward; the other recedes, dimmer and
  without its caption. Step 2 is "Connect your speech key.": a dark pill
  field with the middle of the key masked, the speech providers only (with
  their logos from `UsefulLinkIcons`), the provider's real offer, and a
  quiet "Use your own server →" to Settings → API & Models. Only real key
  prefixes pick the provider (ElevenLabs `sk_`, OpenAI `sk-` once offered;
  Soniox and Deepgram keys have none). A refusal names one of five causes
  without blame: the key's shape (checked before any request), a refused
  key, an empty balance, a key without speech access, or no answer (with
  Retry); the key check has no separate rate-limit answer. The wire key
  turns in its lock when accepted and catches on a pin when refused. The
  footer pill no longer says "Hold"; the pointer still holds the move.
- **The wire figures move per display frame, not by SwiftUI animation.**
  Values a `Canvas` captures are not interpolated by `.animation`, so the
  first draft jumped between poses, and it drew at 30 fps. The stages now
  step the prototype's own damped springs (pose 135/19.5, fade and light
  150/22, key turn 160/18 on step 1; slide 140/20, turn 175/19 on step 2)
  on `TimelineView(.animation)` at the display's rate, keeping velocity
  when the hover target changes, with its pointer spin, hover tilt, screen
  pulse and checking light. Hover only updates the motion object, so no
  SwiftUI state or layout changes on pointer moves; captions are drawn in
  the same canvas. Reduce Motion snaps to the target and draws at 30 fps.

## Rejected

- Keeping Continue on every step: the maintainer asked for screens that move
  on by themselves.
- Moving on whenever a step is already done, including after Back: Back
  would bounce forward and could not be used to look at or change a choice.
- A separate per-feature speech or LLM choice in the onboarding: the shared
  rows already do one pick for all, and Advanced in Settings keeps custom
  models.
- A permanent Continue next to the automatic move: the pill appears only
  while a move is pending, held or reviewed.
- A move that cannot be stopped: the pointer on the stage holds it, so
  reading a result is never cut off.
- A Post Event screen: no separate System Settings pane on current macOS.
- Asking for System Audio Recording and Automation in the onboarding: they
  are only needed by Meetings and Now Playing and are asked at first use.

## What was tested

- `OnboardingJourneyTests`: which steps a clean Mac, a local choice, a key
  choice, a Mac without local speech, an LLM, a missing permission and a Mac
  where everything is done see; Next and Back walk the same list; a step a
  choice removed continues from its place; the bar runs from empty to full;
  a success moves once, Back cancels it, another step's success does not.
- `OnboardingJourneyModelTests` with temporary stores, in-memory keys and
  offline key/model checks: a speech key sets all five speech features
  (Meetings on the recorded model) and moves on after the beat; a refused key
  stays with the reason and sets nothing; a saved key is reused; an LLM key
  sets all four text features and brings the search step; skipping the LLM
  skips search; OpenAI preselects its newest usable catalog model; On this
  Mac with and without the model here; permissions granted while shown move
  on, granted elsewhere do not; Input Monitoring only when the shortcut needs
  it; informational steps end with Done; an earlier speech key whose check
  finishes last does not replace the later choice.
- `OnboardingJourneyTests` also covers the dwell controller: counting,
  latch and resume, commit now, review never firing, cancel, and the
  per-step dwell times.
- `OnboardingPreviewTests` also names each of the five key problems
  (and saves no refused key), accepts only real prefixes, keeps an
  Anthropic key out of speech and masks the middle of a key.
- `OnboardingPreviewTests`: the preview session walks every step with its
  fakes (refused and accepted keys, the stubbed Tavily check, pretend
  permissions, Simulate Drop, Back, finish) and writes routes only to its
  own suite; On this Mac finishes its timed download.
- OpenAI is not a speech tab until the registry has its speech model; an
  OpenAI key saved on the LLM step opens the speech step on it, and one
  saved for speech opens the LLM step on it.
- Offscreen renders (520 × 440) of every step, including a refused key, an
  accepted key while counting, a held step and Back to a reviewed step.

Not verified: the real window with real permissions, real provider key
checks, the motion itself (offscreen renders are still frames) and the
maintainer's approval of the visual.

2026-11-22 · branch `feature/onboarding-v2`
