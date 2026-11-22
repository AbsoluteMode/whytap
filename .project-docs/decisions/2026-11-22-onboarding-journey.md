---
id: onboarding-journey-2026-11-22
type: decision
title: The first-launch onboarding becomes a small window of single steps that move on by themselves
summary: The five-page onboarding is replaced by one small window with a progress bar and up to thirteen single-purpose steps (speech source, speech key, optional language model, language, one screen per permission, Try Drop, shortcuts, Toolbox, help, thanks); a step whose action succeeds moves on after a short beat, steps done before the window opened are left out, Back keeps everything, and speech and the language model are set through the shared Speech and LLM rows.
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
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingWireframe.swift
    confirmed_at: 2026-11-22
  - type: repository
    reference: Sources/Sidekey/Onboarding/OnboardingServerForm.swift
    confirmed_at: 2026-11-22
  - type: user-confirmed
    reference: On 2026-11-22 the maintainer accepted the onboarding screens in the standalone preview at commit 6d9f196c and asked to go on.
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
  progress rail and "NN / 12" on top; the act, a serif title and one line
  under it; the step's stage; a footer with Skip or Set up later on the left
  and Next on the right only when nothing moves on by itself. Back also answers ← and ⌘[ outside text
  fields. The visual and motion come from the design pass (dark raised
  cards with a 1 pt top highlight, recessed key fields, near-critically
  damped springs, nothing moving at rest, opacity only under Reduce Motion).
- **Progress rail:** one equal micro-segment per step, a wider gap between
  the four acts (Engine, Access, Try Drop, Island). Done steps are green,
  the current one fills during the dwell and turns amber while held; a step
  skipped or made unnecessary is hollow, never a false "done". A passed
  step reached again by Back stays green and is only lit (a soft glow and a
  light rim), never reset to white "in progress"; the owner asked for that
  on 2026-11-22 (`OnboardingSegmentState.revisited`). The gaps between acts
  stay.
- **Steps, in their only order** (`OnboardingStep`):
  1. Source: On this Mac or Your key (two cards).
  2. Speech key: Soniox, Deepgram or ElevenLabs.
  3. Language model key (optional): Anthropic, OpenAI or OpenRouter, with a
     preselected model.
  4. Language.
  5. Keyboard control (Accessibility).
  6. Microphone.
  7. Input Monitoring, only when the Drop shortcut reports it needs it.
  8. Screen Recording (optional).
  9. Try Drop (only when speech is on the way).
  10. Shortcuts. 11. Toolbox. 12. Help on whytap.ai. 13. Thank you.
  Web search for the Agent is not a step (see "Web search is not an
  onboarding step").
- **Moving on by itself, with no chip.** When a shown step's action
  succeeds (a key accepted and applied, a permission turning granted, a
  dictation inserted, a language picked, a source chosen) its segment fills
  for the step's dwell (0.62 s for a choice, 0.78 s for a verified key or
  grant, 1.15 s on the speech key so the padlock opens and settles first,
  1.35 s after Try Drop; Reduce Motion adds 0.22 s), then the step moves on
  with its animation. The owner removed every footer chip on 2026-11-22
  ("Next: …", "Paused · Stay as long as you need", "Continue · …"): Return
  still goes on at once without one. With no visible hold, the pointer no
  longer holds the move (a pointer resting on the page would have stopped
  it silently). Back to a step that is done, or to a tour step, never moves
  by itself and offers the plain Next; Back during the dwell cancels it.
  The tour steps (Shortcuts, Toolbox, Help) move on after 4.2 s only when
  reached going forward. Required steps keep a quiet "Set up later",
  optional ones "Skip"; a step that is done without a pending move offers
  Next. Step 1 has neither: its two figures are the choice (the owner asked
  to remove its skip).
  Step 1 is the exception (the owner asked to remove the pill, 2026-11-22): a
  click on a figure, or Return on the figure in front, is its Continue, with
  no pill and no Next, also after Back. It is not an instant cut either (the
  owner's clarification the same day): the click's own motion plays for
  0.34 s (the key turns a quarter and dips), then the chosen key flies on to
  step 2 while the page dissolves under it (the old page leaves in about
  0.2 s, the new one settles 0.1 s later), and Back flies it home the same
  way. A second choice during that beat wins.
- **The page fills the whole window.** The window's content runs under its
  transparent title bar; inside the safe area the fixed 520×440 page was
  centred and its footer ran about 14 pt past the bottom edge on every step,
  so the page ignores the safe area and the header keeps its place with a
  24 pt top inset.
- **Done before means not shown.** Steps whose result already holds when the
  window opens (speech runs, an LLM is set, the
  language is chosen, a permission is granted) are left out; choices remove
  the steps they make unnecessary (On this Mac removes the speech key step). A Drop press that finds a permission
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
  `finish_answer.sources`. That is a separate Agent change (session 78).
  Superseded on 2026-11-22 (below, "Web search is not an onboarding
  step").

- **Texts only say what holds for every provider** (corrections to the
  design pass): the API card does not promise free credit (Soniox has no
  free offer; Anthropic and OpenAI credits come with paid plans), so each
  provider tab shows its own offer from API hints or nothing; no latency
  claims for the local model, only "Free. Works offline." and its size; shortcuts, the Agent's state and the
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
  catalogs and server model checks (a key containing "bad" is refused), Allow that
  only pretends macOS granted it, a timer for the speech model download and
  a Simulate Drop button. It starts no hotkeys, event taps, stores or island
  and never touches `com.rootwise.sidekey`, the Keychain or the network.
  It is not a Whytap instance (no bundle, shared stores, hotkeys or taps),
  so the one-running-copy rule does not cover it: the session that changed
  the onboarding opens it for the maintainer after each change.
- **Steps 1 and 2 in the wireframe language (draft, from the design pass):**
  a laptop and a key drawn as depth-sorted wire solids on a softly lit
  ground. Hover brings a figure forward; the other recedes, dimmer and
  without its caption. Step 2 is "Paste your speech key.": a dark pill
  field with the whole key masked, the speech providers only (with
  their logos from `UsefulLinkIcons`), the provider's real offer, and a
  "Self-hosted" mark for your own server (see below). Only a key's own format picks
  the provider (see "Only a key's own format names its provider"). A refusal names one of five causes
  without blame: the key's shape (checked before any request), a refused
  key, an empty balance, a key without speech access, or no answer (with
  Retry); the key check has no separate rate-limit answer. The wire key
  turns in its lock when accepted and catches on a pin when refused. The
  footer has no chip at all (see "Moving on by itself, with no chip").
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
- **One key across steps 1 and 2.** The figures of both steps are one scene
  (`OnboardingWireScene`) drawn by one canvas above the page, so the key
  chosen on step 1 turns and flies to its lock on step 2 (and back on Back)
  on the same springs; only the steps' text and controls take the ordinary
  step transition. Two drawings with a cross-fade made the key jump, vanish
  and reappear. The steps report only their bands' vertical place (the step
  slide is sideways), and step 1's captions fade in the first third of the
  flight.
- **The design pass's padlock and light (delivered 2026-11-22).** Step 2
  uses its meshes and springs one to one: a chamfered padlock body with the
  keyhole toward the key and a tubular shackle; the key slides along the
  keyway (insertion 150/19: resting outside, a little in when pasted, seated
  while checking, short of the hole for a malformed key) and turns 185/18.
  Accepted: a quarter turn, then the shackle lifts (230/14.5) and swings
  open (180/14) with a small kick of the body. Refused: the key tries to
  turn (0.36 rad, 0.46 for credit or access), the padlock shudders and the
  key eases back. No answer: the lock dims and three dots fade toward it.
  The light is on the wires, not behind them: facets catching a grazing
  light turn rose-pearl on hover (step 1), and on step 2 a light from the
  field below goes rose, green when accepted and amber on a problem; the
  only glow is a faint dithered blush under the field, so nothing bands.
  The key and padlock use that prototype's ink (line width from the
  figure's size, full-strength dots in the vertices) and breathe slowly in
  depth and yaw, like the key on step 1.
- **The key field is a secure field.** Every input (Latin, Cyrillic,
  digits, symbols, the Russian layout's "№") is dots from its first
  character, with no visible start or end. A wrong format is named only by
  the error text on Return; the input never shows. The owner asked for the
  whole key closed, then saw a 17-character string and then a Russian
  layout's digits and symbols in clear, so no input is an exception. The
  mask keeps the length in the monospaced font (Cyrillic and "№" have the
  same advance as a dot), so the caret never moves. A native secure field
  was not used: it turns on Secure Event Input, which blocks Drop's own
  keyboard tap while focused.
- **Only a key's own format names its provider.** A real prefix, the
  longest that matches across every provider Whytap knows ("sk-ant-"
  Anthropic, "sk-or-" OpenRouter, "sk-proj-"/"sk-" OpenAI, "sk_"
  ElevenLabs), or Deepgram's 40 hexadecimal characters, and at least 20
  key characters. The owner saw a random string get the OpenAI mark, a
  green check and "check it with OpenAI": the step had fallen back to the
  last provider and kept an earlier acceptance while a new key was typed.
  Now nothing is guessed: an unrecognised key leaves the marks at rest, is
  not checked on paste, and Return calls it a format problem ("pick its
  provider below"). A mark the person clicks still names the provider
  (Soniox keys have no format of their own). A new key in the field is a
  new attempt: an earlier refusal clears, and an earlier acceptance no
  longer shows its check.
- **Step 2's layout follows the design pass.** One centred axis: title, the
  key over its lock, the field ("Paste your API key…"), one quiet line under
  it (empty at rest), four monochrome provider marks of one optical height
  with no preselected one (a mark shows its name on hover, when picked, or
  when the key is recognised: ElevenLabs and OpenAI by prefix, Deepgram by
  40 hexadecimal characters) and, last in the row, "Self-hosted". A
  picked mark offers "Need a … key? Get one" with the provider's real offer.
  "Set up later" stays in the footer like on every step, aligned with the
  field's edge. The standalone preview already shows OpenAI as the fourth
  provider; the app keeps it behind the registry until OpenAI speech lands.
- **The language model step is the same screen.** "Paste a language model
  key." uses the speech step's layout, key, padlock, mask, problems and
  dwell (1.15 s, so the lock opens before the move), with Anthropic, OpenAI
  and OpenRouter marks; a recognised key names the model it will set. The
  lock closes again when the step opens (the key withdraws), and the page
  flows under the key like step 1 into step 2. "Skip" stays in the footer.
- **The model is the person's choice, from the provider's current list.**
  The owner asked what the preset "gpt-5.6" was: a fixed name in the
  preview's fake catalog, while the app took OpenAI's newest catalog model
  and Anthropic's registry model. Now an accepted key starts on the
  provider's newest flagship from its own catalog: the newest generation
  (within 30 days of the newest text model) and in it the highest output
  price when OpenRouter's cached list prices are known (OpenAI
  `gpt-6.2-astra`, Anthropic `claude-fable-5-2` on 2026-11-22), otherwise the
  newest; small tiers, voice, search and dated snapshots are never the
  default. The registry is used only before the catalog exists. Under the
  accepted line a quiet "Choose model ⌄" (the owner: "after the key, Choose
  model, and there the Recommended tag"; no model name or price at rest)
  opens a small dark list of up to eight current models with prices
  (OpenRouter: each major author's flagship), the recommended one first and
  tagged (OpenRouter: `anthropic/claude-sonnet-5.5`). The owner read a cut
  "claude-son…" and asked how to read it, so each row shows a readable name
  that is never cut ("Claude Sonnet 5.5", "GPT-6.2 Sol",
  `OnboardingModelPick.readableName`), the ID small under it, a small
  "Recommended" tag beside the name, and the list is as wide as its longest
  row. The button says "Choose model ⌄" until the person picks a model (the
  recommended one included) and then names it, without a price; the owner
  asked why it still said "Choose model" after a pick. The recommended
  model is already set, and a step with a choice of models does not move on
  by itself: the owner was moved on before he could choose (2026-11-22). It
  waits, after the padlock opens, for a pick (through the shared row, then
  the move) or Next, which keeps the recommended model. The speech step does
  the same when its provider has more than one model (OpenAI: per-minute
  prices); steps without a choice move on by themselves as before. A native
  menu was not used: AppKit draws only one text of its label.
- **One model is recommended: the provider's current Sonnet or Sol.** The
  owner asked on 2026-11-22 for "Sonnet / Sol, the current one" as the
  onboarding's recommendation, replaceable by the person. The language model
  step therefore starts on the newest member of the provider's balanced
  family in its current catalog, chosen by name in one place
  (`OnboardingModelPick.recommended`): Anthropic `claude-sonnet-*`, OpenAI
  `gpt-*-sol`, OpenRouter `anthropic/claude-sonnet-*`. On 2026-11-22 that is
  `claude-sonnet-5-5` and `gpt-6.2-sol` (OpenAI's live /v1/models list, as
  cached by the app, lists `gpt-6.2-sol`, `gpt-6.1-sol` and `gpt-6-sol`). A
  family, not an ID, so a newer Sonnet or Sol takes over without a code
  change; a provider without that family falls back to the newest flagship.
  The list tags it "Recommended"; any other pick replaces it. The speech
  step recommends the registry's Drop model.
- **Web search is not an onboarding step.** First (REV 32) the step was
  left out when the language model searched the web itself and otherwise
  asked for a Tavily key on the key steps' screen. On 2026-11-22 the owner
  asked whether to drop Tavily together with the step; the decision was to
  drop only the step, for every provider and your own server. Search is set
  in Settings -> API & Models -> Models (the Search row, a separate change,
  session 78); Tavily stays in API keys for people on their own servers.
  The progress rail is one segment shorter ("NN / 12").
- **Your own server is a mark in the row and changes the step in place.**
  The owner asked on 2026-11-22 for the quiet "Use your own server →" link
  to become a card like the providers, captioned "Self-hosted": the row ends
  with a monochrome server mark of the marks' optical height, named on
  hover and while its fields are shown (on the speech step after Soniox,
  Deepgram, ElevenLabs and OpenAI; on the language model step after
  Anthropic, OpenAI and OpenRouter). The owner,
  2026-11-22: a separate screen (first a form over the window, in the app
  Settings) and a return to the key step before the move looked cobbled
  together. Now, in the app and the preview alike, the key field's capsule
  reshapes into the first of three fields of the same family (Base URL, an
  optional key, one model) and the other two unfold from it. The step says
  what the model is for, with no switch (the owner: self-hosted
  transcription on the speech step, an LLM on the language model step): a
  transcription model such as `whisper-large-v3-turbo` on speech, an LLM such
  as `qwen3:8b` on the language model step. A server added on one of them
  comes back filled in (address and key) on the other and is added once,
  with both models; the title reads "Your own server.", the wire key and
  padlock stay, the row stays under the fields with Self-hosted selected.
  A provider mark (or Escape, or Back) folds them into the key field again. Return on the model adds the server the way Settings
  does (`addServer`: the address answers, the key if any is accepted), runs
  the model's small check (`runServerModelCheck`), adds it and sets the
  shared Speech or LLM row; the padlock answers like for a key and success
  moves straight on to the next step, the fields still in place. A second
  try with the same address and key reuses the server. The name comes from
  the address (Ollama and LM Studio by their default ports, otherwise the
  host). The Settings path of the first version
  (`SettingsWindowSelection.requestNewServer`) was removed with it, so this
  branch no longer touches the Custom server tile of PR 408.

## Rejected

- Keeping Continue on every step: the maintainer asked for screens that move
  on by themselves.
- Moving on whenever a step is already done, including after Back: Back
  would bounce forward and could not be used to look at or change a choice.
- A separate per-feature speech or LLM choice in the onboarding: the shared
  rows already do one pick for all, and Advanced in Settings keeps custom
  models.
- A permanent Continue next to the automatic move, or any chip that names
  the next step: the owner removed them; Return goes on, Back stops.
- Holding the move while the pointer rests on the page: with no visible
  hold it silently stopped the move; the dwells are long enough to read the
  result instead.
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
  sets all four text features and goes on to the language; skipping the LLM
  goes on to the language; OpenAI preselects its newest usable catalog model; On this
  Mac with and without the model here; permissions granted while shown move
  on, granted elsewhere do not; Input Monitoring only when the shortcut needs
  it; informational steps end with Done; an earlier speech key whose check
  finishes last does not replace the later choice.
- `OnboardingJourneyTests` also covers the dwell controller: counting,
  latch and resume, commit now, review never firing, cancel, and the
  per-step dwell times.
- `OnboardingPreviewTests` also names each of the five key problems
  (and saves no refused key), names a provider only from a real format
  (random strings, short and Cyrillic input name nobody; Anthropic and
  OpenRouter keys only on the language model step), masks every input from
  its first character (Russian layout and symbols included, with the dots'
  width equal to the typed text's), calls an unnamed key a format problem until it
  is edited, turns the key field into the server fields and back on the
  same step (the name from the address; a saved server keeps its fields
  until the move), starts the language model step on the recommended model
  of a realistic catalog listed first, lists only current text models with
  prices, waits for a pick or Next (OpenRouter on its current Sonnet too)
  and applies a pick, offers OpenAI's speech models with
  per-minute prices, and checks the flagship rule on its own; the
  recommendation is the newest Sonnet or Sol. `OnboardingJourneyModelTests`
  add a server model with its check (a refused model keeps the fields, the
  retry reuses the server, the shared row takes it, the move goes straight
  to the language), and there is no web search step.
- `OnboardingPreviewTests`: the preview session walks every step with its
  fakes (refused and accepted keys, server model checks, pretend
  permissions, Simulate Drop, Back, finish) and writes routes only to its
  own suite; On this Mac finishes its timed download.
- OpenAI is not a speech tab until the registry has its speech model; an
  OpenAI key saved on the LLM step opens the speech step on it, and one
  saved for speech opens the LLM step on it.
- Offscreen renders (520 × 440) of every step, including a refused key, an
  accepted key while counting, a held step, Back to a reviewed step, the
  server fields on the speech and language model steps and an added server.

Not verified: the real window with real permissions, real provider key
checks, the motion itself (offscreen renders are still frames) and the
maintainer's approval of the visual.

2026-11-22 · branch `feature/onboarding-v2`
