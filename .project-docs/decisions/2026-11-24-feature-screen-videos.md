---
id: feature-screen-videos-2026-11-24
type: decision
title: Feature screens get the Drop, Shot and Translate clips
summary: Three bundled clips for the feature screens (drop-fast, screenshot, translate), named after their kit scene ids and referenced from FeatureCatalog.video; a Subtitles clip is made and waits for a place on the shared screen; the clips follow build 1747 and show real model output.
status: confirmed
tags: [settings, video, features]
canonical_for: [feature-screen-videos]
verified_at: 2026-11-24
sources:
  - type: user-confirmed
    reference: On 2026-11-24 the user asked for the whole settings rebuild around features at once and said a new user must find it simple, so missing feature videos should be made (relayed by the orchestrator, task 104).
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/FeatureVideo.swift
    confirmed_at: 2026-11-24
  - type: repository
    reference: Sources/Sidekey/Settings/Features/FeatureCatalog.swift
    confirmed_at: 2026-11-24
related: [2026-11-20-other-feature-videos.md, 2026-11-24-settings-around-features.md, 2026-11-24-click-to-copy-translation.md]
---

# Feature screens get their clips (Drop, Shot, Translate)

## Context

Settings now open on Features, and each feature gets its own screen with a
"how it works" clip. Drop, Translate & Subtitles and Screenshots had none, so
their screens showed no clip.

## Decision

- Three clips in `Resources/FeatureVideos`, named after the motion kit's scene
  ids like the existing ones: `drop-fast.mp4` (`.dropFast`, "Drop"),
  `screenshot.mp4` (`.screenshot`, "Shot") and `translate.mp4` (`.translate`).
- `FeatureCatalog` points Drop, Screenshots and Translate & Subtitles at them;
  the feature screen template draws `FeatureInfo.video`. Drop can play its
  clip now. Shot and Translate can play theirs after their feature screens
  ship. Other screens keep the existing quiet “Video coming” row when a
  bundled clip is unavailable.
- A Subtitles clip (kit scene `subtitles`) is made too. A feature has one clip
  and the shared screen has no Subtitles block yet, so it is not bundled: a
  bundled clip with no place to play would only add weight. It joins as
  `subtitles.mp4` / `.subtitles` with the screen part that shows it.
- A clip counts as shown when it is a feature's catalog clip or has a ▶ on an
  Other row (`test_every_feature_video_has_a_button`).
- Encoding as the earlier row clips: 720p re-encodes of the kit render with the
  landing import settings (H.264, BT.709 limited range, CRF 28, no audio).

## Why

- Same naming as the kit and the site, so a re-render replaces a file by name
  and the scene file (`motion/videos/<id>.json`) names the code it mirrors.
- The clips follow the app at build 1747: Drop's wing reveals letters at the
  speaker's pace from dust and scrolls (LiveTextTicker), Shot's arrow cluster is
  261 pt, and Translate and Subtitles show real model output — Translate's
  answer from the app's own request to the user's route (claude-sonnet-5-5),
  Subtitles every word and its arrival time from a recorded OpenAI live session.
- Defaults are what a new user gets: hold Space for Drop, Auto · RU ↔ EN for
  Translate, Auto-detect → Russian for Subtitles.

## Translate re-shot for click-to-copy

The user accepted Drop, Shot and Subtitles and asked that Translate show the
new click on the translation. The clip now copies with one click on the
result: the text tints under the pointer (8 %, 14 % pressed) and "Copied ✓"
shows for a second, instead of right-click and Copy translation. Same answer,
same scene otherwise; kit commit `c7e97b15`.

## What we tested

- `check-videos.py --scenes`: the four scene files' quoted lines exist on main.
- Frames of every step checked by eye; Vocab rendered byte-identical after the
  shared kit change, so accepted clips did not move.
- The translation request ran twice with the same answer.

## Rejected

- Translate into German for an English-only screen: not the app's default, and
  the default is what a new user sees.

2026-11-24 · PR: feature screen clips (this change)
