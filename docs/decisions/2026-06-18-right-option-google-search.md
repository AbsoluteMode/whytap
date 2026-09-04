# Right Option → Google Search

## Контекст

Нужен третий голос/жест-флоу рядом с Drop (hold Space → диктовка → paste) и Agent (R⌘ tap=текст / hold=голос → локальный CLI): быстрый Google-поиск голосом или текстом на **Right Option (R⌥)**, результат открывается в браузере по умолчанию. Изначально продиктовано как «Write Option» — распознано как «Right Option» (омофоны; R⌥ — симметричный близнец агентского R⌘).

## Решение

- **R⌥** (конфигурируемый, дефолт): tap → композер «Google it…» → Enter → браузер; hold → орб в цветах Google → голос → release → браузер; Escape → отмена.
- URL: `https://www.google.com/search?q=…` через `URLComponents` → `NSWorkspace.shared.open` (браузер по умолчанию, новая вкладка).
- Максимум переиспользования агентской инфраструктуры: обобщён `RightCmdGestureStateMachine` (диспетч agent/google), переиспользованы STT-сессия, композер острова, орб (новый `PaletteFlavor.google`).

## Почему

- **R⌥, а не новый combo:** единственный свободный правый модификатор, и `RightCmdGestureMonitor`/`startCandidate` уже детектил R⌥ — инфраструктура (state-machine, held-трекинг, conflict-модель, рекордер) была готова. Симметрия с агентским R⌘ (tap=текст, hold=голос) даёт предсказуемый UX.
- **Обобщить монитор, а не отдельный инстанс:** один CGEvent/NSEvent-монитор вместо двух (избегаем дубля event-tap'ов и гонок); state-machine логика (tap/hold/cancel) не тронута — добавлен лишь второй набор колбэков + `pendingAction`, agent-путь byte-for-byte идентичен.
- **Открытие URL в браузере, а не API-вызов:** `NSWorkspace.open(google.com/search)` — это открытие публичного URL в браузере пользователя, НЕ программный вызов Google API нашими ключами. Инвариант #2 (клиенты не зовут сторонние API напрямую) НЕ нарушается — нет ключей, нет сетевого вызова из процесса. Проще, надёжнее, кросс-браузерно, чем симуляция окна/ввода.
- **Флаг `activeSourceIsGoogle` ставится ПОСЛЕ смены фазы** (ORDER MATTERS в `AppDelegate.makeGoogleCallbacks`): `IslandAgentFlowStore.recompute()` сбрасывает флаг в `.textInputActive`/`.voiceRecording` ветках — это leak-guard, чтобы прошлая google-сессия не протекла палитрой/плейсхолдером в агентский композер. Поэтому google-путь сначала гонит фазу (recompute чистит), потом ставит флаг — он переживает до submit/записи. Проверено, что `recompute()` для google-пути срабатывает только на смене фазы (composingTextChanged не зовёт recompute; google voice-сессия не подключает transcriptUpdated), поэтому одного set-после достаточно.
- **Голосовой транскрипт — `trim` без LLM-cleanup:** поиск терпим к «сырому» тексту, без cleanup быстрее.

## Что протестировали

- Жест-роутинг: R⌥ → google-колбэки, R⌘ → agent (16 существующих agent-тестов монитора зелёные + 2 новых routing-теста; dual-purpose tap/hold симметричен агенту).
- URL-кодирование: ASCII, кириллица, пробелы, спецсимволы (`&`→`%26`; `?` остаётся литералом — `URLComponents` так и делает в query, валидно по RFC 3986).
- Пустой/whitespace запрос → `make` возвращает nil → браузер не открывается.
- Регресс на ordering-баг: `handleTextSubmit` при `activeSourceIsGoogle=true` роутит в google-замыкание, не в агента (тест падает при отключённой ветке — доказано).
- Орб: `.googleVoice`/`.googleTextInputActive` → `.google` палитра; gradientRing параметризован палитрой (Google-кольцо при text-input).

## Отвергли

- **Строго новое окно браузера** — поведение зависит от браузера, хрупко; достаточно открыть результаты во вкладке.
- **Удалить reset флага из recompute** (вместо ordering-фикса) — вернуло бы риск протечки google-палитры в агентский композер.
- **Симуляция ввода+Enter в браузере** — не нужно, прямой URL на страницу результатов.
- **Выбор поисковика** — зафиксирован Google (возможное будущее).
- **Threading google-режима в `FloatingDotPanel`/`DotView`** — это dead code (не инстанцируется в проде; остров — универсальная orb-поверхность для всех экранов).
- **Лого источника в орбе (Codex/Claude Code/Google)** — вынесено в отдельную фичу B (следующий PR).

---
2026-06-18 · ветка `claude/modest-leakey-3e34c2` · спек+план в `docs/superpowers/`

## Follow-up (2026-06-19): орб не появлялся при голосовом Google

**Контекст.** Голосовой Google-жест (R⌥ hold) писал звук и открывал браузер, но орб записи в острове НЕ появлялся — в отличие от агентского голоса (R⌘ hold), где орб появляется и «дышит».

**Почему.** `startGoogleRecordingUI()` звал только `setAgentPhase(.voiceRecording)`. Агентский `handleHoldStart()` дополнительно делает `responseStore.reset()` + `responseStore.markLocalStatus(.recording)` (+ `state = .voiceRecording`). Именно `markLocalStatus(.recording)` дёргает sink flow-store'а по `responseStore.objectWillChange`, который перерисовывает recording-поверхность орба. Без него орб не появлялся, а `state` оставался `.idle`.

**Решение.** Паритет ТОЛЬКО по UI-состоянию: `reset` + `markLocalStatus(.recording)` + phase + `state`. Агентскую телеметрию/snapshot/voice-session НЕ копировали — Google-флоу ведёт `GoogleSearchController`, наша инфраструктура в его data/credential-path не участвует.

**Что протестировали.**
- `markLocalStatus`/`reset` фаерят `objectWillChange`, а sink доставляется асинхронно (`.receive(on: DispatchQueue.main)`). Проверено: поздний `recompute()` из этого sink НЕ затирает `activeSourceIsGoogle`, т.к. флаг выставляется вызывающим (`onHoldStart`) ПОСЛЕ фазы — ordering из основного фикса сохранён. Тест ждёт прогон sink и ассертит, что флаг выжил и орб резолвится в `.googleVoice`.
- Утечка `state`: `startGoogleRecordingUI()` теперь ставит `state = .voiceRecording`, но `endGoogleUI()` его не сбрасывал → следующий агентский voice-tap маршрутизировался в `.stopVoiceCapture` (toggle-stop) вместо старта. Починили: `endGoogleUI()` сбрасывает `state = .idle` (зеркало агентских teardown-путей). Покрыто отдельным тестом.

**Отвергли.**
- **Дёргать sink/recompute синхронно** — не трогали Combine-доставку; ordering caller'а уже решает гонку флага.
- **Звать весь `handleHoldStart()` из Google-пути** — притащил бы агентскую сессию/телеметрию/snapshot, нарушив изоляцию Google-флоу.

2026-06-19 · ветка `feat/voice-source-logos`
