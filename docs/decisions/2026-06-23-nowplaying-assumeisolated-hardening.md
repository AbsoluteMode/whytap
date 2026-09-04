# NowPlaying poll timer: Task hop instead of MainActor.assumeIsolated

**Дата:** 2026-06-23
**Где:** `Sources/Sidekey/NowPlaying/NowPlayingController.swift` (`scheduleTimer`).

## Контекст

Прод-краш на 1.13.0/build1406 (macOS 27 бета), 2026-06-23 00:56: **EXC_BAD_ACCESS** (KERN_INVALID_ADDRESS at 0x1e) на main-треде. Стек: `NowPlayingController.scheduleTimer` closure → `MainActor.assumeIsolated` → `swift_task_isCurrentExecutor` → `swift_getObjectType` → `objc_opt_class` (near-null). Код `Timer + assumeIsolated` не менялся с 1.9.0 (#330) — триггер = рантайм беты macOS 27. См. [[project_sidekey_macos27_nowplaying_crash]].

## Решение

В `scheduleTimer` заменить `MainActor.assumeIsolated { self?.poll() }` (в callback'е `Timer` на `RunLoop.main`) на `Task { @MainActor in self?.poll() }`.

## Почему

`assumeIsolated` делает СИНХРОННУЮ проверку текущего executor'а (`swift_task_isCurrentExecutor`), которая на бете macOS 27 интермиттентно разыменовывает мусор при вызове из CFRunLoop-таймера (не-task контекст на main-треде). `Task { @MainActor in }` ставит job в очередь main-executor'а штатным путём рантайма — без этой bare-thread-проверки, т.е. **убирает именно упавший кадр**. Это hardening в обход грабли беты (на свежей репро-проверке голый паттерн `assumeIsolated`-из-Timer НЕ падает → краш интермиттентный), а не строго репро-проверенный фикс; но он структурно исключает место краша.

Async-hop (poll на следующем витке main) безвреден: это поллинг-таймер. **Тесты не затронуты:** test-seam зовёт `poll()` напрямую, callback `Timer` в тестах не исполняется.

## Что протестировали

`swift test` — вся свита зелёная (поведение поллинга не изменилось; тесты идут мимо Timer-callback'а).

## Отвергли

- **Парсить .ips локально для символикации** — требует Full Disk Access (отдельный пермишен); вместо этого построили MetricKit-телеметрию ([[project_sidekey_macos27_nowplaying_crash]]).
- **Трогать `scheduleCatchUp`** (тот же `assumeIsolated`-паттерн) — НЕ в этом фиксе: он идёт через инъектируемый `scheduler` (тест-дубль ждёт синхронный poll → Task сломал бы тесты), срабатывает редко (только на transport-команду, не в постоянном поллинге) и не падал. Если упадёт — поймает крэш-телеметрия, чиним тогда.
- **Откатить 1.13.0** — код NowPlaying идентичен с 1.9.0; откат не помог бы (краш от беты ОС, не от релиза).

## Хвост

Парный CheckedContinuation-краш (01:42) — [[2026-06-23-websocket-ping-double-resume]]. Оба + крэш-телеметрия едут в 1.13.1.

---
PR: TBD · ветка `fix/macos27-crash-fixes-1.13.1`
