---

**Verify your download.** `{{MANIFEST}}` records the source commit this
`{{ARCHIVE}}` was built from, its SHA-256 and size, the signing identity
(`{{CODE_SIGNING}}`) and notarization (`{{NOTARIZATION}}`). Compare
`shasum -a 256 {{ARCHIVE}}` with its `archive_sha256`, then check Apple's
signature as described in
[Verify your download](https://github.com/AbsoluteMode/whytap/blob/main/docs/install.md#verify-your-download).
