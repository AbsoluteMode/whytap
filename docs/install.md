# Install Whytap

The normal installation uses a ready-made macOS build. You do not need Xcode,
a terminal or an Apple Developer account to use it.

Download [`Whytap-latest.dmg`](https://github.com/AbsoluteMode/whytap/releases/latest/download/Whytap-latest.dmg)
from [GitHub Releases](https://github.com/AbsoluteMode/whytap/releases). Whytap
needs macOS 14.2 (Sonoma) or newer and runs on Apple Silicon and Intel.
Releases before 2.2.17 were published as **Exodia**; it is the same application.

## Download and open

1. Download the Whytap DMG from the repository's Releases page.
2. Open it and drag **Whytap** into **Applications**.
3. Open Whytap from Applications, then eject the disk image.

Community builds are signed with the Developer ID certificate of Whytap's Apple
team and notarized by Apple; the app and the disk image carry a stapled
notarization ticket, so the check also works offline. On the first launch macOS
asks once whether to open an app downloaded from the internet; choose **Open**.
Releases up to 2.2.15 were not notarized: if macOS says it cannot verify the
developer of such a download, follow **System Settings → Privacy & Security →
Open Anyway** for that download;
[Apple explains this per-app approval](https://support.apple.com/102445).

Notarization does not grant Microphone, Accessibility or Keychain access. The
first upgrade from an older community-signed build may ask for those again.
Approve Keychain access in the macOS window only (Always Allow if you trust
this Whytap build); never enter the login password into an agent or chat.
Later updates signed by the same team retain the same identity.
You never install or trust a certificate yourself. Current builds carry the
same team identity, so macOS keeps privacy permissions such as
Microphone and System Audio Recording and access to Whytap's Keychain items
across updates. Earlier builds were signed with Whytap's self-signed
certificate or ad hoc, so the first team-signed update asks for these
permissions one last time and asks once for each Keychain item; choose
**Always Allow** there. Sparkle update signatures verify Whytap's archives separately from Apple's
launch checks.

Requirements: macOS 14.2 or newer, on Apple Silicon or Intel.

## Verify your download

Optional: check that the download is Whytap's notarized build and see which
source commit it came from. Whytap's Apple Team ID is **`UVBKCN5PPV`**. Open
Terminal and go to the folder with the download first, for example
`cd Downloads`.

1. Gatekeeper's verdict on the disk image, before opening it:

   ```bash
   spctl -a -vv -t open --context context:primary-signature Whytap-latest.dmg
   ```

   Expect `accepted`, `source=Notarized Developer ID` and an `origin` line
   ending in `(UVBKCN5PPV)`.
2. The installed app's identity and verdict:

   ```bash
   codesign -dv --verbose=2 /Applications/Whytap.app 2>&1 | grep -E '^(Identifier|TeamIdentifier)='
   spctl -a -vv /Applications/Whytap.app
   ```

   Expect `Identifier=com.rootwise.sidekey`, `TeamIdentifier=UVBKCN5PPV`,
   `accepted` and `source=Notarized Developer ID`.
3. The source it was built from: newer releases also attach
   `Whytap-latest.dmg.manifest.json`, written when the DMG was built. Compare
   its `archive_sha256` with

   ```bash
   shasum -a 256 Whytap-latest.dmg
   ```

   `source_revision` is the commit the release was built from
   (`https://github.com/AbsoluteMode/whytap/commit/<source_revision>`), and
   `code_signing` and `notarization` should read `team:UVBKCN5PPV` and
   `notarized`. The manifest's `archive` field keeps the versioned build name
   (for example `Whytap-2.2.26-build1500.dmg`); it is the same file as
   `Whytap-latest.dmg`. Releases published before the manifest was attached
   have only the DMG and `appcast.xml`.

Sparkle checks each in-app update separately with Whytap's Ed25519 key before
installing it. A build you made yourself from source is ad-hoc or locally
signed and does not pass these checks; that is expected.

## Install with Homebrew

If you use [Homebrew](https://brew.sh), one command installs the same signed and
notarized DMG from GitHub Releases:

```bash
brew install absolutemode/tap/whytap
```

The cask lives in the public tap
[AbsoluteMode/homebrew-tap](https://github.com/AbsoluteMode/homebrew-tap). It pins
the release tag and the SHA-256 of that release's `Whytap-latest.dmg`. Whytap
requires macOS 14.2 or newer. The cask is refreshed by the release process after each
release, so it can trail the newest release by a short time (`brew upgrade --cask
whytap` catches up). Whytap updates itself through Sparkle, so you do not need
`brew upgrade` to stay current; the cask is marked `auto_updates`. Quit a running
Whytap before `brew install` or `brew upgrade` replaces the app.

`brew uninstall --cask whytap` removes the app only, like moving it to Trash
(see [removal](#troubleshooting-and-removal)). `brew uninstall --cask --zap whytap`
also deletes Whytap's data in your user Library folder, including meeting notes, history
and the Case vault. Make a backup first (**Settings → Backup**). Keychain items are
never touched.

## Moving from Exodia or an older Whytap

Whytap is the restored product name. Quit the running app normally before
replacing it. Keep one installed working copy: move the previous **Exodia.app**
out of Applications as a rollback copy, then install **Whytap.app**. Do not run
both copies together or delete Application Support data or Keychain items.

The production bundle ID, Keychain services, storage paths and Sparkle public
key are unchanged; the signing identity changed once, to the Developer ID team
described under [Download and open](#download-and-open). This rename does not require
new privacy permissions. Existing Exodia GitHub links redirect to Whytap.
Older Whytap builds using the retired update host still need one manual install;
changing this GitHub repository does not migrate those feeds.

## First launch

The first launch on a Mac shows the island and opens a short setup window.
Every page can be skipped, a page that is already done is hidden, and closing
the window finishes it. It does not come back after updates.

1. **Speech:** choose how Drop recognizes speech. On Apple Silicon,
   **Download and use for Drop** fetches the *On this Mac* model (about 470
   MB) and needs no account or key. It recognizes 25 European languages
   (Bulgarian, Croatian, Czech, Danish, Dutch, English, Estonian, Finnish,
   French, German, Greek, Hungarian, Italian, Latvian, Lithuanian, Maltese,
   Polish, Portuguese, Romanian, Slovak, Slovenian, Spanish, Swedish, Russian
   and Ukrainian); Chinese, Japanese, Arabic, Hindi and other languages need a
   provider. Or paste a speech provider's key (Soniox,
   Deepgram, ElevenLabs); Whytap checks it, stores it in macOS Keychain and uses
   that provider for Drop. On Intel there is no On this Mac model, so Drop needs
   a provider key or your own server. **Restore from another Mac** applies a
   Whytap backup instead.
2. **Permissions:** allow Microphone and Keyboard control (Accessibility).
   macOS may open **System Settings → Privacy & Security**; reopen Whytap if
   macOS asks you to quit after changing a permission.
3. **Try Drop:** focus the field on the page, hold **Space**, speak, release.
4. **Optional features:** turn on Google search, Meeting Notes or the Agent;
   a feature whose model is not set offers **Add a model**.

The next version (after 2.2.26) redesigns this window into five pages with
Back on every page after the first: the
speech page also lists language-model and Tavily keys with each provider's
free offer and a searchable "I speak" language, Screen Recording (for Shot)
becomes an optional row on the permissions page, a page introduces tool
shortcuts and hover tools, and the last page can connect Claude Code and Codex.

Later you can change everything in **Settings → API & Models** (keys, the On
this Mac model, a model per feature) and **Settings → Permissions**. A feature
without a model opens API & Models on its row when you use it; Whytap never
picks another provider for you. If you used **Local** before October 2026,
choose a speech model again: the old local models were removed.

For the optional Agent, add an OpenRouter, OpenAI or Anthropic key, choose the
Agent model in **API & Models**, then turn on **Agent** in **Settings → Other**.
Read [Whytap Agent](agent.md) first: once on, it can edit files and run
commands. Meeting recording also asks for **System Audio Recording**.

## What it costs

Whytap is free (MIT) and has no plans, accounts or credits of its own. It is
built for people and teams who already have one of these:

- **Provider keys**, billed by the provider per use: Soniox, Deepgram or
  ElevenLabs for speech; OpenRouter, OpenAI or Anthropic for language models.
  They also run the Agent's web search: about $10 per 1,000 searches plus
  result tokens on Anthropic and OpenAI, Exa at about $7 per 1,000 through
  OpenRouter (Claude models there use Anthropic's search). Tavily is for an
  Agent model without search, or when chosen in Models → Search.
- **A ChatGPT or Claude plan with monthly API credits.** OpenAI gives ChatGPT
  Pro ($100, $200 or $500 a month, by tier) and Business seats API credit;
  Anthropic gives Claude Max ($100), Ultra ($200) and Team seats. Both must be
  linked to an API organization you own, start after seven days on the plan
  and expire at the end of each billing cycle. Check
  [OpenAI's terms](https://developers.openai.com/api/docs/guides/chatgpt-api-credits)
  and [Anthropic's terms](https://support.claude.com/en/articles/17154008-monthly-api-credits-for-max-ultra-and-team-plans);
  they were last checked on 2026-11-22.
- **Your own servers** speaking the OpenAI-compatible API (Ollama, LM Studio,
  vLLM for text; a server with the OpenAI Realtime protocol or
  `/v1/audio/transcriptions` for speech).
- **An Apple Silicon Mac** for dictation on the Mac itself.

| Feature | Without any key (Apple Silicon) | Needs |
| --- | --- | --- |
| Drop Fast | On this Mac | a speech provider or server on Intel |
| Drop Smart | speech only | a language model for the cleanup |
| Agent (text) | no | a language model (OpenRouter, OpenAI or Anthropic), which also searches the web; Tavily for search with a model that cannot |
| Agent voice, Voice search | On this Mac | a speech provider or server on Intel |
| Meeting Notes | no: a meeting waits until both rows are set | a language model for the notes, plus speech (On this Mac gives no speaker labels; Soniox, Deepgram or ElevenLabs label speakers) |
| Translate | no | a language model |
| Subtitles | no | an OpenAI key, about $3 per hour of audio (from the version after 2.2.26; 2.2.26 uses a speech model plus a language model) |
| Shot (OCR, blur), History, To-do, Case, Notify, Display | yes | nothing |

The free tiers listed under API & Models → API hints and in the README are
good for trying Whytap; heavier use is billed by your provider. Settings → API
& Models → Costs shows what each feature has cost so far.

## Updates

When the island offers **Update**, choose **Download**. Sparkle verifies the
archive using Whytap's Ed25519 public key. When the app is idle, the requested
update installs and relaunches when ready. If a meeting recording, dictation or
agent task is active, the app keeps the update ready without interrupting it.
Finish the activity, then choose **Restart** to apply the update. A prepared
download can also apply when you quit Whytap normally. Choose **Later** to cancel
the current installation; it will not then apply on that quit. Returning to idle
does not force a restart. Installation after force quit or a crash is not guaranteed.

You can also install a newer Whytap DMG over the copy in Applications. Keys,
settings and local knowledge are stored outside the app bundle, and macOS
permissions carry over because community builds share one Developer ID team identity.

## Customize from source

Use Xcode 26 or newer with its command-line tools:

```bash
git clone https://github.com/AbsoluteMode/whytap.git
cd whytap
./scripts/dev-run.sh --run
```

This creates `build/Whytap-Beta-dev.app`, using an existing local `Sidekey Dev`
signing identity or ad-hoc signing. Version `0.0.0-dev` / build `9999` keeps the
binary feed from overwriting your custom build. Have your agent update the source
while preserving local changes, then validate and rebuild. See
[customization](customization/README.md) and [build details](build-and-release.md).

## Troubleshooting and removal

- **“Install Whytap before opening it”:** drag the app to Applications and open
  that copy instead of the disk-image copy. For source builds, use the writable
  checkout and `scripts/dev-run.sh`.
- **The shortcut or paste does not work:** open **Whytap Settings → Permissions**,
  check the Drop shortcut status and click **Retry Shortcut** after granting
  the missing permission. Refresh and reopening Whytap also recheck the monitors.
- **An unexpected copy opens:** Settings shows the version; a second copy's
  alert names the running copy's version and path. New builds allow one running copy across production and
  beta; a second copy offers to activate the existing app. Quit the running
  copy before switching. Older binaries do not implement this coordination.
- **The API key does not connect:** check the provider, key, endpoint/model and
  internet connection. Never include the key in a bug report.
- **The source build fails:** run `python3 scripts/customize.py doctor --json`
  from the checkout and include the build error and toolchain version in a
  [bug report](https://github.com/AbsoluteMode/whytap/issues/new/choose).

To remove Whytap, quit it and move the app to Trash. Keys, settings and local
knowledge remain outside the bundle so reinstalling preserves them.
