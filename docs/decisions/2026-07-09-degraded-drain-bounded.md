# Degraded-турн hub-стрима резолвится с ограниченным ожиданием дренажа

**Дата:** 2026-07-09
**Где:** `Sources/Sidekey/Streaming/BYOK/DirectProviderStreamingSession.swift`

## Контекст

Пользователи жалуются, что «thinking» после отпускания хоткея Drop висит десятки
секунд. Прод-телеметрия (`client_events`, 30 дней): 10 турнов ждали
`resolving_ms − stop_requested_ms` = 20–42 с, из них 6 — `completed`. Самый
явный кейс — user 15, turn EE2A (2026-07-08): `stop_requested_ms: 27051`,
`resolving_ms: 64633` → `run()` вернулся через **37.6 с после отпускания**, при
том что серверная финализация уже давно умерла.

`resolving` метится ПЕРВОЙ строкой `handleStreamingResult`, сразу после
`await session.run()`. Значит 37.6 с висел сам `run()`. Разбор пути:

- Free-юзеры и все, кто на whytap-хабе, идут через
  `DirectProviderStreamingSession` (event-loop модель) + `WhytapHubAdapter`.
  BYOK-юзеры — тот же класс с прямым адаптером провайдера.
- При обрыве транспорта посреди записи (Wi-Fi/VPN-дропаут — то, что и деградирует
  турн) сессия помечается `degraded`, закрывает upstream, но **держит микрофон**
  (аудио копится в tee для batch-recovery). Событийный цикл `run()` ломается и
  упирается в `if degraded { _ = await audioTask?.value }`.
- `audioTask` дренажит уже накопленные чанки в **закрытый** upstream
  (`await session.sendAudio`). Старый комментарий утверждал, что это «provably
  non-hanging: на закрытом сокете send возвращается сразу». На **полуоткрытом**
  сокете (сеть пропала, но TCP не получил RST) `URLSessionWebSocketTask.send`
  висит до TCP-таймаута — десятки секунд. И на degraded-пути `stop()` делает
  early-return **без арминга стоп-вачдога** — поэтому ожидание ничем не
  ограничено.

`SonioxStreamingSession` (continuation-модель) этого бага НЕ имеет: там degraded
резолвится прямо в `stop()` (`resolve(with: .degraded)`), не дожидаясь дренажа.
Асимметрия и объясняет, почему хаб-юзеры (user 15) страдали.

## Решение

Заменить безлимитный `await audioTask?.value` на `awaitDegradedDrainBounded()`
— две фазы:

1. **Ожидание релиза — безлимитно.** Движок ещё пишет после degrade, поэтому
   резолвить рано нельзя (обрежет реплику). Ждём, пока движок перестанет
   производить чанки: `stopped` (юзер отпустил), `cancelled` (Escape) или
   `audioTaskCompleted` (форвард-петля завершилась сама — покрывает no-progress
   hard-resolve, который дёргает `audioEngine.stop()` без `session.stop()`).
   Длину удержания решает юзер — потолка нет.
2. **Остаточный дренаж — ограничен `stopWatchdog`.** `audioTaskCompleted`
   поднимается (один main-хоп в конце `audioTask`), когда петля дошла до конца.
   Если петля залипла на мёртвом сокете — срабатывает дедлайн, и `run()`
   резолвит `.degraded` всё равно. Retained PCM для batch-recovery **уже полон**
   (tee пишется на стороне ПРОИЗВОДСТВА чанков, в аудио-колбэке, независимо от
   send-петли), так что дренаж после релиза не добавляет ничего полезного.
   Осиротевший `audioTask` гасит `teardown` (`audioTask?.cancel()`).

Поллинг (не `await audioTask.value`) — намеренно: ожидание `Task<Void,
Never>.value` нельзя прервать по дедлайну (Failure == Never), гонка в task-group
просто вернула бы тот же висяк. Все флаги — `@MainActor`-стейт на `@MainActor`
классе, чтение бесплатно.

## Почему

- Корень — не «сеть тормозит», а «клиент бесконечно ждёт бесполезный дренаж в
  мёртвый upstream без вачдога». Ограничение ожидания лечит корень, а не симптом.
- Tee-инвариант («PCM полон на релизе») — то, что делает дренаж после релиза
  выбрасываемым: batch-recovery читает `capturedPCM16()` = `turnAudio`, а он
  наполнен в аудио-колбэке, не в send-петле.
- `stopWatchdog` (10 с) переиспользован как потолок, чтобы не плодить константу;
  в обычном случае флаг `audioTaskCompleted` выходит из фазы 2 за ~50 мс, потолок
  кусает только на патологически залипшем сокете.

## Что протестировали

- Репро `testDegradedStopResolvesPromptlyDespiteStuckSends`: 20 буферных чанков ×
  150 мс залипших sends. ДО фикса `run()` резолвился 3.12 с (в проде — 37.6 с при
  реальном темпе аплинка); ПОСЛЕ — 0.32 с (потолок 200 мс + оверхед).
- `testStopResolvesWithinWatchdogWhenTerminalIsLate`: поздний терминал на
  НЕ-degraded пути по-прежнему рубится стоп-вачдогом (регресс-гард).
- Весь `DirectProviderStreamingSessionDegradedTests` (9) зелёный, включая
  `testNoProgressResolvesWithoutStop` (движок стопается без `session.stop()`) —
  первый вариант фикса на `while !stopped` его вешал, отсюда `audioTaskCompleted`
  в условии фазы 1.
- Полный `swift test`: 3775 passed, 0 failures.

## Отвергли

- **Арминг стоп-вачдога в degraded-ветке `stop()`** — вачдог зовёт
  `audioTask?.cancel()`, но `URLSession.send` не обязан отвечать на отмену Task
  промптно; `run()` всё равно висел бы на `await audioTask.value`. Нужен bound на
  стороне `run()`, не отмена задачи.
- **Резолвить `.degraded` сразу на релизе (как Soniox)** — tee может ещё
  дописывать post-release tail (~600 мс) в момент `stopped`; ждём
  `audioTaskCompleted`/дедлайн, чтобы не потерять хвост в обычном случае.
- **Пропускать `sendAudio` при degraded (не слать в мёртвый upstream)** —
  полезная оптимизация, но одна уже начатая send всё равно могла бы залипнуть;
  bound в `run()` — то, что реально гарантирует отсутствие висяка. Оставлено как
  возможный отдельный follow-up.

2026-07-09 · PR: см. ветку fix/degraded-drain-bounded
