---
id: shot-ocr-warmup
type: decision
title: Prepare Shot's accurate Vision recognizer at launch
summary: Prepare Vision at utility priority on generated text so the first Copy text after preparation avoids the model compilation delay.
status: observed
tags: [shot, screenshots, ocr, vision, performance]
canonical_for: [shot-copy-text-cold-start]
verified_at: 2026-11-28
sources:
  - type: repository
    reference: scripts/benchmark-screenshot-ocr.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Sources/Sidekey/Screenshots/ScreenshotDocument.swift
    confirmed_at: 2026-11-28
  - type: repository
    reference: Tests/SidekeyTests/Screenshots/ScreenshotTextCopyTests.swift
    confirmed_at: 2026-11-28
related: [2026-10-20-screenshot-toolbar.md]
---

## Context

On an Apple M4 Pro with macOS 27.3, the first accurate Vision request in a
newly linked benchmark client took 28–33 seconds, including on small crops.
Subsequent requests took tens to hundreds of milliseconds, including in later
processes of the same executable. Timing inside the recognizer put the delay
in `VNImageRequestHandler.perform`. Apple Espresso logged model-graph
construction during the slow call. Cropping, image preparation, and request
configuration took milliseconds.

## Alternatives

Fresh clients still stalled with CPU, default compute, GPU, and automatic
language detection disabled. Fast Vision was much quicker and missed the four
Russian lines of the mixed fixture. Smaller inputs had the same initial
stall, so reducing capture resolution would sacrifice detail without solving
initialization.

## Decision and rationale

Start one utility-priority preparation task at launch. Run the existing
accurate request on a tiny bitmap containing generated English and Russian
text. This initializes the same system recognizer used for Copy text. Keep
the configured languages, correction, dark-crop treatment, and native Retina
crop for the requested copy. An early copy awaits the shared task off the
main thread so it does not start a second initialization. Escape cancels the
editor operation and any in-flight user Vision request. A generation check
continues to prevent late clipboard writes.

## Consequences and resolution

Compilation still takes time after a new executable is installed. Copy text
invoked during preparation can wait for the remainder. The preparation task
reads only generated pixels and remains independent of the clipboard and
screen capture. Shot logs only the phase, pixel dimensions, and elapsed Vision
time. The benchmark reports separate preparation time and hashes of the
generated-fixture recognition output for quality comparison. Wall-clock
thresholds vary with the system model cache and available hardware, so the
test suite checks correctness without asserting a time budget.

Release-batch review (2026-11-28, same Mac), measured with fresh benchmark
clients:

- The cache belongs to the executable: a second launch of the same binary
  prepares in about 0.1 s. The 28 s preparation therefore runs once after
  each newly installed build, not after every restart.
- The waiting happens in the system `ANECompilerService` (about 90% of a core
  for the whole preparation), although the request is set to the CPU; the
  client itself used about 4 s of CPU. A second fresh client compiling at the
  same time failed with `e5rtError` (`create_precompiled_compute_operation`).
  Inside Whytap only Shot uses Vision, and Copy text waits for the
  preparation (`ScreenshotTextCopy.read(_:after:with:)`) instead of starting a
  second compile.
- Text and numbers Blur during that window waits for the preparation too:
  23.7 s in a fresh client, against 0.07 s for the same Blur in a fresh
  client without preparation. It runs off the main thread under "Blurring on
  this Mac…". This is the accepted cost of moving the stall out of Copy text.
- Whether an on-device Parakeet model load during the window waits for the
  same compiler service was not measured.

This supersedes the lack of warmup in the Copy text restoration section of the
[Shot toolbar decision](2026-10-20-screenshot-toolbar.md).
