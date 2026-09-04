# «Вообще ничего не отдаётся» — stop-before-run race в StreamingAudioEngine

## Контекст
У части пользователей голосовой ввод (Drop) не отдавал ничего: запись будто шла,
но в input пусто, без зависания финала (это отдельный backend-баг — см.
`sidekey-backend` decision той же даты). Воспроизводилось у двух коллег при живом
интернете (не VPN). Ревью Codex локализовало клиентский race: deferred stop во
время setup мог теряться.

## Решение
`StreamingAudioEngine.stop()` теперь закрывает chunk stream
(`chunksContinuation.finish()`) и в ветке `guard isRunning else { ... }` — то есть
даже когда движок ещё не стартовал.

## Почему
Drop можно отпустить *во время* setup-окна сессии (JWT-handshake + factory +
WS-коннект), до того как `session.run()` вызвал `audioEngine.start()`. Тогда
`AppDelegate` применяет отложенный стоп → `session.stop()` → `audioEngine.finish()`
→ `stop()` с `isRunning == false`. Старый `guard isRunning else { return }` выходил
**не закрыв** chunk stream. Forward-loop сессии (`for await chunk in engine.chunks`)
никогда не завершался → `endInput()`/EOF не уходил провайдеру → провайдер ждал,
правое крыло крутилось, ничего не вставлялось до срабатывания stop-watchdog.
Окно тем шире, чем медленнее setup (высокий RTT / далёкий сервер), поэтому
короткий tap у удалённых пользователей чаще попадал в гонку — без всякого VPN.

## Что протестировали (гипотезы)
- **backend WS send/close-after-disconnect** — отдельный баг (зависание финала,
  кейс с появляющимся текстом). Зафикшен отдельно.
- **stop-before-run race** (этот) — подтверждён тестом
  `testStopBeforeStartFinishesChunkStream`: `stop()` без `start()`, затем
  `for await engine.chunks` — на RED висел (stream открыт) и падал по таймауту,
  на GREEN завершается мгновенно.

## Отвергли / осталось
- Полная координация `start`/`stop` (флаг «terminal», чтобы поздний `start()`
  после `stop()` не поднял мик) — не делали: фикс минимальный, а уход в этот путь
  рисковал route-change-restart (`restartAfterConfigurationChange`). Поздний старт
  после стопа существовал и до фикса; форвард-луп на закрытом stream завершается
  немедленно, и teardown сессии останавливает движок. Наблюдаем — если всплывёт
  кратковременный mic-leak, добавим terminal-флаг отдельным тестом.

---
2026-06-16 · ветка `fix/streaming-stop-before-run` · PR: <добавить после создания>
