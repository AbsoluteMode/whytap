# Retire the live meeting assistant

On 2026-11-05 the user requested complete removal of the live assistant from
Whytap, allowing deletion rather than keeping commented implementation.

Remove its panel, wand, meeting observer, audio/question pipeline, Space reader
and authoring script, screenshot attachments, Toolbox/search/link destinations,
model settings and documentation. Remove the independent diagnostic live stream,
mixer and experimental source attribution as well. Ordinary Meeting Notes,
recording, transcription, microphone gain and stored notes remain available.

Keep only compatibility needed for existing data:

- Two inactive AI feature IDs decode historical Costs and backup rows. They
  have retired labels, cannot select a model and cannot resolve a runtime route.
- Launch retires their saved routes, including routes restored from old backups,
  while keeping other routes, provider keys and unknown settings. An unreadable
  or partially decoded routing document is not rewritten during launch.
- Old saved tool IDs and hotkeys follow the existing unknown-tool handling.
  Old show-only links wake the island; old hotkey links only show Hotkeys
  and cannot assign anything.
- A small cleanup retains deletion of the retired diagnostic-audio directory,
  now in all builds. There is no research capture flag or extra audio stream.

Existing user-authored Space manifests and project files are left on disk as
inert files. No project catalog, meeting database, notes or provider keys are
deleted. Previous implementation and decisions remain recoverable in Git.

Validation uses temporary stores, generated audio bytes and fake model clients;
it performs no real recording, screenshot capture or paid model request.
