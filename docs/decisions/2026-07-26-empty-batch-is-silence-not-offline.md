# Пустой batch-транскрипт = тишина, а не offline

**Дата:** 2026-07-26
**Где:** `Sources/Sidekey/AppDelegate.swift` (`recoverOrSalvage` / `salvageOrFail`, параметр `armRetry`), `Tests/SidekeyTests/DropDeliveryResolverTests.swift`.

## Контекст

Максим (user_id=9, прод 1.18.7 build 1440) получил в острове терминальную пилюлю
«Couldn't deliver — offline» + Retry и не понял, откуда она.

Разбор турна `7D591F20` (04:29:18 по его времени, +05):

| Слой | Факт |
|---|---|
| client_events | `voice_turn_failed reason=degraded_batch_failed`, `token_count=0`, `stop_requested=false`, `resolving_ms=12923`, `total_ms=15863`; следом `user_error error_type=delivery_failed` |
| nginx (`sidekey-backend-access.log`) | WS `GET /api/transcribe/stream/v2` → 101, но `body_bytes_sent=0` за 6.4 с (у соседнего УСПЕШНОГО турна — 1259 байт); затем `POST /api/transcribe` → **200**, тело **11 байт** = `{"text":""}` |
| backend app | `proxy.transcribe outcome=ok provider=soniox-async audio_duration_sec=12.599625 latency_ms=2380` |
| Retry юзера (04:36:47) | `island_control_click control_id=delivery_retry` → тот же POST → снова 200 / 11 байт |

То есть: аудио (12.6 с) дважды целиком дошло до бэкенда, Soniox отработал и вернул
**пустой** транскрипт. Сеть была жива — «offline» в копии не соответствовал
реальности, а Retry переотправлял ту же тишину и детерминированно получал пусто.

Корень в лестнице доставки: `recoverOrSalvage` при пустом ответе батча вызывал
`salvageOrFail()` с дефолтным reason `degraded_batch_failed`, и при отсутствии
партиала это уходило в rung 4 — `retainForRetry` + `.deliveryFailed`. Успех батча
с пустым текстом и полный отказ транспорта попадали в одну и ту же терминальную
ветку.

Побочный эффект в проде: под `degraded_batch_failed` слиты два разных класса.
За последние ~780 турнов — 8 событий: у Максима/user 2 `total_ms` 16–23 с
(быстрый 200 + пустой текст), у Севы (user 15, 5 шт.) `total_ms` 121–145 с
(настоящие сетевые висяки). По телеметрии их было не различить.

## Решение

Пустой ответ батча — отдельная ветка: `salvageOrFail(batchFailureReason:
"degraded_empty", armRetry: false)`.

- партиал есть → rung 3 (raw-paste) как раньше;
- партиала нет → `degraded_empty` + `.idle`, **без** `retainForRetry` и без пилюли;
- партиал есть, но паста упала → `salvaged_partial_paste_failed` + `.idle` (тоже
  без ретрая — он бы перезапустил тот же пустой батч).

`armRetry: true` (дефолт) сохраняет прежнее поведение всех остальных путей:
брошенная ошибка → rung 4, таймаут → `degraded_batch_timeout` + rung 4,
local-сессия / пустой PCM → `degraded_no_audio` + idle.

## Почему

- **Честность копии.** «Couldn't deliver — offline» на живой сети — прямое враньё
  пользователю. Rung 1 в такой же ситуации (пустой realtime-транскрипт при
  user stop) уже давно идёт в тихий idle через `silence_guard`; rung 2 теперь
  ведёт себя так же.
- **Retry обязан иметь шанс.** Ретрай пустого батча возвращает пустой батч —
  кнопка, которая не может сработать, хуже её отсутствия.
- **Наблюдаемость.** `degraded_empty` отделяет «провайдер не услышал речь» от
  «транспорт умер»; иначе доля ложных «offline» в проде неизмерима.
- Manual-Retry путь (`runBatchRecovery`) уже обрабатывал пустой результат
  правильно (`degraded_empty` + idle) — расхождение было только в первичном
  пути. Правка приводит их к одному контракту.

## Что протестировали

TDD, `DropDeliveryResolverTests` (RED → GREEN):

- `test_degraded_batch_empty_transcript_idles_without_arming_retry` — до фикса
  падал на `.deliveryFailed` вместо `.idle` и `degraded_batch_failed` вместо
  `degraded_empty`, audio арминался в retry;
- `test_empty_batch_with_failed_partial_paste_idles_without_arming_retry` — до
  фикса арминал retry и парковал `.deliveryFailed`;
- `test_empty_batch_still_salvages_a_live_partial` — regression-guard, зелёный
  и до, и после (rung 3 не тронут).

Полный прогон: 3950 тестов, 0 падений, 7 skipped. Существующие ветки
(`degraded_batch_failed` на throw, `degraded_batch_timeout` на дедлайне,
local-сессия без backend-Retry) остались зелёными без правок.

## Отвергли

- **Только телеметрия (новый reason, UI без изменений)** — масштаб стал бы виден,
  но пользователь продолжал бы видеть ложный «offline» + мёртвый Retry.
- **Оставить как есть** — повторяется у нескольких юзеров, а не только у Максима.
- **Показывать отдельную пилюлю «Didn't catch that»** — это новая UI-поверхность
  на кейс, который rung 1 уже обрабатывает молча; паритет с `silence_guard`
  важнее нового элемента.
- **Не арминать Retry вообще на всех degraded-путях** — сломало бы реальный
  offline-кейс (Task 7), где локальное аудио — единственная копия дикции.

Не входит в эту правку: почему конкретно в записи не оказалось речи — PCM жил
только в памяти приложения (`pendingRetryPCM`) и постфактум недоступен.
Связанные решения: `2026-07-22-hub-token-join-and-batch-recovery-deadline.md`,
`2026-06-24-deliveryfailed-escapable-and-retry-robust.md`.
