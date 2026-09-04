# Now Playing в Dynamic Island: полировка виджета (прогресс, зазор, стекло, отступы, hover)

## Контекст

Коллега добавил Now Playing music в Dynamic Island ([#330](https://github.com/rootwise-team/sidekey/pull/330)). При ручном тестировании всплыла серия проблем виджета:

1. **Прогресс-бар трека не двигается** — заполняется только когда жмёшь Паузу.
2. **Плеер и hover-меню налезают** друг на друга.
3. **Плеер и меню разного цвета** — разное Liquid Glass стекло.
4. **Неравные отступы** — остров→плеер ≠ плеер→меню.
5. **Hover transport-кнопок мигает** — то подсвечивается, то нет.

## Решение

1. **Прогресс:** `NowPlayingSnapshot.progressFraction(at:)` экстраполирует `elapsed + (isPlaying ? Δt : 0)` от `capturedAt`; wing рисует через `TimelineView(.periodic)`.
2. **Раздельные карточки:** `musicStripBottomGap = 8pt` между плеером и меню (по выбору Максима — НЕ единый фрейм).
3. **Стекло:** детерминированная база `IslandDetachedHoverPanelBackground.glassBase` (`.ultraThinMaterial` + фиксированный `.black.opacity(0.25)`) вместо адаптивного `.glassEffect`.
4. **Равные отступы:** `musicStripTopGap = musicStripBottomGap = 8` (симметрия остров→плеер→меню).
5. **Hover:** геометрический, как клики — `IslandMusicStripHitZone.transportButton(at:)` на mouseMoved → `AppState.hoveredMusicTransport` → подсветка в strip (вместо SwiftUI `.onHover`).

## Почему

### Прогресс (вариант B — экстраполяция в UI)

MediaRemote-источник **push-based**: шлёт снапшот только на событиях плеера. `currentElapsedSeconds(now:)` умеет экстраполировать, но её звали один раз — в момент события (`Δt ≈ 0`), а `currentSnapshot()` отдавал кэш как есть. Контроллер поллит 1s, но получал тот же замороженный снапшот → бар стоял; транспортная команда давала свежее событие → бар прыгал («оживает на Паузу»). Поле `capturedAt` было добавлено в #330 именно под render-time экстраполяцию — вариант B замыкает связку. `.periodic` (не `.animation`) — бар информативный, должен ползти и при Reduce Motion.

### Зазор + равные отступы (раздельные карточки)

Плеер и меню — два отдельных стеклянных surface в `VStack(spacing: 0)` без зазора; их скругления в стыке конфликтовали («налезают»). Максим выбрал раздельные карточки. Зазор 8pt разносит их; `activeHoverPanelHeight` растёт на `stripHeight + bottomGap`, из `panel.frame` вычитается та же сумма → меню сохраняет полную высоту (контролам нужно ≥145pt). Верхний отступ выровнен на тот же 8pt (`= detachedPanelGap`), чтобы плеер стоял симметрично между островом и меню; band от `topGap` не зависит (его поглощает panel).

### Стекло (детерминированная база)

macOS 26 `.glassEffect(.regular)` — **адаптивный** эффект: тинтит каждую поверхность от её собственного фона. Плеер и меню — два инстанса `IslandDetachedHoverPanelBackground` → на светлом фоне плеер выходил светлым, меню тёмным. Фиксированный wash над `.ultraThinMaterial` (как уже сделано в `DarkGlassCard`) даёт одинаковый тон на любых обоях и в любой позиции. Бонус: уходит Tahoe-only символ `.glassEffect`, который не компилируется на CI Xcode (см. коммент в `DarkGlassCard`). Polish-слои (specular/lens/rim) остались — «стеклянность» на месте.

### Hover (геометрический, как клики)

SwiftUI `.onHover` теряет mouseEntered/Exited в non-activating панели с динамическим `ignoresMouseEvents` — та же причина, по которой transport-КЛИКИ уже диспатчатся геометрически в `sendEvent`. Решение: на mouseMoved окно резолвит кнопку под курсором через `transportButton(at:)` (те же `transportButtonRects`, что и клики — рассинхрон невозможен) и публикует в `AppState.hoveredMusicTransport`; strip подсвечивает по нему. Курсор конвертируется screen→window (host заполняет окно).

## Что протестировали

TDD RED→GREEN везде:
- **Прогресс:** 5 тестов `progressFraction(at:)` (экстраполяция play, заморозка pause, clamp, нулевая длительность, защита от обратного хода). RED — падали 2 по правильной причине.
- **Зазор:** `test_hoverGatedMusicStrip_growsHoverBandByStripHeightPlusGap` (band растёт на `stripHeight + bottomGap`). RED `42 ≠ 50`.
- **Hover:** 3 теста `transportButton(at:)` (центр каждой кнопки → та кнопка, вне → nil, live → только play/pause). RED — nil на заглушке.
- Старый Stage-1 контракт `progressFraction` сохранён (выражен через `progressFraction(at: capturedAt)`).
- Полный сьют зелёный (2887 тестов).

## Отвергли

- **Прогресс, вариант A** (пересчёт elapsed в `currentSnapshot()`) — рывки 1s, только MediaRemote.
- **Единый surface** плеер+меню — Максим хочет раздельно.
- **Стекло через `GlassEffectContainer`** (Apple-нативное согласование) — тот же Tahoe-only символ ломает CI; проект уже ушёл от `.glassEffect` в `DarkGlassCard`.
- **Hover через `acceptsMouseMovedEvents = true`** (вариант A) — не хватило в non-key панели, hover всё равно мигал → геометрический B.

---

Дата: 2026-06-16. PR: [sidekey#332](https://github.com/rootwise-team/sidekey/pull/332) (поверх [#330](https://github.com/rootwise-team/sidekey/pull/330)).
