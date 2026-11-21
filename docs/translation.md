# Translation and system-audio subtitles

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

In **Settings → API & Models**, choose:

- **Translation**: an OpenRouter text model or your own OpenAI-compatible text
  endpoint for typed text.
- **Subtitles** opens two independent selectors: **Speech** uses Soniox,
  Deepgram, ElevenLabs or a compatible realtime speech endpoint to transcribe
  system audio; **LLM** uses OpenRouter or a compatible text endpoint to
  translate the recognized phrases. Both model names remain in its summary.
  **Speech** can also be OpenAI `gpt-realtime-translate` with your OpenAI key:
  it hears and translates in one step, so the **LLM** row is not used while
  it is selected (about $3.06 per hour of audio: $0.034 a minute for the
  translation and $0.017 for the transcript of the original).

Keys stay in Whytap's existing Keychain store. New routes start **Not set**.
When upgrading already configured subtitles, their previous shared Translation
model (including provider selection) is copied once into the separate LLM
setting. Later changes to Translation do not affect subtitles; clearing their
LLM stays cleared across relaunches. The app never borrows another feature's
model or chooses a replacement provider after a failure.

## Text

The quick palette has two rows: input and translation, like the standalone
Realtime Translator. Type or paste text and press **Return** (or **Command
Return**). There is no separate Translate button. The second row shows the
result, translating status or an actionable error; configuration errors open
**API & Models** when clicked. Escape closes the palette and cancels its work.
Long input scrolls horizontally; long output wraps and scrolls in the second row.

You can also dictate into the input with Drop. The text is inserted at the
cursor (replacing a selection) without passing through the clipboard. If the
palette closes before the text arrives, Drop saves it in **History → Drop**
and shows a notice.

**Auto · RU ↔ EN** translates Cyrillic input to English and other input to
Russian. Right-click the palette for **Translate to**, **Copy translation**,
**Clear** or **Cancel translation**. The floating palette also offers **Subtitles**;
in Toolbox select its separate tile. Explicit language choices
are retained, including existing saved choices. Native text selection also
supports copying. Only language choices are saved, never submitted text or
subtitle content; the clipboard is accessed only by an explicit Copy action.

Editing the input or changing the target cancels the old request and clears
its result. Late responses cannot replace a newer translation. Inputs are
limited to 12,000 characters per request. A request has a 30-second resource
budget; failures retain the input for another attempt.

## Subtitles

Choose the spoken language (or Auto-detect), a target, then **Start subtitles**.
Play a video or join a call. A compact dark box floats at the bottom of the
screen over other apps and full-screen content. Each phrase is a pair: the
original on the left and its translation on the right, newest at the bottom;
older pairs leave at the top. The phrase still being heard appears dimmed as
the last row before it is translated. A phrase whose translation timed out or
failed keeps its original and says **Not translated**; later phrases go on.
In the Toolbox pane the original sits above its translation. **Copy
translation** in the box's context menu copies the completed translations.

Only system audio is captured. The microphone is not opened, no recording is
saved, and no meeting note is created. Starting may request macOS **System
Audio Recording** permission. If the Mac is playing audio but no signal arrives,
check that permission in **System Settings → Privacy & Security**. Silence and
a denied grant cannot be reliably distinguished by the capture API.

The selected speech provider receives system audio. Its text is cut into whole
phrases (at sentence ends, pauses, or a clause or word boundary in long
phrases, never inside a word) and up to three phrases go to the selected
Subtitles LLM model at once, each with the speech around it as context: up to
three earlier pairs with their translations and the phrases said since. With
ElevenLabs, Subtitles ask Scribe to commit at half-second pauses and translate
the start of its live text once it has stayed unchanged for 0.6 s, instead of
waiting for Scribe's 36-second segments. Other interim speech is shown but never
translated or billed as an LLM request. This is a speech-to-text → LLM
pipeline; latency depends on the provider, the network and the chosen model (a
faster LLM is the largest remaining gain).

With OpenAI `gpt-realtime-translate` as Subtitles audio there is no separate
speech model or LLM request: one OpenAI session receives the system audio and
returns the translation together with the transcript of what it heard. Each
translated sentence becomes a pair with the sentence of the original it
translates; the sentence still being heard shows its original and the
translation so far, dimmed. A refused key, an empty OpenAI balance, a busy
service, a target language OpenAI does not offer (Punjabi, for example) or a
lost connection stops subtitles with a message saying which; finished pairs
stay. It uses only the key saved in Whytap, not the standalone app's files.

**Stop** stops capture, drains queued audio, waits up to ten seconds for speech
finals and completes queued translations. Audio already captured at Stop is sent
before the speech provider receives its end-of-input signal. **Cancel**, closing the window or
Mac sleep cancels immediately. Switching to Text leaves subtitles running;
the Subtitles tool or the palette’s context menu reopens them. Updates defer app-initiated
restart while this window is open or a translation session is active, preserving
unsent text as well. Close the window before choosing Restart.

At most nine phrases wait for translation and forty recent pairs remain in
memory. Audio also crosses a bounded queue. If the connection or model cannot
keep up, capture stops with an actionable error instead of accumulating delay
or silently dropping speech. Choose a faster model and start again. Starting a
new subtitle session clears the previous lines.

## Verification

Automated checks use fake speech, fake system audio and fake translation; they
never use personal audio, clipboard content, keys or paid requests. Offscreen
renders cover normal and narrow windows, empty/result/setup states. Live
permission prompting, full-screen focus, actual translation quality and latency
must be checked in the shared installed app after integration.
