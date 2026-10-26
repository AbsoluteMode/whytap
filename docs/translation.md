# Translation and system-audio subtitles

Open **Translate** or **Subtitles** from the island's tool search. Add either
button in **Settings → Toolbox** if you want it pinned. Each tool can have its
own shortcut in **Settings → Hotkeys**; no existing shortcut or layout changes.
In Toolbox, select either tile to use it directly in the right pane. The floating
window and Toolbox share translation content and language preferences. Leaving
the mini app or closing Settings cancels its work unless the floating translator
is also visible. Selecting the tile alone never starts capture or a request.

From the island, both tools open the same floating, resizable window, including over full-screen
apps. Escape closes it and cancels translation/capture. The borderless text
palette has no title bar or input hint. Click outside it to close and cancel
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
Play a video or join a call. The window floats over other apps and full-screen
content; you can move or resize it. **Original** shows source phrases above the
translation. **Follow** follows the latest line; turn it off to read older lines.
Copy copies the completed translations retained in this window.

Only system audio is captured. The microphone is not opened, no recording is
saved, and no meeting note is created. Starting may request macOS **System
Audio Recording** permission. If the Mac is playing audio but no signal arrives,
check that permission in **System Settings → Privacy & Security**. Silence and
a denied grant cannot be reliably distinguished by the capture API.

The selected speech provider receives system audio. Its committed phrases go
to the selected Subtitles LLM model. Interim speech is shown but never translated
or billed as an LLM request. This is a speech-to-text → LLM pipeline; latency
depends on phrase finalization, the network and the chosen model. It does not
use the standalone app's OpenAI translation endpoint or its credential files.

**Stop** stops capture, drains queued audio, waits up to ten seconds for speech
finals and completes queued translations. Audio already captured at Stop is sent
before the speech provider receives its end-of-input signal. **Cancel**, closing the window or
Mac sleep cancels immediately. Switching to Text leaves subtitles running;
the Subtitles tool or the palette’s context menu reopens them. Updates defer app-initiated
restart while this window is open or a translation session is active, preserving
unsent text as well. Close the window before choosing Restart.

At most eight phrases wait for translation and forty recent lines remain in
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
