# Install Whytap

## Download and open

1. [Download Whytap-latest.dmg](https://github.com/AbsoluteMode/whytap/releases/latest/download/Whytap-latest.dmg).
2. Open the DMG and drag **Whytap** onto the **Applications** folder beside it.
3. Open **Applications**, then double-click **Whytap**. If macOS asks whether
   to open an app downloaded from the internet, choose **Open**.
4. Eject the Whytap disk image in Finder. Keep using the copy in Applications.

The same download supports Apple Silicon and Intel on macOS 14.2 or newer.
The app is signed with Developer ID and notarized by Apple. No developer
tools, terminal commands or administrator script are required.

## First dictation

The app walks you through the setup:

1. Allow **Microphone** so Whytap can hear your speech.
2. Enable **Whytap** under **System Settings → Privacy & Security →
   Accessibility** so its shortcut and text insertion can work. Reopen Whytap
   if macOS asks you to quit it after changing this permission.
3. Choose **Your key**, select your speech provider and paste its API key.
   **Save & continue** checks the connection and saves the key in macOS Keychain.
4. Optionally add an OpenRouter key or your own endpoint for text cleanup and
   meeting summaries. You can skip this step and try dictation immediately.
5. Click the practice text field, hold **Space**, speak, then release Space.

Whytap is free. When you use a provider key, that provider's account and billing
apply. Whytap does not sell credits or require a Whytap account.

For on-device processing, choose **Local** and download the speech model.
Local models require Apple Silicon and internet access for the initial
download. Local text cleanup uses a separate model. Intel Macs use provider
keys or compatible endpoints.

Claude Code and Codex are optional: connect one only if you want the agent.
Meeting recording may also request **System Audio Recording** permission.

## If something does not work

- **“Install Whytap before opening it”:** you launched the temporary copy on
  the disk image. Drag it to Applications and open the installed copy.
- **Whytap is already installed:** quit the running app, drag the new copy
  into Applications and choose **Replace** in Finder. Your keys and history
  are stored outside the app bundle. In-app updates are also available.
- **macOS says the app is damaged or cannot verify its developer:** download
  a fresh DMG from the link above. Do not disable Gatekeeper or remove
  quarantine attributes. If the new download is still rejected, include the
  exact message and macOS version in a [bug report](https://github.com/AbsoluteMode/whytap/issues/new/choose).
- **The shortcut does not work or text is not pasted:** check Microphone and
  Accessibility for the installed Whytap copy, then quit and reopen it.
- **The API key does not connect:** check the selected provider, its key and
  your internet connection. Save again. For a self-hosted endpoint, also
  check its base URL and model name. Never include your key in a bug report.
- **You skipped model setup:** open **Settings → Models** from the island.
  There is no menu-bar icon; Whytap's controls live in the island at the top
  of the screen.

## Updates and removal

When the island offers an update, choose **Download**. Whytap installs it and
relaunches. You can also install a newer DMG over the existing app.

To remove the app, quit Whytap and move it from Applications to Trash. This
keeps keys, settings and local history so reinstalling does not erase them.

Apple explains the standard [Developer ID and notarization checks](https://support.apple.com/102445).
