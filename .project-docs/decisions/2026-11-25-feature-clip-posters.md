---
id: feature-clip-posters-2026-11-25
type: decision
title: A feature screen's clip card shows a frame of the clip with a play mark
summary: The "Watch how … works" card shows a 16:9 frame read from the bundled clip at a chosen moment where the feature's result is on screen, with a play mark over it, instead of a grey tile. Read once per session on this Mac; a clip not made yet keeps the quiet tile.
status: confirmed
tags: [settings, features, video]
verified_at: 2026-11-25
sources:
  - type: user-confirmed
    reference: On 2026-11-25, looking at the "Watch how Google search works" card in build 1752, the maintainer asked for a preview of the video on it (ORCH-99, via the orchestrator).
    confirmed_at: 2026-11-25
  - type: repository
    reference: Sources/Sidekey/Settings/FeatureVideo.swift
    confirmed_at: 2026-11-25
  - type: repository
    reference: Tests/SidekeyTests/Settings/FeatureClipPosterTests.swift
    confirmed_at: 2026-11-25
related: [2026-11-24-feature-screen-videos.md, 2026-11-20-other-feature-videos.md]
---

## Context

The clip card on a feature screen (`FeatureVideoStrip`) drew a grey 54×34
tile with ▶. It did not show what the clip is about until it was played.

## Decision

- The card shows a 96×54 frame of the clip with a dark round play mark (a
  stop mark while it plays). A clip not made yet keeps the grey tile with
  the film icon and "Video coming".
- Each clip names its moment, `FeatureVideo.posterSeconds`, chosen from a
  contact sheet of every clip: the result on screen (Agent's answer with the
  file, Google's results, Drop's dictated text, the call with live captions,
  Shot's arrow, the finished translation), never the dark first frame.
- `FeatureVideoPoster` reads the frame with `AVAssetImageGenerator` from the
  bundled file (at most 320×180), once per session, and keeps it in memory.
  Nothing is fetched and nothing is written to disk.

## Why

- A frame says what the clip shows before it is played, which a grey tile
  did not; Maxim asked for it.
- Reading the frame from the clip keeps one source: a re-rendered clip brings
  its new frame, with no second image file to keep in step.
- One moment per clip, not "a second in": the clips open on a dark desktop.

## What we tested

`FeatureClipPosterTests`: every bundled clip's moment is after the first
second and inside the clip; every clip a feature screen shows gives a 16:9
frame that is neither black nor blank (mean and spread of its luminance) and
is read once; a missing file gives no poster and nothing cached; offscreen
pictures of every feature's cards in both appearances, including
Translate & Subtitles with a poster and a "Video coming" slot.

Not checked in a running app: how long the first read takes on a cold start
(the tile shows until the frame arrives).

## Rejected

- PNG posters bundled beside the clips: a second file per clip that could
  drift from a re-rendered clip.
- The first frame or a fixed second: dark for every clip.
- A looping silent preview: plays by itself, which the clips must not do.

2026-11-25 · PR (this branch)
