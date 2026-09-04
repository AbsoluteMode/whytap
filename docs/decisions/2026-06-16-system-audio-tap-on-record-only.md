# System audio tap — только во время записи, не always-on

## Контекст

Пользователи видели постоянно горящий индикатор macOS «Системная аудиозапись»
(Privacy & Security → Whytap Beta), хотя запись митинга не шла. Для
voice-продукта это выглядит как скрытая слежка и бьёт по доверию.

## Решение

CoreAudio process tap (`CoreAudioSystemAudioSource`) поднимается только когда
реально идёт запись митинга — через `SystemAudioVADProbe.audioBufferStream()`
(recorder fan-out). Из `SystemAudioVADProbe.subscribe()` (VAD `Bool`-стрим,
который детектор слушает always-on) запуск тапа убран.

## Почему

- `MeetingsCoordinator.start()` гейтится только на `MeetingsConfig.isEnabled`
  (по умолчанию `true`) и безусловно зовёт `detector.subscribe()` →
  `vadProbe.subscribe()`. Детектор подписывается один раз на старте и никогда
  не останавливается (`detector.stop()` в проде не вызывается). Значит tap,
  поднятый в `subscribe()`, жил всю сессию → индикатор горел постоянно.
- VAD-результат при этом даже не использовался для триггера: system-audio
  Silero в проде классифицировал реальный звук Zoom/Slack как тишину, путь
  bypassed. Реальный триггер — frontmost-app whitelist + mic
  (`tryFireFromFrontmost` / `scheduleMicOnlyTrigger`). То есть tap зажигал
  индикатор ради данных, которые выбрасывались.
- Recorder при старте записи сам поднимает tap через `audioBufferStream()`
  (тот же инстанс `vadProbe`, передаётся как `systemSource` в
  `MeetingRecorder`), так что запись митинга не страдает.

Выбран хирургический вариант (A1): убрать запуск тапа из `subscribe()`, не
трогая логику детектора. VAD `Bool`-путь оставлен wired-but-dormant.

## Что протестировали

- RED/GREEN: новый тест `SystemAudioVADProbeTests.test_subscribe_doesNotStartSource`
  — `subscribe()` не трогает source (`startCount == 0`). До правки падал
  (`startCount == 1`), после — проходит.
- Регрессии: `SystemAudioVADProbeTests` (6), `MeetingDetectorTests`,
  `MeetingsCoordinatorTests` (21), `MeetingRecorder*` — 63 теста, 0 провалов.
  Путь записи (`audioBufferStream` first-call старт + second-call rebuild)
  по-прежнему зелёный.

## Отвергли

- Полное выпиливание VAD `Bool`-пути из детектора (вариант A2) — больше работы
  и переписывание ~10 тест-кейсов; отложено до решения, возвращаем ли
  VAD-детекцию вообще.
- Оставить как есть — постоянный индикатор «Системная аудиозапись» =
  репутационный риск для voice-продукта.

---

Дата: 2026-06-16. PR: https://github.com/rootwise-team/sidekey/pull/337
