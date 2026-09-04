# Settings: Now Playing always-on + новый таб «Other»

## Контекст

Two чистки Settings, попрошенные Максимом:
1. Таб **«Now Playing»** держал тоггл включения музыкального виджета (дефолт-on) +
   тоггл volume-duck «Lower other audio while speaking» + CTA на Automation-разрешение.
2. Capability-флаги (Meetings / Google) после онбординга **не имели дома в Settings** —
   их некуда было включить/выключить (онбординг ставит, дальше никак).

## Решение

- **Now Playing → always-on.** Убран `guard config.isEnabled` в
  `NowPlayingCoordinator.start()` (координатор всегда поллит). Таб `.music`
  удалён, `SettingsNowPlayingView` удалён. `NowPlayingConfig.isEnabled`
  остаётся, но больше ничего не гейтит (vestigial).
- **Новый таб «Other»** (последний в списке табов) — `SettingsOtherView`:
  - «Lower other audio while speaking» (volume-duck, `VolumeDuckConfig`) —
    переехал сюда из удалённого Now Playing таба.
  - «Meeting Notes» on/off — capability-флаг `meetingsEnabled`.
  - «Google search» on/off — capability-флаг `googleEnabled`.
- **Automation-CTA выкинут.**

## Почему

- **Always-on музыка:** виджет безвреден и всегда полезен; тоггл был лишним
  кликом/вкладкой. Решение Максима.
- **Таб «Other»:** Meetings/Google нужен Settings-дом (вкл/выкл после онбординга).
  Консолидировать их + осиротевший (удалением Now Playing) volume-duck в один
  «Other» чище, чем размазывать по Account/прочим. Тогглы переиспользуют готовую
  capability-проводку: `SettingsOtherView` чистый (writes идут через инжектнутые
  `onMeetingsToggle`/`onGoogleToggle`), хост (`AppDelegate.configureOtherDeps` →
  `SettingsWindowController`) превращает флип в `UserPreferencesCache.setXEnabled`
  (постит `.sidekeyCapabilityFlagsChanged` → live arm/disarm) + `persistCapabilityFlags()`
  (backend PUT) — ровно паттерн онбординга.
- **Automation-CTA не нужен:** релевантен только на редком AppleScript-пути; на
  современном MediaRemote-пути (Максим: ничего не выдавал, музыка играет —
  значит MediaRemote) он бесполезен. Узкий кейс отказа покрывается on-demand
  промптом / System Settings.

## Что протестировали

- `swift build` чистый, `swift test` **3617 тестов, 0 провалов** (перепрогон
  поверх свежего main с чужим #453 SettingsModels — пересечения нет).
- **Staleness-баг тоггла пойман проверкой действием и пофикшен:** Meetings/Google
  сначала сидились из СТАТИЧНЫХ `initial*` и не перечитывались; SwiftUI
  пересоздаёт таб-вью при заходе → @State реинитился из устаревшего seed →
  переключил Meetings, ушёл/вернулся → показывал OFF (тоггл врал). Фикс: live
  getters `() -> Bool` + перечитка в `.onAppear` (как у volume-duck с
  `volumeDuckConfig.isEnabled`). Регресс-гард `test_onAppearReReadsLiveCapabilityState`.

## Отвергли

- Оставить тоггл Now Playing — лишний клик/вкладка.
- Meetings/Google в таб Account — Максим выбрал отдельный «Other».
- Volume-duck always-on — Максим хотел тоггл (в Other).
- Перенести Automation-CTA в Permissions — выкинули совсем (бесполезен на
  MediaRemote).

---

Дата: 2026-06-29 · ветка `feature/settings-other-tab` (off main `76df5c3`) ·
имплементация subagent-driven + verify-by-action
