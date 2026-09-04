# Тумблер Settings для island idle-hide (opt-out)

**Дата:** 2026-07-09
**Где:** `Sources/Sidekey/DynamicIsland/IslandIdlePreferences.swift` (новый),
`IslandIdleController.swift`, `Sources/Sidekey/Settings/SettingsOtherView.swift`,
`Sources/Sidekey/AppDelegate.swift`

## Контекст

Island idle-hide (авто-скрытие острова в «голую чёлку» после ~20с простоя,
#497/#499) уехал юзерам в 1.17.1 **всегда включённым, без возможности
отключить** (CLAUDE.md: «Тумблера в Settings нет — v1 = константа»). Фидбек:
кого-то авто-скрытие отвлекает / не нравится, а opt-out'а не было. Контроллер
`IslandIdleController` уже был написан под будущий тумблер — принимает
`isEnabled: () -> Bool` замыкание и читает его живьём в
`reschedule()`/`evaluate()`.

## Решение

Тумблер «Auto-hide island» в Settings → Other (в группе Display, рядом с «Show
island on»). Дефолт ON — поведение 1.17.1 сохраняется для всех, тумблер только
даёт **выключить**.

- **`IslandIdlePreferences`** (зеркало `VolumeDuckConfig`): UserDefaults-ключ
  `com.sidekey.island.idleHideEnabled`, missing key = enabled. Сеттер постит
  `didChangeNotification` **только при реальной смене** значения (как
  `IslandScreenResolver.setPreferredDisplayUUID`) — без спурьёзных пиков.
- **`IslandIdleController.settingsDidChange()`**: сбрасывает `lastActivity = now`
  и `reschedule()`. Disable → `isEnabled()` veto в `evaluate()` немедленно даёт
  `.active` (скрытый остров поднимается сразу, без hover/хоткея); enable →
  свежее idle-окно (не схлопывается мгновенно по устаревшему якорю).
- **AppDelegate**: контроллер строится с
  `isEnabled: { islandIdlePreferences.isEnabled }`; подписка на
  `didChangeNotification` дёргает `controller.settingsDidChange()`.
- **SettingsOtherView**: строка-тумблер пишет прямо в инжектированный
  `IslandIdlePreferences` (как volume-duck), локальный `@State`-mirror
  перечитывается в `.onAppear` (гвард от stale при возврате на таб). Вью
  остаётся чистой: контроллер она не видит — развязка через
  UserDefaults + NotificationCenter.

## Почему

- Контроллер уже был спроектирован под это (`isEnabled`-замыкание) — работа
  свелась к preference + UI + проводке, движок не тронут.
- Развязка через нотификацию, а не прямая ссылка вью→контроллер: Settings-окно
  и остров живут независимо; тот же паттерн, что у display-picker.
- `settingsDidChange` сбрасывает окно (а не просто reschedule), потому что при
  enable старый `lastActivity` мог быть >timeout назад → мгновенный коллапс сразу
  после включения (плохой UX). Сброс даёт честный полный таймаут.
- Default ON: не менять поведение у существующих юзеров; тумблер — чистый
  opt-out.

## Что протестировали

- `IslandIdleControllerTests` (+2): disable при скрытом острове → мгновенно
  `.active`; re-enable → свежее окно (active, потом коллапс через полный
  таймаут). Виртуальные часы + fake scheduler.
- `IslandIdlePreferencesTests` (+4): default enabled; персист disabled; смена
  постит нотификацию; та же величина — не постит.
- `SettingsOtherViewTests` (+3, source-string): строка присутствует, биндится к
  инжектированным prefs, `.onAppear` перечитывает.
- Полный набор idle+settings: 42 passed. Сборка `Sidekey` зелёная.

## Отвергли

- **Слить флаг в `IslandIdleConfig`** (enum статических таймингов) — тип-миксин
  «константы + persisted-состояние»; отдельный `IslandIdlePreferences` чище и
  повторяет проверенный `VolumeDuckConfig`.
- **Только `reschedule()` без сброса `lastActivity`** — при enable схлопывало
  остров мгновенно по устаревшему якорю.
- **Прямая ссылка вью→контроллер** — связала бы Settings-окно с островом;
  нотификация развязывает (паттерн display-picker).

2026-07-09 · PR: см. ветку feat/island-idle-hide-toggle
