# Композер агента: капсула растёт с текстом, потом скроллит хвост

## Контекст

Два бага в текстовом композере агента (`IslandAgentComposerPanel`, R-Cmd tap):

1. **Хвост не виден.** При наборе длинного запроса поле показывало первые
   символы, а каретку/конец — нет.
2. **Текст вылезал на обои.** Длинный текст рисовался правее чёрной капсулы
   острова, на рабочем столе.

## Решение

1. Поле — single-line `NSTextView` обёрнут в горизонтально-скроллящийся
   `NSScrollView` (`widthTracksTextView = false`, `isHorizontallyResizable`),
   `clipsToBounds` на clip-view. Каретка/хвост следуют за вводом.
2. Чёрная капсула (и поле) растут вместе с набираемым текстом от floor-плейсхолдера
   до `agentWingComposingWidth` (300), дальше поле скроллит хвост. Единый источник
   ширины — `IslandAgentWingView.composingFaceWidth(text:)`, который читают все трое:
   чёрный путь (`IslandView.activeWingFaceWidth`), хит-зона (`syncAgentSurfaces`) и
   позиция поля (`composingFieldWindowRect`). Живой текст течёт из панели в
   `IslandAgentFlowStore.composingText` по уже существующей реактивной проводке
   (`objectWillChange → syncAgentSurfaces`; IslandView наблюдает store).

## Почему

- **Корень бага #2 — расхождение ширин.** Чёрная капсула в composing мерилась по
  плейсхолдеру (~130pt) и не росла; поле было фикс 300pt. Всё за 130pt падало на
  прозрачную часть панели → на обои. Recording-режим уже растит чёрное под контент —
  composing просто выпал из паттерна (его `case composing` не несёт текст, текст живёт
  в отдельной панели). Доделали паттерн: один источник ширины для всех потребителей →
  дрейфа быть не может.
- **Геометрия — рост только вправо.** `wingRect.x = boundsSize.width -
  rightAgentZoneWidth` (константа), а floor капсулы (≥72, adaptiveWingFloor) >
  `agentWingInCapsuleWidth` (70). Значит на всём диапазоне 130→300 левый край поля
  фиксирован, растёт только правый — текст не сдвигается при наборе.
- **Анимация — snap на рост, spring на открытие.** Чёрное — CAShapeLayer со
  spring-морфом; поле (AppKit) ресайзится мгновенно. При spring чёрное отстаёт от
  поля → новый символ на миг оказывается за капсулой (мини-рецидив бага #2). Поэтому
  per-keystroke рост снапается (как acting: «snap so the black wing never lags behind
  the text»), а пустой композер открывается спрингом. Разделено через
  `wingSnapsWidth = acting || (composing && !composingText.isEmpty)`.

## Что протестировали

- **Offscreen-замер раскладки каретки** (выкинутый scratch-тест): старый конфиг
  (`widthTracksTextView=true`, без scroll view) клампит каретку на ширине контейнера
  (maxX=140) — хвост не существует в раскладке; scroll-обёртка (`widthTracksTextView
  =false`) раскладывает строку на полную ширину и `scrollRangeToVisible` двигает
  clip-view к хвосту (`documentVisibleRect.origin.x = 1787.5`). Подтвердило корень #1
  и что фикс работает offscreen в `swift test`.
- **Формула ширины** (`IslandAgentComposingFaceWidthTests`): floor на плейсхолдере для
  короткого текста, рост с текстом, кап на 300.
- **Store** (`IslandAgentFlowStoreTests`): `composingText` зеркалит набор, чистится при
  выходе из composing.
- **Хвост-скролл** (`IslandAgentComposerPanelTests`): длинный запрос скроллит хвост в
  видимую зону.
- Визуально на острове (dev-билд): рост + скролл + отсутствие спилла подтверждены.

## Отвергли

- **Чёрное фикс 300pt** — текст не вылезает, но пустой композер сразу широкий с пустым
  чёрным справа; теряется снаг-вид.
- **Сузить поле до ширины плейсхолдера** — чёрное снаг, но поле ~130pt, тесно набирать.
- **`case composing(text:)` (associated value)** — симметрично recording, но большой
  blast-radius по всем match-сайтам enum; взяли отдельное `@Published composingText`.
- **Spring на рост капсулы** — совпадает с прежним «smooth stretch», но чёрное отстаёт
  от мгновенного поля → текст мигает за капсулой. Снап надёжнее.

---
2026-06-15 · PR: TBD
