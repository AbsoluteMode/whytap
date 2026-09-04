# The "Hide Hover and Music" eye keeps the compact music wing

## Контекст

Есть два музыкальных элемента острова:

- **Compact-крыло** (`IslandMusicWingView`) — лёгкий always-on индикатор «играет
  музыка» (обложка + эквалайзер + прогресс) в правой полосе;
- **Hover-виджет** (`IslandMusicStripView`) — плеер с обложкой и транспортом в
  зазоре МЕЖДУ компактным островом и hover-drawer.

«Глаз» (`IslandHideButton`, "Hide Hover and Music") через
`hideIslandHoverWidgets` занулял общий `visibleNowPlaying` → пропадали ОБА: и
hover-виджет, и compact-крыло. Максим: по «глазу» должен пропадать только
hover-виджет (плеер между островом и hover), а правое крыло — оставаться.

## Решение

Разделить источник Now Playing по поверхностям через чистый helper
`IslandMusicRouting`:

- `compactNowPlaying` = `compactWingNowPlaying(...)` — **eye-независимый**
  (всегда реальный playback); им питается compact-крыло (`IslandWrapRow`).
- `hoverNowPlaying` = `hoverWidgetNowPlaying(...)` — **eye-gated** (nil при
  включённом «глазе»); им питается hover-виджет и расчёт высоты drawer.

## Почему

Compact-крыло — постоянный индикатор состояния, прятать его «глазом» неверно.
Большой плеер-виджет — hover-поверхность, его «глаз» прячет (как и раскрытие
drawer). Вынос маршрутизации в `IslandMusicRouting` фиксирует инвариант
тестом, чтобы регрессия «глаз снова прячет крыло» не вернулась.

## Что протестировали

- Юнит `IslandMusicRouting`: compact игнорирует «глаз», hover-виджет скрывается
  «глазом» (4 кейса).
- Source-grep тест `test_hideButtonGatesHoverWidgetsButKeepsCompactMusicWing`
  обновлён под новый контракт (был `…GatesHoverAndMusicWidgets`).
- Полный `swift test` зелёный; визуально проверено в dev (подтверждено).

## Отвергли

- Прятать музыку, но без визуального дёрганья правого крыла — Максим выбрал
  «крыло остаётся видимым».
- Вообще не трогать музыку «глазом» — hover-виджет-плеер всё же должен прятаться.

---
2026-06-24 · ветка `claude/dazzling-dhawan-67728c` → main (squash)
