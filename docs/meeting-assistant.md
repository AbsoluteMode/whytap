# Meeting Assistant

Open **Meeting Assistant** from the island's tool search or Toolbox. Choose a
ready Space in the module, ask a question and press Enter. Answers include a
short conclusion, structured points and two follow-up suggestions. **Return
answer** restores a collapsed conversation. Escape leaves an input without
closing the module; the common × hides answers while listening continues.

In **Settings → API & Models → Meeting Assistant**, explicitly choose a speech
route and an answer model. Both start unset. Choose a tool-capable answer model;
screenshots also require a model that accepts images. Whytap keeps the exact
provider/model choice and reports failures without substituting another route.

Once both models and a ready Space are configured, Assistant automatically
listens to each recognized meeting, transcribing the other participants through
the speech route. No separate Listen button or required hotkey is involved.
The module shows connection/listening status. Questions extracted from the recent
transcript appear above older questions; click one for an answer. This does not
start recording notes or capture your microphone. Closing the module leaves
listening active. Changing Space clears its transcript and reconnects during an
active meeting. Audio, transcript, images and conversations are not saved.

Once both model routes and a ready Space are selected, hovering over the island
while a meeting is recognized or Meeting Notes records reveals a **magic wand** immediately to the right of
the recording timer. It is translucent when off and has a soft white/blue glow
while listening. Click it to stop or resume Assistant for this meeting. Connecting
has a visible outline and can be cancelled; cleanup is temporarily disabled.
The control remains available after stopping Assistant during a recognized call
without Notes. It keeps answers when stopped. Newly created Spaces refresh
automatically while models are configured. The ordinary
tool/search/deep link still only opens the module; hover alone never starts audio.

The wand's off choice applies only to the current meeting. When the existing
metadata-only probe has recognized meeting mic activity and that context ends
for 15 seconds, listening stops. A brief reconnect cancels the pending stop;
a later meeting automatically starts listening again. No microphone samples are
captured by the probe. Sleep and quit stop capture; wake rechecks the current
meeting. Removing either required model disables automatic listening. A connection
error pauses capture until an explicit wand retry or the next meeting. Muting a
call for long enough can look like an end, while calls without a detectable
boundary cannot be distinguished: this is a context heuristic, not a calendar/call ID.

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
