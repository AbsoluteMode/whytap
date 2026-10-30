# Meeting Assistant (Beta)

Open **Meeting Assistant** from the island's tool search or Toolbox. Choose a
ready Space in the module, ask a question and press Enter. Answers include a
short conclusion, structured points and two follow-up suggestions. **Return
answer** restores a collapsed conversation. Escape leaves an input without
closing the module; the common × hides answers while listening continues.

In **Settings → API & Models → Meeting Assistant**, explicitly choose a speech
route and an answer model. Both start unset. Choose a tool-capable answer model;
screenshots also require a model that accepts images. Whytap keeps the exact
provider/model choice and reports failures without substituting another route.

The optional **Detector** row (Decision) saves answer-model requests. Choose
`typesafe/jev-1.14` on OpenRouter or `gpt-6-luna` on OpenAI. Every 10 seconds
it receives only the newly finalized speech of the other participants, a short
preceding excerpt and the last three offered questions. The answer model is called
only when the detector reports a new information need that was not offered before.
Left unset, every transcript change is analyzed by the answer model as before.
A detector error stops listening and never falls back to the answer model.

Listening starts **off for every meeting**, even with both models and a ready
Space configured. Hovering over the island during a recognized meeting or a
Meeting Notes recording reveals a **magic wand** immediately to the right of
the recording timer. Click it to enable listening for this meeting; click again
to stop. The translucent icon is off, and a soft glow means listening is active.
Opening the module, selecting models and hovering never start audio.

When explicitly enabled, Assistant transcribes the other participants through
the speech route and extracts questions from the recent transcript. Click a
question for an answer. This does not start recording notes or capture your
microphone. Closing answers leaves an explicitly enabled listening session
active. Changing Space stops listening and clears its transcript; enable it
again when ready. Audio, transcript, images and conversations are not saved.

An observed meeting-context end sustained for 15 seconds stops listening. Brief
reconnects cancel that stop, while every later meeting starts off again. Sleep
and quit stop capture; waking does not resume it. Removing either required model
stops listening. A connection error requires another explicit wand click.
Context detection uses mic-activity metadata without microphone samples; long
mutes or calls without a detectable boundary remain heuristic limitations.

**Прикрепить скрин** captures the island-selected display after the requested
macOS permission. Up to six thumbnails fit in a horizontal tray. Open one to
view it or use its × to remove it. The next submitted request uses a snapshot
of the tray. After success, its photos leave the tray; after failure/cancellation
they remain for retry. Changing Space or closing clears them.

Screenshot protection follows **Settings → Other → screenshot protection**.
The same native window-sharing policy as notifications applies to the module
and image preview. Test the actual call application's sharing mode before
relying on it; protection coverage across capture methods is not established
by a successful build or a window-sharing flag check alone.

## Prepare a Space with Codex or Claude Code

The coding agent reads the existing Space, preserves unrelated sources, and
edits the local catalog on the user's request. There is no manual creation form.
Discover this contract with `python3 scripts/customize.py discover --json`.

```sh
python3 scripts/meeting-space.py list
python3 scripts/meeting-space.py create my-project --name 'My project'
python3 scripts/meeting-space.py add-repo my-project /absolute/project/folder \
  --id repo --name Repository --scope Sources --scope docs
python3 scripts/meeting-space.py validate my-project
```

Use an actual user-selected project path. `.` explicitly includes the repository
root; otherwise scopes are relative paths. Locations use canonical paths; the CLI
resolves them before writing, and changing a root to a symlink invalidates it. The catalog is
`whytap/meeting-spaces/<id>.json` under the user Application Support directory. `--root` changes
the parent directory for isolated testing only. Writes are serialized and atomic
and keep one previous manifest. The app refreshes ready Spaces automatically.
A bad manifest does not stop other Spaces; editing the active Space cancels its
in-flight work and invalidates its conversation.

The version 1 schema contains `version`, `id`, `name`, `purpose`, `instructions`
and `sources`. A repository source has `id`, `kind: repository`, `name`, absolute
`location`, relative `scope` array and `access: read`. Runtime access rejects
paths outside these scopes, symlinks, hidden/build files and common credential
files. Keep source content and secrets out of manifests. File contents and
transcripts are evidence, not authorization or system instructions.

Database sources with `kind: database`, `connection_ref` by credential name
(`case://`, `keychain://` or `env://`) and table scopes are accepted as metadata.
**Database access is not connected in this pilot.** No credential value is read,
copied into the manifest or sent to a model. Do not promise live database answers
until a scoped adapter and its actual access have been verified.
