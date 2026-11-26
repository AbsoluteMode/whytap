---
id: test-suite-speed-2026-11-26
type: decision
title: Slow tests wait for conditions at a test pace, and a polling wait that runs out fails
summary: The slowest tests no longer wait the human-paced delays of fakes or a silently expiring deadline; product timing seams take a shorter value in tests; the full suite went from 455 s to 320 s. SwiftPM --parallel starts one process per test and is slower (351 s); two class shards in separate xctest processes take 165 s with no failure in ten runs, three shards 105 s.
status: confirmed
tags: [tests, speed, parallel, builder, flaky]
canonical_for: [test-suite-speed]
verified_at: 2026-11-26
sources:
  - type: user-confirmed
    reference: On 2026-11-26 the maintainer asked for faster testing and review after the council found the full suite grew from about 85 s in October to about 520 s, concentrated in a few slow tests; task 42 asked to remove real sleeps and timeouts without losing coverage and to try parallel runs at least ten times.
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/OnboardingPreviewTests.swift
    confirmed_at: 2026-11-26
  - type: repository
    reference: Tests/SidekeyTests/Translation/SpeechTranslationTests.swift
    confirmed_at: 2026-11-26
related: [2026-11-23-builder-queue-flaky-tests.md]
---

# Test suite speed

## Context

Measured on 2026-11-26, main at `0d40ad59`, one sequential `swift test` in a
clean worktree (host load 9 to 13, other sessions running): 6,208 tests,
59 skipped, no failure, **455.5 s**. 118 tests of one second or more took
321 s; the 5,635 tests under 50 ms took 33 s together. Per class:

| Class | Before | Cause |
| --- | --- | --- |
| `OnboardingPreviewTests` | 65.7 s | the preview's fakes wait so a person can watch (key check 0.7 s, System Settings 1.6 + 0.9 s, Tavily 0.6 s, model download 2.6 s, Try Drop quiet 1.2 s) |
| `SpeechTranslationModelTests` | 41.8 s | a 30 s polling wait that ran out and then passed; the stop watchdog's fixed 10 s |
| `PackagingRebrandTests` | 41.7 s | each case runs `build-dmg.sh` in a committed fixture, six cases in a row |
| `SubtitleSteadyOverlayTests` | 11 to 51 s | four tests replay the same 300-event recording |
| `LiveTextTickerTests` | 11.7 s | 400 in-between frames had every pixel counted and the count thrown away |
| `NotificationQueueTests`, `NotifyScriptSupervisorTests` | 4.2 s each | a real 2 s card and a real 2 s backoff |
| `OnboardingJourneyModelTests` (Tavily step) | 3.2 s | five 0.6 s answers of the preview's URL stand-in |

## Decision

- **Fakes and product timers take a test pace.** `OnboardingPreviewSession`
  has `pace` (default 1); tests pass 0.1 and every fake delay, the dwell and
  the Try Drop quiet run at a tenth, in the same order. `LiveSubtitleModel`
  takes `stopDeadline`, `OnboardingJourneyModel` `tryQuiet` and
  `NotifyScriptSupervisor` `backoffUnit`; the app keeps the old values.
  The checks that something does *not* happen kept a margin of several times
  the scaled delay (400 ms against a 78 ms dwell).
- **A polling wait that runs out fails.** The Subtitles helpers returned
  silently at the deadline; one test waited 30 s for a `listening` phase that
  lasted less than one poll and passed anyway. They now fail with the call
  site, like the other helpers; that test waits for the new session itself.
- **Shared setup where the frames are the same.** The recorded Subtitles
  session is replayed once per class; the four tests check their own
  property on the same frames. Every property must hold on any replay.
- **Independent fixtures run at once.** The four packaging tests with three to
  six `build-dmg.sh` cases run them concurrently (`concurrently`): each case
  has its own directory, stubs and marker.
- **Genuinely slow checks stay.** Real Settings-window rendering (about 1.5 s a
  test), Lil Bro frame-timing measurements, the 60-lecture pairing simulation,
  the `upload-release.sh` publication fixtures (about 2.7 s each) and the
  process-group Notify tests keep their cost: they measure or exercise the real
  thing and have no cheaper equivalent with the same coverage.

## Result

Same machine and worktree, full sequential `swift test`, 6,208 tests, no
failure: **455.5 s before, 320.5 s after** (−30 %). The classes above:
Onboarding preview 65.7 → 11.3 s, speech translation 41.8 → 2.0 s, packaging
41.7 → 33 to 36 s, steady overlay → 3.3 s, notification queue 4.2 → 1.2 s,
backoff 4.2 → 2.4 s.

## Parallel runs

- `swift test --parallel --num-workers 6`: **351 s**, slower than sequential.
  SwiftPM runs every XCTest method in a process of its own: the xUnit report
  sums to 2,095 s of test time for 6,208 tests (about 0.3 s of start-up per
  test), and host load rose from 29 to 37. It also exposed three tests that
  depend on running in one process with the others (below).
- Two `swift test --filter` processes in one package do not overlap: SwiftPM
  locks `.build` ("Another instance of SwiftPM is already running").
- **Class shards:** the built bundle run as `xcrun xctest -XCTest <classes>`
  in K processes at once, classes balanced greedily by their sequential times
  (with the fixes below). Two shards: ten runs, every one 164 to 166 s, all
  6,208 tests, no failure (host load 3.5 to 17 during the series). Three
  shards: three runs, 104 to 105 s, no failure. Each run's wall time is its
  slowest shard; the longest class is `PackagingRebrandTests` (about 35 s).

## Recommendation for the builder (not changed here)

Two class shards cut the full suite from about 320 s to about 165 s with no
flaky result in ten runs; three shards to about 105 s. The builder's scripts
belong to another task, so this decision only records the measurement. Before
the builder switches: shard by a committed class list or by a stable hash of
the class name with a check that the shards' total equals
`swift test --list-tests`, so no new class is left out; run the shards from
the built bundle (`xcrun xctest -XCTest`), because SwiftPM serialises two
`swift test` runs in one package; keep the load gate; record a failure with its
shard so an order dependence shows. The shards still share the test process's
`UserDefaults.standard` domain, the login Keychain and the temporary folder
across processes; the series found no collision after the fixes, which is
evidence, not a guarantee.

## Isolation defects found and fixed

- `BYOKKeyStoreTests` saved and deleted test keys under the app's own Keychain
  service and restored a snapshot afterwards. Two processes raced on the same
  item, and a crash between save and restore would have replaced or deleted
  the user's real OpenAI key. It now uses a service of its own per test.
- `SystemSoundGuardTests` read `NSApp`, which is nil until something creates
  the application; alone in its process the test crashed.
- `MeetingDetectorTests` collected the reconnect trigger within 2 s; under a
  loaded parallel run it took longer. The positive wait is now 10 s and checks
  that the event is the trigger, per the flaky-tests decision.
- `NativeAgentTests.testDetachedOutputCannotKeepCommandWaitingAfterLeaderExit`
  failed once under `--parallel` (250 ms deadline; already listed as load
  sensitive in the windowless decision). Not changed here.

## Rejected

- `swift test --parallel` for the builder: slower, see above.
- Shrinking the packaging fixture: the script itself takes about 0.3 s and git
  0.1 s; the remaining time is process start-up, which concurrency hides.
- Fewer lectures or fewer onboarding steps: that would remove coverage.
- A virtual clock everywhere: right for the product timers changed here, but
  the preview fakes only need one multiplier.

2026-11-26.
