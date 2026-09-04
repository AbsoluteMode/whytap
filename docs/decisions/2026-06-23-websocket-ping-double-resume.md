# WebSocket keepalive ping: guard against CheckedContinuation double-resume

**Дата:** 2026-06-23
**Где:** `Sources/Sidekey/Notifications/WebSocketKeepalive.swift` (new), `RelayGitHubListener.swift`, `RelaySlackListener.swift`, `LinearWebSocketTransport.swift`.

## Контекст

Прод-краш на 1.13.0/build1406 (macOS 27 бета), 2026-06-23 01:42: **EXC_BREAKPOINT** → `_assertionFailure` → `CheckedContinuation.resume(returning:)`, resume из serial dispatch queue (`_dispatch_lane_serial_drain`). Кадры приложения = `<deduplicated_symbol>`. См. [[project_sidekey_macos27_nowplaying_crash]].

## Решение

Общий once-guarded мост `WebSocketKeepalive.ping(task)`: resume континуации **максимум один раз**, сколько бы раз ни дёрнулся handler. Три байт-идентичных `defaultPingSender` (Linear/Slack/GitHub) теперь делегируют ему. Ядро вынесено в `resumeOnce(_ register:)` — тестируемо без живого сокета.

## Почему (как опознали без dSYM)

Триангуляция (dSYM билда 1406 не сохранился — релиз собирался из удалённого worktree):
- **`<deduplicated_symbol>`** = линкеровский ICF слил байт-идентичный код. В проде ровно ТРИ идентичных `defaultPingSender`: `await withCheckedContinuation { task.sendPing { error in continuation.resume(returning: error) } }` → folded в один символ. Точно бьётся с крэш-кадром.
- **`resume(returning:)` в кадре краша = двойной resume** (утечка трапнула бы в deinit континуации, а не в resume).
- **serial dispatch queue** = delegate-очередь `URLSession`, на которой `sendPing` зовёт `pongReceiveHandler`.
- `URLSessionWebSocketTask.sendPing` **может дёрнуть handler больше одного раза** на teardown/cancel-гонке (pong + ошибка закрытия) → второй `continuation.resume` → трап. Бета macOS 27 (агрессивнее рвёт сокеты) повысила частоту.

Фикс — resume-once, потому что континуацию по контракту можно резюмить ровно раз; краш доказывает, что резюмнули дважды. Guard корректен независимо от точного механизма double-fire.

## Что протестировали

- `WebSocketKeepaliveTests`: handler фигачит 3 раза синхронно → resume один раз (первое значение), без трапа; async double-fire (pong + teardown) → берём первое. Без guard'а второй вызов уронил бы процесс (red=trap, green=pass).
- `swift test`: вся свита зелёная.

## Отвергли

- **Фикс по месту в каждом из 3** — дублирование (оно и породило 3 одинаковых бага); общий хелпер = single fix + DRY.
- **Таймаут на ping** — это про ZERO-fire (утечку), не про наш double-fire; отдельная забота.
- **Ждать символикацию** — dSYM билда 1406 не сохранился; триангуляция (ICF-dedup 3 идентичных + signature двойного resume из delegate-очереди) и так решающая.

## Хвост

NowPlaying assumeIsolated-краш (00:56, EXC_BAD_ACCESS) — отдельный фикс, [[2026-06-23-nowplaying-assumeisolated-hardening]]. Оба + крэш-телеметрия едут в 1.13.1.

---
PR: TBD · ветка `fix/macos27-crash-fixes-1.13.1`
