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

## Moving from Exodia or an older Whytap

Whytap is the restored product name. Quit the running app normally before
replacing it. Keep one installed working copy: move the previous **Exodia.app**
out of Applications as a rollback copy, then install **Whytap.app**. Do not run
both copies together or delete Application Support data or Keychain items.

The production bundle ID, Keychain services, storage paths, community signing
certificate and Sparkle public key are unchanged. This rename does not require
new privacy permissions. Existing Exodia GitHub links redirect to Whytap.
Older Whytap builds using the retired update host still need one manual install;
changing this GitHub repository does not migrate those feeds.

## First dictation

Whytap opens the island without a setup wizard. On the first launch on a Mac,
**Settings → Permissions** also opens if access is missing. It appears once;
you can return from the island's Settings control:

1. In **Permissions**, allow Microphone and Accessibility. macOS may open
   **System Settings → Privacy & Security** to grant them. Reopen Whytap if
   macOS asks you to quit after changing a permission.
2. In **API & Models**, click **Add key**, choose a speech provider and enter its
   API key. Whytap checks it and stores it in macOS Keychain; then pick a model
   for Drop Fast and Drop Smart.
3. Optionally add OpenRouter, OpenAI, Anthropic or your own endpoint and pick
   models for Smart cleanup and meeting summaries.
4. Focus a text field, hold **Space**, speak, then release Space.

Whytap is free. Your selected provider handles API billing; there are no Whytap
accounts, plans or credits. On-device speech and text models were removed; if
you used **Local** before, choose a speech model in **API & Models** to dictate
again.

For the optional agent, add an OpenRouter, OpenAI or Anthropic key, choose the
Agent model in **API & Models**, then click **Connect** in **Settings → Agents**
([Whytap Agent](agent.md)). Meeting recording may also request **System Audio
Recording** permission.

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
- **An unexpected copy opens:** Settings shows the actual version, channel and
  application path. New builds allow one running copy across production and
  beta; a second copy offers to activate the existing app. Quit the running
  copy before switching. Older binaries do not implement this coordination.
- **The API key does not connect:** check the provider, key, endpoint/model and
  internet connection. Never include the key in a bug report.
- **The source build fails:** run `python3 scripts/customize.py doctor --json`
  from the checkout and include the build error and toolchain version in a
  [bug report](https://github.com/AbsoluteMode/whytap/issues/new/choose).

To remove Whytap, quit it and move the app to Trash. Keys, settings and local
knowledge remain outside the bundle so reinstalling preserves them.
