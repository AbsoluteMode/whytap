# Bare-Escape close агента: Carbon-хоткей только при видимой панели ответа

**Дата:** 2026-06-24
**Где:** `Sources/Sidekey/Agent/AgentController.swift` (подписка `escapeCloseLifecycleCancellable`); комментарии в `IslandAgentFlowStore.swift` / `CarbonHotkeyMonitor.swift` / `AgentResponseCloseHotkey.swift`; тесты `AgentControllerStreamingTests` / `IslandAgentFlowStoreTests`.

## Контекст

Симптом: whytap глобально перехватывает Escape — клавиша перестаёт работать в других приложениях. Со слов пользователя — «снова» (повторный заход бага), «проходит само через время», к конкретному действию на глаз не привязывается.

Root cause: `CarbonEscapeCloseHotkey` вешает голый Escape (`kVK_Escape`, без модификаторов) через Carbon `RegisterEventHotKey` — а такой хоткей забирает клавишу у всей системы, перед frontmost-приложением (тот же механизм, что у bare-key Carbon Drop, см. инвариант #6 в `CLAUDE.md`). Регистрация гейтилась `answerPanelVisible || agentActing`. Флаг `agentActing = (wing == .acting && phase != .idle)` держится весь период исполнения агента, включая фазу «думания» ДО появления панели ответа. Итог: пока агент работает (особенно если завис — agent-watchdog'а нет, см. [[project_sidekey_agent_hang_rca]]), Escape глобально перехвачен. Когда турн дозавершается → `agentActing=false` → Escape отпускает («само через время»).

Регрессия: `combineLatest($answerPanelVisible, $agentActing)` пришёл с `b2429b8` (#408 Drop resilient delivery), но захват во время `.acting` существовал и раньше (прежнее условие `wing == .acting`). #408 сузил его (убрал Drop), но окно executing у агента осталось.

## Решение

Регистрировать bare-Escape Carbon-хоткей **только пока видна панель ответа** (`answerPanelVisible`). `agentActing` убран из условия регистрации; сам флаг остаётся как ownership-marker (брендинг/UI острова), но Escape больше не драйвит.

## Почему

- Глобальный захват Escape во время невидимой фазы «думания» агента и есть корень бага: пользователь ушёл в другое приложение, ждёт ответа, а Escape там не работает.
- При зависании агента панель ответа может не появиться вовсе → старое условие держало Escape перехваченным неограниченно. Привязка к `answerPanelVisible` исключает это в корне: нет видимого UI — нет захвата.
- Escape как guaranteed-close осмыслен ровно тогда, когда есть видимый ответ, который он закрывает. До панели закрывать нечего.
- Recording (R-Cmd cancel-path) и composing (`onExitCommand` в текстовом поле key-window) Escape и так держат локально — эти фазы фиксом не затронуты (`agentActing` там был false).

Компромисс: в окне «executing до первого токена / permission / ошибки» Escape больше не отменяет турн (уходит в активное приложение). Для локального CLI окно — пара секунд, после чего панель видна и Escape снова закрывает. Принудительная отмена доступна через ✕ в острове.

## Что протестировали

- Инвертирован регрессионный тест в `AgentControllerStreamingTests`: `.acting` без панели (`answerPanelVisible == false`) → Escape-хоткей `startCalls == 0` (было `== 1`). Кодифицирует новое поведение и ловит откат.
- `IslandAgentFlowStoreTests`: `agentActing` остаётся корректным маркером (Drop `.finishing`/`.verifying` → false; agent `.executing` → true) — обновлены только формулировки, логика та же.
- `swift test` — вся свита зелёная.
- Подтверждено, что остальные подозреваемые чисты: `SpaceHoldMonitor` глотает Escape только в `.armed` (активная запись), `RightCmdGestureMonitor` Escape пропускает (`.passThrough`).

## Отвергли

- **Сохранить отмену по Escape во время executing, но снимать захват по watchdog/таймауту** — сложнее и упирается в отсутствующий agent-watchdog ([[project_sidekey_agent_hang_rca]]); глобальный захват Escape вне видимого UI остаётся плохим UX даже с таймаутом.
- **Оставить как есть** — это и есть баг.

## Хвост

Диагностика — независимый проход Codex (`codex:rescue`) + ручная верификация Claude; сошлись на одном root cause. Самоотчёт Codex недосчитал объём правок (заявил 2 файла, реально 6 — но «лишние» 4 = комментарии + тесты, логика не задета); проверено `git diff`.

---
PR: TBD · ветка `claude/quirky-tu-3ca1df`
