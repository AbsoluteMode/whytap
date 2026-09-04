# Drop `.deliveryFailed`: сделать escapable + укрепить Retry

**Дата:** 2026-06-24
**Где:** `Sources/Sidekey/AppDelegate.swift` (роутинг Drop, `handleStreamingResult`, `retryPendingDelivery`), `Sources/Sidekey/DynamicIsland/IslandAgentFlowStore.swift` (комментарий стейта).

## Контекст

Юзер прислал скриншот: Dynamic Island намертво залип на `Couldn't deliver — offline` + кнопка Retry (терминальный стейт resilient-Drop `AppPhase.deliveryFailed`, «Task 7»). Симптомы: баннер не уходил, Retry не помогал, «появился внезапно», сеть — неясно. Диагностика (Claude + независимый проход Codex/GPT-5.x) вскрыла связку из 4 корней:

- **A — мышеловка.** Выход из `.deliveryFailed` только через *успешный* Retry или рестарт: hold-Space был `.noop` (`dropHotkeyPressedRoute` гейтил `phase == .idle`), новую диктовку начать нельзя, dismiss-кнопки нет, авто-ретрая по возврату сети нет. Комментарий в сторе обещал «next Drop turn clears it» — ложь.
- **C — Retry хрупкий.** `retryPendingDelivery` гасил `pendingRetryPCM` ДО запуска async-recovery → подвисшая/не-переarmившая recovery оставляла `pendingRetryPCM == nil` при фазе `.deliveryFailed` = вечный тихий no-op.
- **«появился внезапно».** Запоздавший async `.degraded` от `session.run()` (hard no-progress timeout) доходит до `.deliveryFailed` уже после того, как турн «в голове юзера» закончился.
- **D — текст врёт.** `Couldn't deliver — offline` хардкод; ставится при ЛЮБОМ терминальном сбое, включая провал paste (Accessibility), не только сеть. (Отложено, см. ниже.)

## Решение

- **A (escapable).** Новый `DropFlowRoute.discardFailedTakeAndStart`. `dropFlowRoute(.deliveryFailed)` отдаёт его (отделён от `.finishing`, который остаётся `.noop` — recovery в полёте не рвём). `dropHotkeyPressedRoute(.hold)` пускает `.idle || .deliveryFailed`. Хэндлер: `discardPendingRetry()` (гасит retained PCM + AX-таргет) + `.idle` + нормальный старт. Так `.deliveryFailed` больше не мышеловка: нажал Drop — начал заново; Retry остаётся способом ВОССТАНОВИТЬ прошлый дроп.
- **C (Retry robust).** Чистый гейт `shouldBeginRetry(inFlight:hasPendingAudio:)` + флаг `retryInFlight`. PCM НЕ гасится сразу — им владеет ИСХОД (success → `clearPendingRetry`; offline → `retainForRetry` держит). `.finishing` ставится СИНХРОННО, чтобы быстрый второй клик / свежий Drop видели in-flight фазу (`.noop`), не escapable-терминал — закрывает окно гонки «stale retry поверх нового турна».
- **B (defense-in-depth).** Guard `shouldApplyStreamingResult(resultGeneration:currentGeneration:)` в начале `handleStreamingResult` (до мутации session/phase/telemetry), generation протянут из `session.run()` через существующий `streamingSetupGeneration`. Stale-континуация (новый турн перехватил слот) дропается. Сейчас не воспроизводимо (run() резолвится один раз до `.deliveryFailed`, retry идёт по batch-HTTP), но `.discardFailedTakeAndStart` делает свежий турн достижимым прямо из терминала — guard страхует от будущих рефакторов.
- **Free-tier escape (фикс находки Codex).** `discardPendingRetry()` + `.idle` вынесены в НАЧАЛО `handleDropHotkeyRoute`, ДО drop-budget pre-check: иначе бюджет-блок возвращался рано с живым `.deliveryFailed`, а limit-pill подавлялся под крылом → тихая ловушка. Теперь баннер гасится всегда, даже если новую запись бюджет не пустил.
- **Leak-fix (фикс находки Codex).** Раз PCM не гасится сразу, ветки retry-исхода `no-audio/empty/unauthorized` идлят фазу без `clearPendingRetry` → захваченное аудио висело бы в памяти. Хвост retry-Task'а дропает take, если исход не переarmил `.deliveryFailed`.

## Почему

Корень «залага» — состояние-ловушка, легко войти (любой offline/throttle при доставке), тяжело выйти. Самый дешёвый и дискаверабельный выход — «нажми Drop ещё раз»: zero new UI, естественно. `.finishing`-синхронность и `retryInFlight` нужны именно потому, что A делает конкурентный «старый retry vs новый турн» достижимым. Generation-guard — гигиена применения async-результата (в этом коде уже есть симметричный `streamingSetupGeneration` для setup-окна).

## Что протестировали

- TDD red→green по каждому корню: 53 теста в `AppDelegateDropFlowRouteTests` (роутинг escapable, хэндлер, budget-escape ordering, retry-gate, синхронный `.finishing`, leak-fix, generation-guard predicate + wiring). Чистые предикаты — поведенчески; AppDelegate-side effects — source-inspection (идиома этого файла).
- `swift test`: 3389 тестов, 0 провалов.
- Два состязательных прохода Codex: первый нашёл free-tier trap + leak + переоценил stale-clobber как HIGH (опровергнуто: не воспроизводимо сейчас); второй — вердикт SHIP, оба целевых фикса подтверждены.

## Отвергли

- **Авто-ретрай по возврату сети (`NWPathMonitor`).** Вставит текст в уже-другое поле спустя время — плохой UX; «нажми Drop заново» + ручной Retry достаточно.
- **Кнопка ✕ на крыле.** Лишняя hit-зона в острове с историей «проглатывания кликов»; press-to-supersede закрывает мышеловку без нового UI.
- **D (честный текст offline vs paste-blocked).** Требует протянуть reason через чистый резолвер + ~14 ассертов — ортогонально concurrency-фиксу, отдельным PR.
- **App-level timeout на batch-recovery (находка Codex #3).** Pre-existing; `.finishing` ограничен `timeoutIntervalForRequest` (но `forResource` дефолт 7д — стрим тела может держать дольше) → отдельным PR с аккуратным таймаутом, чтобы не рубить легит-транскрибацию.

Ветка: `claude/heuristic-jepsen-e33474`. Диагностика: память [[project_sidekey_drop_vpn_proxy_truncation]], [[project_sidekey_drop_silent_death_rca]].
