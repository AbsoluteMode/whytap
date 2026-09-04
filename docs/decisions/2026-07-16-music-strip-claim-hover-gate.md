# Music strip mouse-claim гейтится hover-expanded (как hitTest), не одним фактом трека

## Контекст

Баг-репорт: у пользователя с играющей музыкой область прямо под Dynamic Island
не прожимается — traffic lights окна macOS под островом не реагируют на клики.
У коллег (без музыки) всё работает.

Остров — перманентно agent-wide прозрачная оверлей-NSPanel (`isOpaque = false`)
на `.screenSaver` level; съеденный клик поэтому невидим для пользователя —
под курсором просто «ничего не происходит».
Клик-роутинг трёхслойный, и все слои обязаны использовать один предикат:

1. `refreshMouseEventRouting` (claim) — решает `ignoresMouseEvents` по
   членству курсора в списке rect'ов отрисованных поверхностей;
2. `ClickThroughHostingView.hitTest` / `acceptsEvent` — принимает событие;
3. `IslandPanel.sendEvent` — геометрический dispatch transport-кнопок.

Для музыкального strip'а (полоса всей ширины пилюли, 8–50px под ней —
`musicStripTopGap`/`musicStripHeight`) слои 2 и 3 гейтятся
`IslandMusicStripHitZone.isActive(musicStripActive && acceptsExpandedHitTesting)`
— strip рендерится только в hover-expanded. Слой 1 гейтился одним
`musicStripActive`.

## Решение

Гейт claim-слоя приведён к тому же предикату `IslandMusicStripHitZone.isActive`.
Сборка `activeFrames` вынесена из приватного метода панели в чистую
`IslandPanelMouseEventPolicy.activeFrames(...)` — per-surface гейтинг снова
юнит-тестируем (регрессия жила именно в нетестируемом инлайне).

## Почему

С играющим треком и компактным островом окно держало
`ignoresMouseEvents == false` над невидимой полосой strip'а; `hitTest` там
возвращал nil, и AppKit **съедал** событие вместо передачи окну ниже — ровно
механизм dead-zone бага из
[2026-06-16-island-mouse-dead-zone.md](2026-06-16-island-mouse-dead-zone.md).
Претензия claim'а обязана совпадать с тем, что hit-testing реально принимает.

Регрессия историческая: в #330 strip union шёл только в expanded-frame
(«the union goes onto the EXPANDED frame only»), выбор compact/expanded и был
hover-гейтом. При мерже #341 (переход на список per-rect frames) strip-ветка
переехала как `if musicStripActive { ... }` — hover-гейт потерялся. Ирония:
регрессию внёс сам фикс click-eating.

## Что протестировали

- Красный тест до фикса: компакт + трек → точка в strip band claim'ится
  (`test_musicStripBand_claimedOnlyWhileHoverExpanded`), зелёный после.
- Hover-expanded + трек → band claim'ится (транспорт продолжает получать клики).
- Полный сьют: 3859 тестов, 0 failures.
- Открытие strip'а не ломается: hover начинается с пилюли (компакт-rect
  claim'ится всегда вне idle-hide), expanded включает band синхронно с рендером.
- Независимое ревью Codex (GPT-5.6): root cause и фикс подтверждены
  («correct with caveats»), регрессий не найдено; по его замечанию усилен
  тест — asserts на состав `activeFrames` (membership-проверка курсора
  false-pass'ила: probe-точка strip'а лежит и внутри expanded-frame).

## Известный смежный разрыв (вне скоупа, pre-existing)

`acceptsExpandedHitTesting` держится raw `isHovering`-callback'ом, а
SwiftUI-рендер drawer'а гаснет при старте agent flow (`isHoverExpanded`
учитывает `agentFlow.isActive`). Агент, запущенный при наведённом курсоре,
оставляет expanded/strip claim по исчезнувшему drawer'у — «claim = rendered»
в этом окне нарушается ещё с до-фиксовых времён. Вынесено в отдельную задачу.

## Отвергли

- Разгейтить `sendEvent`-транспорт под компакт (band оставить активным) —
  клики по невидимым кнопкам, нарушает «claim = rendered».
- Убрать dedicated band и положиться на expanded-frame — on-device доказано в
  #330, что generic expanded rect не доставляет клики transport-кнопкам.
- Точечный инлайн-фикс без выноса в policy — гейт остаётся нетестируемым,
  как и была внесена регрессия #341.

2026-07-16 · ветка `claude/dynamic-island-clickable-area-a02b51`
