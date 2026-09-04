# Implementation spec: pivot NowPlaying source to MediaRemote adapter

Replaces the AppleScript now-playing source (dead on macOS 15.4+/Tahoe, system-wedged on the target machine) with the community **MediaRemote adapter** (bundled `perl` + unlinked `MediaRemoteAdapter.framework` that dlopens the private MediaRemote framework and streams now-playing as JSON, **no permission prompt**). The existing `NowPlayingSource` protocol + `NowPlayingSnapshot` model + all UI (wing/strip/transport, Stages 2-4) stay — only the SOURCE changes.

Worktree: `/Users/grigoriygolovlev/work/sidekey-nowplaying-sync`. NO commits/push. Build/tests FOREGROUND only.

## Legal (do this first)
Vendor all runtime artifacts from **`ungive/mediaremote-adapter` (BSD-3-Clause)**, NOT `ejbills` (that fork ships no LICENSE). Verify `ungive`'s actual interface from its source (the design below was verified against `ejbills`; `ungive` is the upstream and reported identical — confirm the `loop` subcommand, the stdin transport verbs, and the JSON field names from `ungive`'s `run.pl`/sources before coding, and adapt any differences). Record the exact pinned commit SHA and add `Resources/MediaRemoteAdapter/THIRD_PARTY_NOTICE.md` with the BSD-3 text + copyright + source URL + SHA.

## 1. Vendor (from ungive@<pinned-SHA>)
- `Resources/MediaRemoteAdapter/run.pl` — the perl script (carries BSD-3 header).
- `Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/` — built UNIVERSAL from ungive source and checked in:
  ```bash
  git clone https://github.com/ungive/mediaremote-adapter /tmp/mra && cd /tmp/mra
  git checkout <PINNED_SHA>
  swift build -c release --arch arm64 --arch x86_64
  ditto .build/apple/Products/Release/MediaRemoteAdapter.framework \
        <wt>/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework
  lipo -info <wt>/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter
  # must show: x86_64 arm64
  ```
  (If ungive's product/target name differs, adjust; the deliverable is a universal `MediaRemoteAdapter.framework` whose `Versions/A/MediaRemoteAdapter` Mach-O perl will dlopen.)
- `Sources/Sidekey/NowPlaying/MediaRemoteTrackInfo.swift` — the `TrackInfo` Codable model adapted to internal (drop `public`). Fields (microseconds): `title, artist, album, isPlaying, durationMicros, elapsedTimeMicros, timestampEpochMicros, playbackRate, applicationName, bundleIdentifier, PID, artworkDataBase64, artworkMimeType, shuffleMode, repeatMode`. Tolerate `isPlaying` as bool OR 0/1 int. Decode `artworkDataBase64`→`NSImage` in `init(from:)`. Expose a computed `currentElapsedSeconds` interpolating `elapsedTimeMicros + (now - timestampEpochMicros)*playbackRate` while playing.

`Package.swift` stays UNCHANGED — no SPM dependency, no resource bundle. The new Swift files compile into the existing `Sidekey` target; the framework+pl are bundled by the build scripts (below) and resolved at runtime via `Bundle.main`.

## 2. Bundle layout + build-script changes
Bundle:
```
*.app/Contents/Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter   (dlopen target, SIGNED)
*.app/Contents/Resources/MediaRemoteAdapter/run.pl                                      (script, sealed by app sign)
```
Runtime resolution:
- pl:  `Bundle.main.url(forResource:"run", withExtension:"pl", subdirectory:"MediaRemoteAdapter")`
- dylib (argv): `Bundle.main.bundleURL/Contents/Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter`

**`scripts/build-dmg.sh`** — after the BlockNote copy block, before "Embed Sparkle.framework": hard-fail if `Resources/MediaRemoteAdapter/{run.pl,MediaRemoteAdapter.framework}` missing; `mkdir Contents/Resources/MediaRemoteAdapter` + copy `run.pl` (chmod 0644); `mkdir Contents/Frameworks` + `ditto` the framework; assert `lipo -info` shows BOTH `x86_64` and `arm64` (mirror the Sparkle universal check). Then in the Sparkle codesign block, BEFORE the app-bundle sign, add:
```bash
codesign --force --sign "${SIGNING_IDENTITY}" --options runtime --timestamp \
    "${APP_BUNDLE}/Contents/Frameworks/MediaRemoteAdapter.framework"
```
No `--deep`, no rpath/`install_name_tool` (host doesn't link it). `run.pl` gets NO own codesign (sealed as a Resource by the final app sign). The existing `codesign --verify --deep --strict` then validates the nested framework.

**`scripts/dev-run.sh`** — mirror both ops: after the BlockNote block, copy `run.pl` + `ditto` the framework into the dev `.app` (guarded by `[ -f … ] && [ -d … ]`, `rm -rf` the dest framework first for idempotency); in the Sparkle sign block before the app sign, `codesign --force --sign "${SIGN_IDENTITY}" --options runtime` the framework. Dev entitlements already inject `disable-library-validation`.

## 3. Entitlements
Add to `Resources/Sidekey.entitlements` (release source of truth):
```xml
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```
(Keeps the hardened-runtime private-framework load story consistent; dev path already has it.) Do NOT add `com.apple.security.automation.apple-events` (MediaRemote is prompt-free; only the AppleScript fallback uses TCC, and it drives the prompt at runtime, not via entitlement). No new Info.plist usage-description key.

## 4. Source: `Sources/Sidekey/NowPlaying/MediaRemoteNowPlayingSource.swift`
`final class MediaRemoteNowPlayingSource: NowPlayingSource, @unchecked Sendable`. Push-based cache, same external shape as `AppleScriptNowPlayingSource` so `NowPlayingController`/`Coordinator`/`Config` are UNCHANGED.
- **Process:** spawn `Process` = `/usr/bin/perl <run.pl> <dylib> loop` on `start()`, off-main I/O on a dedicated serial queue. Keep `standardInput`/`standardOutput` pipes.
- **stdout:** `readabilityHandler` buffers `Data`, splits on `\n`. Per line: `NIL` → `latest = nil`; else `JSONDecoder().decode(MediaRemoteTrackInfo)` → filter `bundleIdentifier ∈ {com.apple.Music, com.spotify.client}` (else treat as nil) → `MediaRemoteSnapshotMapper.snapshot(from:capturedAt:Date())` → store `latest` under lock. No main hop (controller polls the cache on its own timer).
- **`currentSnapshot()`** returns lock-guarded `latest` synchronously.
- **Transport (stdin):** write one line — `previous()`→`previous_track\n`, `next()`→`next_track\n`, `playPause(isPlaying:true)`→`pause\n`, `playPause(isPlaying:false)`→`play\n`. If the loop process is down, one-shot `perl run.pl <dylib> <command>`.
- **Artwork preservation:** same-track (title+artist) consecutive events with smaller/absent artwork keep the previous `NSImage` (anti-flicker).
- **Resilience:** `signal(SIGPIPE, SIG_IGN)` once; `terminationHandler` → clear `latest` + relaunch after 0.2s while `started`; proactive restart every ~100 events; `stop()` clears handler + `terminate()`.
- **Health-check (static):** `healthCheck()` runs a bounded (~2s) one-shot `perl run.pl <dylib> get`; OK iff exit 0 AND a parseable line (JSON or `NIL`). Fail-closed if `run.pl`/framework binary missing from the bundle.

## 5. Mapper: `MediaRemoteSnapshotMapper.snapshot(from:capturedAt:) -> NowPlayingSnapshot?` (pure, unit-tested)
- `app`: bundle id → `.music`/`.spotify`, else `nil`.
- `title`: trim; empty → `nil`. `artist`/`album`: `?? ""`.
- `duration`: `durationMicros/1_000_000`, `max(0,…)`. **No per-app divisor** (MediaRemote normalizes). `elapsed`: `currentElapsedSeconds`, `max(0,…)`. `isPlaying`: explicit bool else `playbackRate>0`. `artwork`: pass-through. `capturedAt`: now.

## 6. Source selection + fallback (in NowPlayingCoordinator or a small factory)
```
let source: NowPlayingSource = MediaRemoteNowPlayingSource.healthCheck() == .ok
    ? MediaRemoteNowPlayingSource(...)
    : AppleScriptNowPlayingSource(...)   // existing, unchanged; needs no entitlement (TCC at runtime)
```
Fixed for the session (no per-poll switch). Keep `AppleScriptNowPlayingSource` + `NowPlayingAutomationConsent` as the fallback. In `SettingsNowPlayingView`: the Automation permission row is meaningful ONLY when the active source is AppleScript — when the adapter is active, replace its copy with an informational "No permission needed — uses the system Now Playing" (or hide it). Keep the feature on/off toggle as-is.

## 7. Tests (keep all green; add pure unit tests)
- `MediaRemoteSnapshotMapper` mapping: bundle-id filter (Music/Spotify in, Safari/other → nil), microsecond→second (duration+elapsed), isPlaying bool-vs-rate, empty-title→nil, paused vs playing interpolation (inject fixed `now`).
- `MediaRemoteTrackInfo` Codable: canned JSON lines incl. int-`isPlaying`, `NIL`, missing-artwork; assert decoded fields + base64→non-nil NSImage for a known PNG.
- Line-framing: extract the stdout `\n`-splitter into a pure helper; test partial/multi-line/`NIL`.
- Artwork-preservation heuristic: pure fn over (prev,incoming); keeps larger art on same-track downgrade, passes through on track change.
- Existing `NowPlayingControllerTests` (fake source) unchanged — they now also cover the push-cache source by contract.

## 8. Verification (the agent does; on-device is Andrey's)
- `swift build` + `swift test` FOREGROUND, green at known baseline (2 env skips; flake `testLastSessionIDSetFromResultLine`).
- Packaging proof (this is where it kept breaking): run `./scripts/dev-run.sh` BUILD-ONLY (no `--run`) FOREGROUND (wrap with `doppler run --project sidekey --config dev --` if it needs env; if the signing identity/secrets are unavailable in this environment, report that and at minimum statically confirm the copy+sign edits are correctly placed). On success, verify: framework present at `build/Whytap-Beta-dev.app/Contents/Frameworks/MediaRemoteAdapter.framework`, `run.pl` at `Contents/Resources/MediaRemoteAdapter/run.pl`, `codesign -v --deep --strict build/Whytap-Beta-dev.app` passes, `codesign -d --entitlements - build/Whytap-Beta-dev.app | grep disable-library-validation` present, and `lipo -info` on the framework shows both arches.
- Do NOT launch the GUI.

## 9. Risks (already mitigated in the design)
Private-API fragility → health-check fallback + fail-closed. Legal → ungive BSD-3 + NOTICE + pinned SHA. Notarization → plain script + normally-signed framework + `disable-library-validation` (notarization-allowed); the four packaging guards (missing-asset hard-fail, universal assert, deepest-first sign, `--verify --deep --strict`). Universal mismatch → `lipo` assert. Long-lived leak → periodic restart.

## On-device retest (for Andrey, after agent finishes)
Quit the old dev build; `doppler run --project sidekey --config dev -- ./scripts/dev-run.sh --run`. Play a track in Apple Music → within ~1-2s the wing replaces the hints and the strip appears (title/artist/artwork/progress) WITH NO permission prompt; transport buttons drive the player. Repeat with Spotify. (If literally nothing: `log show --last 5m --predicate 'subsystem == "com.sidekey.nowplaying"' --info` should show coordinator start + adapter events; a missing framework would have failed the build's `--verify`.)
