# Notch-оверлеи не появляются поверх чужого fullscreen

## Контекст

Поле ввода для text agent (R-Cmd tap) и text Google (R-Option tap) не
появлялось, когда фронтовое приложение — браузер Dia (Chromium) — было в
нативном fullscreen. В оконном режиме Dia всё работало. Поверх fullscreen
терминала (Claude Code) — тоже работало. То есть баг был специфичен для
fullscreen Chromium-браузера.

## Решение

Добавить `NSWindowCollectionBehavior.canJoinAllApplications` (macOS 13+) в
`collectionBehavior` всех notch-оверлеев, которые живут на уровне
`.screenSaver`:

- `IslandAgentComposerPanel` (поле ввода)
- `IslandPanel` (остров — фон-капсула, к которой привязана геометрия поля)
- `IslandNotificationPanel` (уведомления в острове)
- `MeetingPillView` (пилл записи митинга)

## Почему

Появление окна в fullscreen-Space ЧУЖОГО приложения зависит от пары
(window level, collectionBehavior), а не от одного флага:

- На **низком** уровне `.statusBar` (25) достаточно `.canJoinAllSpaces` —
  окно влезает в чужой fullscreen-Space. Это доказывает `HistoryStripPanel`
  и все панели на `.statusBar`: они видны поверх Dia fullscreen без
  дополнительных флагов.
- На **высоком** уровне `.screenSaver` (1000) — который notch-оверлеям нужен,
  чтобы перекрывать системный menu bar в обычном режиме (`.statusBar` на
  macOS 14+ оказывается ПОД menu bar, см. комментарий в `IslandPanel`) —
  `.canJoinAllSpaces` уже НЕ достаточно. Без `.canJoinAllApplications` окно
  не присоединяется к fullscreen-Space другого приложения.

Заголовок AppKit SDK дословно описывает наш случай:
`NSWindowCollectionBehaviorCanJoinAllApplications` — "allowing it to join
other apps' sets and **full screen spaces** when eligible. This collection
behavior should commonly be used for floating windows and **system overlays**."
Доступен с macOS 13.0; deployment floor проекта — macOS 14.2, поэтому без
`@available`-guard. Флаг взаимоисключающий только с `.primary`/`.auxiliary`
(их в коде нет) — конфликта нет.

Почему Claude Code (терминал) в fullscreen работал без фикса: вероятно его
fullscreen — maximized-окно в обычном Space, а не нативный fullscreen-Space.
Это вторично — фикс от этого не зависит.

## Что протестировали

- **Codex (независимый проход):** дал гипотезу «не хватает
  `.canJoinAllApplications`», но не объяснил, почему `HistoryStripPanel`
  работает без этого флага.
- **Корреляция уровней (опровержение «дело в collectionBehavior»):** свёл
  все оверлеи по window level. ВСЕ на `.statusBar` (history strip/expanded,
  toast, orb actions, floating dot, keybindings hint) видны поверх чужого
  fullscreen; ВСЕ на `.screenSaver` (остров, композер, notification, meeting
  pill) — нет. collectionBehavior у обеих групп идентичен — значит граница
  проходит ровно по уровню. Это и объясняет «history норм работает».
- **Проверка API действием:** формулировка и `API_AVAILABLE(macos(13.0))`
  взяты прямо из `NSWindow.h` в SDK, не со слов Codex.
- **На машине:** до фикса при R-Cmd в Dia fullscreen у нотча «совсем ничего»;
  dev-build с фиксом → остров и поле ввода появляются. Подтверждено
  пользователем.

## Отвергли

- **Понизить уровень острова до `.statusBar`** — сломает обычный режим: на
  macOS 14+ menu bar рендерится выше `.statusBar` и перекроет остров.
- **`NSApp.activate` при показе композера** — выбрасывает приложение из
  чужого fullscreen-Space (намеренно избегается, см. комментарий в
  `IslandAgentComposerPanel.show`).
- **Динамически ронять уровень в зависимости от fullscreen-состояния
  фронта** — сложнее и не нужно: один флаг закрывает проблему.

---
2026-06-24 · PR: TBD
