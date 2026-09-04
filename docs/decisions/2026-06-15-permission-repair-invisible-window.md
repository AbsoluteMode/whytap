# Permission-repair окно было невидимым (прозрачное окно без opaque-фона)

## Контекст
После PR #325 (permission-recovery) у Максима и тестеров «пропал онбординг»: при старте прод-сборки с отозванным Accessibility приложение показывало Dock-иконку, но окна не было, а клик по иконке ничего не открывал. Симптом изначально смешали с другим — «не работает drop» — который оказался backend 526 (потерянный nginx vhost `api.whytap.ai`, см. sidekey-backend#199) и к окну отношения не имел.

## Решение
`PermissionRepairView` теперь красит непрозрачный фон edge-to-edge: `.background(OnboardingTheme.bg.ignoresSafeArea())` + `.frame(maxWidth/maxHeight: .infinity)`. Регрессию закрывает source-contains тест `PermissionRepairViewTests` (та же конвенция, что `OnboardingWindowControllerTests`).

## Почему
`SidekeyWindowChrome.configure` делает окно прозрачным (`backgroundColor = .clear`, `isOpaque = false`, `hasShadow = false`) — это общий frameless-вид Settings/онбординга. Видимым окно делает ТОЛЬКО непрозрачный фон, который рисует сам контент. Каждый онбординг-экран это делает (`.background(OnboardingTheme.bg)`); новый repair-экран — нет. Итог: окно создаётся, ордерится вперёд, app промоутится в `.regular` (отсюда Dock-иконка), но контент прозрачный → «окна нет». Все три симптома Максима — один механизм: нет фона (не видно), `.regular` (иконка есть), невидимое key-окно уже открыто и нет `applicationShouldHandleReopen` (клик по иконке пустой).

## Что протестировали
- Гипотеза «контроллер деаллоцируется» → опровергнута: `permissionRepairWindowController` удерживается свойством (`AppDelegate.swift:206`).
- Гипотеза «repair не промоутит в `.regular`, в отличие от онбординга» → опровергнута: `presentPermissionRepair` зовёт `beginOnboardingDockActivation()` (`.regular`).
- `log show` за прошлый час пуст — info-логи вытесняются из store / прод не стартовал в окне; корень нашёлся чтением кода, не логами.
- Подтверждено: `OnboardingTheme.bg` непрозрачен (`Color(red:0.047,0.047,0.063)`), а палитра `MacSettingsTheme` полупрозрачна (рассчитана лежать на материале).
- Коллега онбординг НЕ ломал: его `OnboardingLanguageScreen` фон имеет.

## Отвергли
- Откат permission-recovery (#325) целиком — корень тривиален, а tap-safety + эмпирика Accessibility ценны; выбрасывать их ради обхода однострочного бага незачем.
- Делать окно непрозрачным на уровне `NSWindow` — сломало бы общий frameless-вид `SidekeyWindowChrome`.
- Реплицировать материал Settings — оверкилл для утилитарного repair-экрана; opaque `OnboardingTheme.bg` достаточно и проверен онбордингом.

2026-06-15 · ветка `claude/serene-shirley-3c7e89` · PR: см. описание коммита
