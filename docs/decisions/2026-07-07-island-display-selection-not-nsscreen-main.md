# Выбор экрана острова: primary/notch/пикер вместо NSScreen.main

**Дата:** 2026-07-07
**Где:** `Sources/Sidekey/DynamicIsland/IslandScreenResolver.swift` (`selectDescriptor` без `mainDescriptor`, `selectionDidChangeNotification`, `currentVisibleFrame()`, `IslandScreenCache.rebuild(descriptors:)`), все overlay-панели (island, notification, meeting pill, orb, hint, history strip/expanded, copied toast, share-data modal), `Sources/Sidekey/Settings/DisplayPickerViewModel.swift` + row «Show island on» в Settings → Other. Тесты: `IslandScreenResolverTests`, `IslandIdleWakeZoneTests`, `DisplayPickerViewModelTests`.

## Контекст

Фидбек тестера (два монитора: Mac mini + 2 внешних, либо MacBook + внешний): пилюля острова появляется «не на том» мониторе и перепрыгивает с экрана на экран, «когда что-то делаешь»; навести мышь невозможно — остров убегает из-под курсора. Поведение давнее (билд до idle-hide #497), не регрессия.

Трасса бага: `IslandScreenCache.selectedDescriptor` подставлял **live `NSScreen.main`** в `selectDescriptor` с приоритетом выше чёлки и primary. `NSScreen.main` в AppKit — экран **key window** (клавиатурного фокуса), а не «основной монитор»: на 2+ мониторах он меняется при каждом клике в окно на другом экране. Layout острова пересчитывается на десятках событий (hover, wake, agent, notification, idle) и каждый `computeLayout()` ре-резолвил экран заново → `setFrame` на экран фокуса ровно в момент взаимодействия. Отсюда «остров убегает»: hover будит пересчёт, пересчёт перевозит окно на экран, где юзер только что кликал. Той же болезнью страдали панели-отщепенцы, позиционировавшиеся от сырого `NSScreen.main?.visibleFrame` (orb, hint chip, share-data modal, history strip/expanded, copied toast).

## Решение

1. **`selectDescriptor(preferredUUID:descriptors:)`** — чистая функция, `NSScreen.main` не участвует нигде. Порядок: preferred UUID юзера (если подключён) → экран с реальной чёлкой → **primary-дисплей** (`frame.contains(NSPoint.zero)` — экран с глобальным origin/menu bar; предикат тот же, что в `SidekeyWindowChrome.primaryVisibleFrame`) → первый → fallback. Параметр `mainDescriptor` удалён из сигнатуры — независимость от фокуса гарантирована на уровне компиляции для всех call-site'ов.
2. **Все панели идут через резолвер**: hot-path'ы острова уже шли через `currentDescriptor()` и починились сами; отщепенцы переведены на `IslandScreenResolver.currentVisibleFrame()` (чистые NSRect-overload'ы геометрии сохранены/добавлены, мёртвые screen-based overload'ы удалены).
3. **Пикер** Settings → Other → «Show island on» (`DisplayPickerViewModel`, `MacPopup<String?>`): Automatic (nil) + подключённые дисплеи по `localizedName` (дубли — суффикс « (2)»). Ключ `sidekey.dynamicIsland.preferredDisplayUUID` существовал и раньше, но его никто не писал — ветка была мёртвой; теперь это рабочий приоритет №1. Отвал выбранного монитора **не стирает** выбор: UI показывает Automatic, при возврате дисплея выбор снова активен.
4. **Живое применение**: `setPreferredDisplayUUID` постит `selectionDidChangeNotification` (только при реальной смене значения — повторный выбор того же пункта не дёргает панели); все девять overlay-панелей подписаны на неё тем же селектором, что и на `didChangeScreenParametersNotification`, — смена в Settings переезжает мгновенно, без hardware-события.

## Почему

- Класс бага закрыт по конструкции, а не по условию: в выборе экрана больше нет ни одного источника, зависящего от фокуса. `computeLayout()` детерминирован и идемпотентен — окно двигается только на реальную смену конфигурации дисплеев или явный выбор юзера.
- Wake-зона idle-hide (#497) автоматически всегда на экране пилюли: она выводится из `computeLayout().compactFrame`, который больше не мигрирует.
- Primary-предикат (`contains(.zero)`) уже был кодифицирован в `SidekeyWindowChrome` — переиспользован, а не изобретён.
- `FloatingDotPanel.currentDisplayID` оставлен на `panel.screen ?? NSScreen.main`: люминанс-диагностика хочет РЕАЛЬНЫЙ экран панели, это не позиционирование.

## Что протестировали

- `IslandScreenResolverTests` (переписаны, 9): primary при трёх экранах без чёлки независимо от порядка descriptors; чёлка бьёт primary; clamshell; preferred бьёт всё; отвал preferred → automatic-цепочка; возврат preferred; пустой список → fallback; остров и meeting-suggestion на одном снапшоте экрана; `IslandScreenCache.rebuild(descriptors:)` end-to-end без NSScreen.
- `IslandIdleWakeZoneTests` (+1): двухэкранная фикстура — wake-зона целиком в полосе выбранного экрана и не пересекает второй.
- `DisplayPickerViewModelTests` (новые, 5): options/дедупликация имён; запись ключа + нотификация ровно один раз; повторный выбор — без нотификации; Automatic удаляет ключ; disconnect держит ключ, reconnect возвращает выбор.
- Ручной QA на двух мониторах — см. чеклист в PR.

## Отвергли

- **Оставить `NSScreen.main` как приоритет с дебаунсом/кэшем** — лечит симптом (частоту прыжков), не причину; остров всё равно уезжал бы за фокусом, просто реже.
- **Гейтить пересчёт layout'а (не ре-резолвить экран на hover)** — трогает hot-path'ы `IslandPanel` и оставляет гниль в резолвере; любой новый call-site воспроизводил бы баг.
- **`NSScreen.screens.first` как «primary»** — прямо не гарантирован AppKit'ом как primary; надёжный предикат — `frame.contains(.zero)` (origin глобальной системы координат по определению на primary).
- **Следовать за фокусом «умно» (например, только при долгом фокусе)** — противоречит ментальной модели «остров живёт у чёлки/на выбранном экране»; непредсказуемость и была жалобой.

---
2026-07-07 · ветка `fix/island-multimonitor-anchor` · спека-дизайн в задаче (основная сессия), предыстория idle-hide: `docs/specs/island-idle-auto-hide.md`
