# Troubleshooting

**Ask first: [whytap.ai](https://whytap.ai).** Its Ask answers from Whytap's
code and knows the common problems below. If Whytap cannot do something yet,
it drafts the GitHub issue for you.

The most frequent problems, each with where to fix it:

- **Holding Space does nothing, or the text is not pasted:** allow Accessibility
  and Microphone in **Settings → Permissions**, then click **Retry Shortcut**
  ([first launch](install.md#first-launch),
  [shortcut help](install.md#troubleshooting-and-removal)).
- **Dictation opens Settings instead of recording:** that feature has no speech
  model yet; pick one in **Settings → API & Models**, or download **On this
  Mac** ([first launch](install.md#first-launch)).
- **“<Provider> refused the key” or “out of credit”:** the provider rejected
  the key or the account is empty; fix it with the provider, then save the key
  again in **API & Models → API keys**
  ([key help](install.md#troubleshooting-and-removal)).
- **“Install Whytap before opening it”:** drag Whytap to **Applications** and
  open that copy, not the one on the disk image
  ([install](install.md#troubleshooting-and-removal)).
- **macOS asks for permissions or Keychain access again after an update:**
  expected once when moving from an older self-signed build to the team-signed
  one; choose **Always Allow** ([why](install.md#download-and-open)).
- **Meeting notes contain only your own voice:** allow **System Audio
  Recording** when macOS asks, or in **System Settings → Privacy & Security**
  ([first launch](install.md#first-launch)).
- **A different copy of Whytap opens:** only one copy runs at a time; a second
  copy's alert names the running copy's version and path, and Settings shows
  the version
  ([which copy](install.md#troubleshooting-and-removal)).

Still stuck? Open a [bug report](https://github.com/AbsoluteMode/whytap/issues/new/choose)
with your macOS and Whytap versions. Never include API keys or transcripts.
