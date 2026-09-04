# Drop degraded-путь: verbatim-склейка Soniox-токенов + 30s deadline на batch-recovery

**Дата:** 2026-07-22
**Где:** `Sources/Sidekey/Streaming/BYOK/BYOKTranscriptionAdapter.swift` (`BYOKTranscriptJoin`, `finalsJoin`), `WhytapHubAdapter.swift`, `SonioxBYOKAdapter.swift`, `DirectProviderStreamingSession.swift` (склейка live-транскрипта), `AppDelegate.swift` (`BatchRecoveryDeadline`, `withBatchRecoveryDeadline`, катчи rung 2/Retry).

## Контекст

Репорт Севы (тестер, V2Ray VPN, рвущаяся сеть; третий его VPN-арк после 2026-06-21 и 2026-06-29). Прод-телеметрия (user_id=15, 1.18.3 и 1.18.6): `voice_turn_failed` с `reason=salvaged_partial` (вставленный текст разбит по слогам: «Фи чи по фа кту») и `reason=degraded_batch_failed` с `resolving_ms` 61–93 секунды («зависло», Retry «неактивен», лечился перезапуском приложения).

## Решение

1. **Пробелы.** Живой транскрипт собирается по режиму `BYOKTranscriptJoin` сессии-источника: `.verbatim` (склейка встык) для Soniox-путей — `WhytapHubSession` (hub Soniox-only, ROO-262) и `SonioxBYOKSession`; `.wordBoundary` (прежняя эвристика «вставь пробел на стыке без пробела») остаётся дефолтом для BYOK-адаптеров с целословными финалами (Deepgram/ElevenLabs/OpenAI). Режим применяется и к финалам, и к склейке committed+partial.
2. **Deadline.** Батч-восстановление (rung 2 в `recoverOrSalvage` и manual Retry в `runBatchRecovery`) ограничено 30 секундами end-to-end: гонка `withThrowingTaskGroup` — операция против инжектируемого sleep. Проигравшая операция отменяется (URLSession кооперативен). Таймаут — типизированный `BatchRecoveryTimeout`, в телеметрии различим как `degraded_batch_timeout`; внешняя отмена (CancellationError) пробрасывается как есть и таймаутом не считается.

## Почему

- Живой пробой Soniox realtime (русская фраза через `say -v Milena`) показал: токены посабвордные («Фи», «чи», « по», « фа», «кту»), ведущие пробелы только на границах слов — склейка встык корректна by construction. Hub (`soniox.py`) шлёт каждый final-токен отдельным событием, и клиентская word-boundary эвристика вставляла пробел в каждый мид-словный стык. Штатный путь маскировал баг (вставка идёт из серверного `done`), а rung 3 (сырой салваж при недоставке) вставлял разбитую строку как есть. Заодно чинится live-превью в крыле острова.
- 60–93-секундные висяки — отложенный хвост из [2026-06-24-deliveryfailed-escapable-and-retry-robust.md](2026-06-24-deliveryfailed-escapable-and-retry-robust.md) (находка Codex #3). Пока батч висит, `.finishing` = `.noop` для hold-Space, а после клика Retry баннер сменяется на «finishing…» — для юзера «кнопка не работает». 30с: щедро для легитимного долгого WAV на медленном-но-живом линке (серверный бюджет Soniox — 60с), решительно для мёртвого.

## Что протестировали

- Живой пробой Soniox stt-rt-v5 (scratchpad-скрипт, синтезированная русская речь) — форма non-final/final токенов подтверждена.
- TDD: 5 тестов на склейку (verbatim Soniox-токены/пунктуация, wordBoundary-регрессия, контракты `finalsJoin` hub/BYOK-Soniox) + 7 на deadline (helper: таймаут/победа операции/проброс чужой ошибки; лестница: салваж партиалом по таймауту, rung 4 с `degraded_batch_timeout`, победа батча; manual Retry). Полный `swift test`: All tests passed, 0 failures.
- Состязательный проход Codex (gpt-5.5): подтвердил оба RCA по file:line, отверг adapter-level флаг (мультипровайдерный hub + пропущенный мною Soniox BYOK), рекомендовал 30с и единый deadline-шов, потребовал не конвертировать отмену в таймаут — всё учтено.

## Отвергли

- **Adapter-level флаг `finalsCarryOwnSpacing`** (мой первый драфт) — hub по коду мультипровайдерный, и прямой Soniox BYOK имеет ту же по-токенную семантику; флаг на адаптере промахивается по обоим.
- **Per-event join-аннотация** (рекомендация Codex в максимуме) — без серверной по-кадровой аннотации вырождается в session-level: hub-сессия ставила бы всем событиям один режим. Session-level свойство `finalsJoin` даёт то же покрытие меньшим диффом; per-event станет осмысленным, когда протокол хаба понесёт провайдера кадра (mid-stream failover) — зафиксировано комментарием у `finalsJoin`.
- **Серверный running-concatenation в `final`-кадрах** — клиент трактует финалы как дельты; накопленная строка дублировала бы текст. Изменение протокола — риск раскатки.
- **15–20с deadline** — retained-аудио может достигать ~20 MiB (десять минут); на медленном живом линке легитимная заливка не укладывается.
- **Size-adaptive deadline** — блэкхоленный большой WAV ждал бы ещё дольше; если понадобится прогресс-чувствительность, это inactivity-таймаут по upload-прогрессу + абсолютный кэп, не размер файла.

Ветка: `claude/seva-version-bugs-check-35b9a7`. Диагностика: телеметрия `client_events` (user_id=15), memory [[project_sidekey_drop_vpn_proxy_truncation]], [[project_sidekey_drop_resilient_delivery]].
