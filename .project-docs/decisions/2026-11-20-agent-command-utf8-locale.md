---
id: agent-command-utf8-locale-2026-11-20
type: decision
title: Agent commands always run with a UTF-8 locale
summary: Commands started by the native Whytap Agent always get a UTF-8 LANG, the app's own when it is UTF-8 and en_US.UTF-8 otherwise, because an app opened from Finder has no locale and tools such as pbcopy then corrupt every non-ASCII character.
status: confirmed
tags: [agent, commands, locale, clipboard, encoding]
canonical_for: [agent-command-locale]
verified_at: 2026-11-20
sources:
  - type: user-confirmed
    reference: On 2026-11-20 the user reported that the agent copied a file with Cyrillic text and the clipboard on his second computer held a broken copy while the file itself was fine. After the cause was explained and he asked whether other languages would work, he approved the fix.
    confirmed_at: 2026-11-20
  - type: repository
    reference: Sources/Sidekey/AgentDaemon/NativeAgentCommand.swift
    confirmed_at: 2026-11-20
  - type: repository
    reference: Tests/SidekeyTests/AgentDaemon/NativeAgentCommandLocaleTests.swift
    confirmed_at: 2026-11-20
related: [2026-10-22-native-agent.md]
---

# Agent commands always run with a UTF-8 locale

## Context

`run_command` starts its shell with a short allowlist of the app's environment.
`LANG` was on that list, but an app opened from Finder or at login has no
`LANG` at all, so the command ran in the C locale. `pbcopy` then reads its
input as MacRoman: "Privet, mir" written in Cyrillic reached the clipboard as a
run of dashes and accented Latin letters. The file on disk was never changed.
On the owner's main Mac the app had been relaunched from a terminal by the
builder, which is why the same request worked there.

## Decision

`NativeAgentCommand.childEnvironment` always sets `LANG`: the app's own value
when it ends in `.UTF-8` and macOS has that locale installed
(`/usr/share/locale/<name>/LC_CTYPE`), so `ru_RU.UTF-8` or `C.UTF-8` is kept;
otherwise `en_US.UTF-8`. `LC_ALL` and `LC_CTYPE` are still not inherited, so
they cannot switch the command back. Nothing else about the child environment
changes.

## Why

Only the encoding part of a locale decides how bytes become characters, and
UTF-8 covers every script, so one fixed fallback is correct for all languages.
The language part (`en_US`) only affects message language and sorting of the
tools the agent runs, which the model reads either way.

## What was checked

- Reproduced with `pbcopy` on the Find pasteboard: no `LANG` breaks Cyrillic,
  `LANG=en_US.UTF-8` keeps it.
- The running app on the main Mac has `LANG=en_US.UTF-8`, consistent with the
  problem appearing only on the other computer.
- Tests run real commands with an empty and a `C` base environment over
  Cyrillic, Chinese, Japanese, Korean, Arabic, Hebrew, Hindi, accented Latin
  and emoji: `locale charmap` is UTF-8, `wc -m` counts characters instead of
  bytes and `cat` returns the text. They fail on the code before the fix.
- The builder's review found that an inherited `ja_JP.utf8` was kept and ran
  as US-ASCII: Darwin resolves only exact installed names, and an unknown name
  silently behaves as C. The inherited value is now checked against the
  installed locales, and the real-command test covers `ja_JP.utf8`, an unknown
  `xx_YY.UTF-8`, a legacy charset and an inherited `LC_ALL=C`.
- Not checked: the clipboard on the second computer after the fix.

## Rejected

- Add a clipboard tool to the agent: larger change, and other locale-dependent
  tools would stay broken.
- Inherit `LC_ALL` and `LC_CTYPE` too: a stray `LC_ALL=C` would bring the bug
  back.

## Limit

A file that is itself stored in a legacy encoding is not converted.

Decided 2026-11-20. Branch: fix/agent-command-utf8-locale.
