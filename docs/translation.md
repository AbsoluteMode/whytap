# Translation and system-audio subtitles

**Settings → Features → Translate & Subtitles** shows both tools on one screen:
their shortcuts, what each needs, and buttons that open them.

Open **Translate** or **Subtitles** from the island's tool search. Add either
button in **Settings → Toolbox** if you want it pinned. Each tool can have its
own shortcut in **Settings → Hotkeys**; no existing shortcut or layout changes.
Pressing the same shortcut again closes its window.
In Toolbox, select either tile to use it directly in the right pane. The floating
window and Toolbox share translation content and language preferences. Leaving
the mini app or closing Settings cancels its work unless the floating translator
is also visible. Selecting the tile alone never starts capture or a request.

From the island, both tools open the same floating, resizable window, including over full-screen
apps. Escape closes it and cancels translation/capture. The borderless text
palette has no title bar or input hint. Its full-width input band is slightly
lighter than the result below. Every open returns the caret to the input. Click outside it to close and cancel
translation; the click still reaches the app you chose. Its context menu stays
usable. Subtitles stay open when you interact with the video or another app.
Drag the palette background to move it.

## Setup

In **Settings → Keys & models**, choose:

- **Translation**: a language model from OpenRouter, OpenAI, Anthropic or your
  own OpenAI-compatible server, for typed text.
- **Subtitles** is an ordinary row with its model already chosen by your
  keys: **Soniox · stt-rt-v6** when your Soniox key (the one Drop uses) is
  saved in **API keys**, otherwise **OpenAI · gpt-realtime-translate** with
  your OpenAI key. Both hear and translate in one step. Soniox gives each
  phrase's translation about a second after it ends, for about $0.12 per hour
  of audio; OpenAI runs 3–4 seconds behind, for about $3.06 per hour. There is
  nothing to choose. Without either key the row looks like any other row that
  cannot run yet, its menu offers **Add a Soniox key…**, and **Start** says
  "Subtitles need a Soniox or OpenAI key" with a button to **API & Models**. Subtitles models chosen in earlier versions (Speech and LLM) are no
  longer used.

  This Subtitles setup comes with the next version after 2.2.26. In 2.2.26
  Subtitles have two rows of their own: a speech model (a provider or On this
  Mac) for the system audio and a language model that translates finished
  phrases.
- A Subtitles session ends by itself after one hour, exactly as if you had
  pressed **Stop**: nothing is shown and **Start** begins a new hour. This
  keeps a forgotten session from spending your provider credit.

Keys stay in Whytap's existing Keychain store. New routes start **Not set**.
The app never borrows another feature's model or chooses a replacement
provider after a failure.

## Text

The quick palette has two rows: input and translation, like the standalone
Realtime Translator. Type or paste text and press **Return** (or **Command
Return**). There is no separate Translate button. The second row shows the
result, translating status or an actionable error; configuration errors open
**Keys & models** when clicked. Escape closes the palette and cancels its work.
Long input scrolls horizontally; long output wraps and scrolls in the second row.

You can also dictate into the input with Drop. The text is inserted at the
cursor (replacing a selection) without passing through the clipboard. If the
palette closes before the text arrives, Drop saves it in **History → Drop**
and shows a notice.

**Auto · RU ↔ EN** translates Cyrillic input to English and other input to
Russian. Click the translation to copy all of it: **Copied ✓** shows for a
second at the corner of the result. Dragging over it still selects a part to
copy with ⌘C, and a double click selects a word. With keyboard navigation
enabled, Tab can focus the result and Return copies it. Right-click the palette for
**Translate to**, **Copy translation**,
**Clear** or **Cancel translation**. The floating palette also offers **Subtitles**;
in Toolbox select its separate tile. Explicit language choices
are retained, including existing saved choices. Only language choices are saved, never submitted text or
subtitle content; the clipboard is accessed only by a click on the
translation or an explicit Copy action.

Editing the input or changing the target cancels the old request and clears
its result. Late responses cannot replace a newer translation. Inputs are
limited to 12,000 characters per request. A request has a 30-second resource
budget; failures retain the input for another attempt.

## Subtitles

Choose the spoken language (or Auto-detect), a target, then **Start subtitles**.
Play a video or join a call. A compact dark box floats at the bottom of the
screen over other apps and full-screen content. Each phrase is a pair: the
original on the left and its translation on the right, newest at the bottom.
While it listens the box keeps one size, also before any audio or words
arrive; **Stop** turns it into the stopped box at once. It blurs the video
under it. In a narrower window it narrows with it. Text already shown stays where it
is: the sentence still being heard is the last row, its original appearing
as far as its translation has reached and the translation so far dimmed, and turns white in place when it is finished, keeping every word
it showed; older lines move up and leave at the top one line at a time. A very
long original without a pause shows its newest lines beside the translation.
Hover the box to
reach the languages, **Stop** and **×**; they cover the top of the caption
without moving it and stay a second after the pointer leaves.
In the Toolbox pane the original sits above its translation. **Copy
translation** in the box's context menu copies the completed translations.

Only system audio is captured. The microphone is not opened, no recording is
saved, and no meeting note is created. Starting may request macOS **System
Audio Recording** permission. If the Mac is playing audio but no signal arrives,
check that permission in **System Settings → Privacy & Security**. Silence and
a denied grant cannot be reliably distinguished by the capture API.

There is no separate speech model or LLM request: one Soniox (or OpenAI) session receives the system audio and
returns the translation together with the transcript of what it heard. Each
translated sentence becomes a pair with the sentence of the original it
translates, also when the model translates two short sentences as one; the sentence still being heard shows its original and the
translation so far, dimmed. A refused key, an empty provider balance, a busy
service, a target language the provider does not offer or a
lost connection stops subtitles with a message saying which; finished pairs
stay. It uses only the key saved in Whytap, not the standalone app's files.

**Stop** shows the stopped box at once, with **Start** in place of Stop. In
the background it drains queued audio, waits up to ten seconds for speech
finals and completes queued translations; the last row settles where it is.
**Start** during that time drops the unfinished tail. Audio already captured at Stop is sent
before the speech provider receives its end-of-input signal. **Cancel**, closing the window or
Mac sleep cancels immediately. Switching to Text leaves subtitles running;
the Subtitles tool or the palette’s context menu reopens them. Updates defer app-initiated
restart while this window is open or a translation session is active, preserving
unsent text as well. Close the window before choosing Restart.

At most nine phrases wait for translation and forty recent pairs remain in
memory. Audio also crosses a bounded queue. If the connection or model cannot
keep up, capture stops with an actionable error instead of accumulating delay
or silently dropping speech. Start again when the connection is stable.
Starting a new subtitle session clears the previous lines.

## Verification

Automated checks use fake speech, fake system audio and fake translation; they
never use personal audio, clipboard content, keys or paid requests. Offscreen
renders cover normal and narrow windows, empty/result/setup states. Live
permission prompting, full-screen focus, actual translation quality and latency
must be checked in the shared installed app after integration.
