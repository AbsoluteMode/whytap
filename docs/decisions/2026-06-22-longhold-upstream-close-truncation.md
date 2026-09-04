# Длинная диктовка обрывается на ~40с: upstream-close + резолвер вставлял огрызок

## Контекст

Максим на проде (Whytap 1.12.11, user_id=2, hub → ElevenLabs) держал клавишу Drop
непрерывно ~50с и получал «ничего» / крошечный огрызок. Воспроизвели и сняли
прод-телеметрию:

- turn `567FDD9B`: `total_ms=37750`, **`stop_requested=false`** (клавишу держал, не
  отпускал), `resolving_ms=37254`, `token_count=12`. То есть стрим **сам**
  зарезолвился на ~37с, в текст ушло 12 токенов из ~50с речи.
- turn `B30E` ранее: то же — 37.9с, `stop_requested=false`, 35 токенов.
- Серверный uvicorn реально запущен с `--ws-ping-interval 3600 --ws-ping-timeout
  3600` (фикс #247 на проде) — значит хоп **клиент↔наш-сервер** уже не рвётся на
  ~40с. Обрыв идёт с хопа **наш-сервер↔ElevenLabs** (или внутри EL): EL закрывает
  наш upstream-коннект на ~37-40с при непрерывном аудио. Хаб форвардит close/done
  с накопленным `finalText` → клиент резолвит `.transcript(finalText=12 токенов)`,
  `stopRequested=false`.

Независимый проход Codex по коду подтвердил клиентскую дыру: пустой/обрезанный
терминальный транскрипт обходит все recovery-рунги (`silence_guard`→idle для
пустого; прямой paste огрызка для непустого), а накопленное локальное аудио
(`capturedAudioPCM16`) НЕ доганивается батчем — батч-лестница работала только для
`.failed`/`.degraded`.

Это НЕ покрылось #408 (resilient delivery): тот резолвер обрабатывал `.failed`/
`.degraded`, а «нормально зарезолвился `.transcript` с огрызком на upstream-close»
выглядел как обычная успешная доставка.

## Решение

**Слой B (клиент, этот фикс):** в `AppDelegate.resolveDelivery` — `.transcript` с
`stopRequested == false` (ненормальный конец: провайдер/upstream закрыл стрим, пока
юзер держал) уходит в `recoverOrSalvage` (batch по полному PCM), а не вставляет
realtime-текст. Realtime-текст несётся как salvage-фолбэк (длиннейший из него и
UI-партиала) — никогда не отдаём МЕНЬШЕ, чем дал живой стрим. `.endpointDetected`
(легитимный VAD-конец речи) — исключение, всегда доставляет realtime. Нормальный
stop (`stopRequested=true`) не тронут: realtime-финал доверяем как раньше.

Сигнал ненормальности — `stopRequested`, проброшен `handleStreamingResult →
resolveViaSink → resolveDelivery`. Дефолт параметра `= true` (нормальный turn), но
прод-путь обязан передавать реальное значение — защищено source-pin'ом
`test_abnormal_transcript_without_stop_batch_recovers`.

Батч-путь (`/api/transcribe`, один HTTP-multipart с полным WAV) **не** страдает от
~40с realtime-обрыва — нет долгоживущего WS, ws-ping/keepalive не применяются →
надёжно отдаёт полный транскрипт записанного.

## Почему

- Локальное аудио = истина (принцип resilient-доставки). Раз стрим умер, но мы
  записали аудио — добиваем батчем, а не теряем.
- `stopRequested=false` на `.transcript` — детерминированный признак ненормального
  конца: нормальный `.transcript` приходит ПОСЛЕ end-of-stream, который шлётся
  только на `stop()` (отпускание). Провайдерский авто-конец = `.endpointDetected`,
  не `.transcript`. Значит false-срабатываний в нормальном потоке нет.
- Скоуп — только Drop: agent-voice и Google идут своими `handleStreamResult` с
  `resilient:false`; Task 4 `.degraded` — отдельная ветка, не тронута.

## Что протестировали

- TDD RED→GREEN: `test_transcript_without_stop_batch_recovers_full_audio` (огрызок →
  батч полного аудио), `test_transcript_without_stop_empty_still_batch_recovers`
  (пустой close с реальным аудио → батч, НЕ silence_guard). Guard'ы:
  `test_transcript_with_stop_delivers_realtime_not_batch`,
  `test_endpointDetected_without_stop_still_delivers_realtime`.
- Source-pin проводки: `test_abnormal_transcript_without_stop_batch_recovers` +
  обновлён `test_degraded_result_routes_to_batch_recovery`.
- Полный `swift test`: 3321 тест, 0 провалов, 37с.

## Отвергли

- **Чинить на уровне сессии (резолвить upstream-close как `.degraded`)** — чище
  семантически, но трогает lifecycle `SonioxStreamingSession` (риск задеть
  `.endpointDetected` и stall-пути); резолвер-уровень контейнернее и полностью
  unit-тестируем.
- **Дефолт `stopRequested` без проброса** — футган: молча вернул бы баг; закрыли
  source-pin'ом.
- **Только починить пустой `silence_guard`-кейс (минимум по Codex #1)** — не
  покрывает обрезанный (непустой огрызок) кейс, а у Максима именно он (12 токенов).

## Известное ограничение / хвосты

- Слой B спасает аудио, **записанное до ~37с close**. Если держать дольше, хвост
  после close не записан (сессия зарезолвилась). Полное «без обрезки» требует:
  - **Слой A (backend, отдельный репо):** keepalive/ping на хопе наш-сервер↔EL,
    чтобы EL не рвал на ~37-40с — тогда realtime отдаёт всё целиком.
  - либо **client-premium:** не резолвить turn на upstream-close пока юзер держит,
    копить аудио до отпускания, затем батч полного буфера.

---

2026-06-22 · ветка `claude/youthful-leakey-95a4af` · фикс resolveDelivery
(`stopRequested`-ветка) · связано: [[byok-noprogress-deadlock]],
docs/superpowers/specs/2026-06-21-drop-delivery-resolver-design.md
