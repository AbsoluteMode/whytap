# ElevenLabs BYOK: аккумулировать сегментные commit'ы вместо терминирования на первом

## Контекст

Drop на **BYOK → ElevenLabs** (Settings → Models → Your key) принудительно
завершался примерно на 30–40-й секунде удержания: остров показывал
"finishing…", запись обрывалась сама, длинная диктовка терялась.

Это **рецидив уже диагностированного бага**. 22 июня тот же симптом нашли на
hub-пути (наш сервер → ElevenLabs) и починили на бэкенде
(sidekey-backend PR #250, `app/proxy/streaming_providers/elevenlabs.py`;
backend decision-doc `2026-06-22-elevenlabs-segment-commit-truncation.md`).
Клиентский **BYOK-direct** путь (`ElevenLabsBYOKSession`, клиент ходит к
ElevenLabs напрямую ключом пользователя, минуя наш сервер) — это **другой
адаптер**, и фикс на него не портировали. Сам путь, по комментарию в коде
(«LIVE-VERIFY … unconfirmed against a live socket»), был написан по докам и
вживую не обкатан — баг всплыл, когда на нём впервые продиктовали длинно.

## Решение

Портировать механику #250 в `ElevenLabsBYOKSession`
(`Sources/Sidekey/Streaming/BYOK/ElevenLabsBYOKAdapter.swift`):

- На `committed_transcript` — **накапливать** сегмент в `finalParts`, эмитить
  `.final(text)` (для живого превью) и **продолжать слушать**.
- Терминал `.done(joined)` эмитить только когда (1) пришёл наш manual commit
  после release (`endInput()` ставит флаг `_endInputSent` под `NSLock` —
  receive-task и `endInput()` на разных executor'ах), **или** (2) сокет
  закрылся, а сегменты уже накоплены (recovery — отдать накопленное, не
  потерять).
- Закрытие сокета без единого сегмента остаётся `.error("transport")`.

## Почему

ElevenLabs Scribe v2 Realtime сам авто-коммитит сегмент на его максимальной
длине (~36 с) **без** нашего commit — даже при `commit_strategy=manual`.
`committedTranscript` — это **список** сегментов, и сокет остаётся открытым
между ними. Старый клиентский код принимал **первый** `committed_transcript`
за конец турна (`emit(.done)` + `finish()` + `return`), поэтому любая
диктовка длиннее сегмента (~36 с) обрывалась на первом авто-commit'е.

Soniox BYOK тем же багом не страдает: он не режет сегменты сам — терминал
(`finished:true`) приходит только в ответ на наш end-маркер. Поэтому симптом
был виден именно на ElevenLabs.

## Что протестировали

5 TDD-тестов в `ElevenLabsBYOKAdapterTests` (red → green):

- `testMidHoldAutoCommitIsNotTerminal` — авто-commit посреди удержания не
  завершает турн (следующий partial доказывает, что стрим открыт).
- `testCommitAfterEndInputJoinsAllSegments` — терминал склеивает все сегменты
  (полная диктовка, не только последний сегмент).
- `testConnectionCloseRecoversAllAccumulatedSegments` — закрытие сокета до
  нашего commit восстанавливает накопленное как `.done`.
- `testConnectionCloseWithNoSegmentsSurfacesError` — пустое закрытие = ошибка
  транспорта (guard).
- `testShortDictationCommitsOnEndInput` — короткая диктовка коммитится по
  release (guard).

Корень подтверждён на бэкенде 22 июня реальным frame-capture (#249):
partials идут непрерывно, `committed_transcript` падает на 36.2 с — адаптер
там и возвращался.

## Отвергли

- **uvicorn `--ws-ping-interval` / websockets `ping_interval=None`** (backend
  #247/#248) — гипотеза keepalive, эмпирически red herring: 36 с резало и
  после деплоя.
- **Обход через whytap-hub** (переключить юзера с Your key на Whytap, где
  фикс уже есть) — рабочий немедленный workaround, но это уже наш сервер/наш
  ключ, BYOK-путь остаётся сломанным. Оставлен как временная мера, не как
  решение.

---

2026-06-30. Связано: sidekey-backend PR #250 (hub-аналог), backend
decision-doc `2026-06-22-elevenlabs-segment-commit-truncation.md`.
Якорь в коде: `// WHY:` в `ElevenLabsBYOKAdapter.swift` (ветка
`committed_transcript`). PR: _добавить после открытия._
