# Escape-close ответа агента: пассивный NSEvent-монитор вместо Carbon-захвата

**Дата:** 2026-07-02
**Где:** `Sources/Sidekey/Agent/AgentResponseCloseHotkey.swift` (`EscapeCloseEventMonitor`, заменил `CarbonEscapeCloseHotkey`), `Sources/Sidekey/Agent/AgentController.swift` (лайфцикл только по `answerPanelVisible`; `appActivePublisher` удалён), тесты `AgentControllerStreamingTests` + `EscapeCloseEventMonitorTests`.

## Контекст

Регрессия после #458: с открытым ответом агента Escape его не закрывает — вообще, ни в каком сценарии. #458 гейтил регистрацию bare-Escape Carbon-хоткея на `answerPanelVisible && NSApp.isActive` (frontmost-gate), чтобы вылечить рецидивный «Escape пропадает глобально в других приложениях» (Carbon `RegisterEventHotKey` на голый Escape забирает клавишу у всей системы).

Ошибка модели #458: «пользователь смотрит на ответ ⇒ whytap frontmost». whytap — accessory-приложение (`setActivationPolicy(.accessory)`), а панель ответа в острове — non-activating: она никогда не делает приложение active. `NSApp.isActive` в реальном использовании ≈ всегда `false` (исключение — открытые Settings/Help). Гейт задумывался как «отпустить захват, когда пользователь ушёл в другое приложение», а фактически стал «не регистрировать никогда». Компромисс был осознан в decision-doc #458 («закрытие через ✕ или новый turn»), но его масштаб недооценён: думали, что теряем Esc-close только на время работы в чужом приложении, потеряли везде.

## Решение

Bare-Escape close переведён с Carbon-захвата на **пассивное наблюдение**: `EscapeCloseEventMonitor` = `NSEvent.addGlobalMonitorForEvents(.keyDown)` (Escape при чужом frontmost) + `addLocalMonitorForEvents` (Escape, когда key window — окно whytap, например Settings). Оба монитора не поглощают событие (local возвращает event как есть). Предикат `isBareEscape` — keyCode 53 без chord-модификаторов (⌘⌥⌃⇧); state-флаги клавиатуры (Caps Lock, fn) не считаются chord'ом.

Лайфцикл вернулся к форме #423: регистрация ровно на время `answerPanelVisible`, **без** app-active гейта — `appActivePublisher` и `defaultAppActivePublisher()` удалены из `AgentController`, Carbon-ID `escapeCloseHotKeyID` освобождён. Диагностика `escape_close_registered/unregistered` сохранена и поднята с `.info` до `.default` — `.info` unified log не персистит, из-за чего рецидив #458 был невидим post-factum (проверено: `log show` за 4 часа при живом баге — пусто).

## Почему

- Пассивный монитор разрешает ОБА бага одновременно, потому что убирает сам конфликт: Escape закрывает видимый ответ из любого приложения (жалоба сегодняшняя), и при этом клавиша всегда доходит до приложения пользователя (жалоба #423/#458). Держать монитор всю жизнь ответа безопасно — красть нечего.
- Класс рецидивов «Escape пропадает глобально» закрыт по конструкции, а не по условию: в кодовой базе больше нет ни одного глобального захватчика Escape (Carbon bare-Escape удалён; `SpaceHoldMonitor` глотает Escape только в `.armed`).
- Точечный гейт (только `answerPanelVisible`) сохраняет прежние инварианты: recording владеет Escape через gesture-cancel, composing — через key-window `.onExitCommand`, acting не регистрирует ничего.
- Global monitor требует Accessibility — оно уже обязательно для agent-жеста (`RightCmdGestureMonitor`); без гранта деградация мягкая: Esc-close работает только при key-окне whytap, ✕/⌥Q живы (тот же soft-fail контракт, что раньше).

Компромисс (принят): Escape теперь «двойного действия» — при видимом ответе нажатие Esc закроет ответ И долетит до активного приложения (например, закроет его автокомплит). Считаем это честнее захвата: до #458 Escape при видимом ответе вообще не доходил до приложения пользователя, и именно это было багом.

## Что протестировали

- RED→GREEN `testEscapeCloseHotkeyRegistersWhileAnswerPanelVisibleEvenWhenAppNotFrontmost`: воспроизводит прод-форму (реальный `NSApplication.shared`, неактивный в headless-раннере = accessory-форма) — на коде #458 падал (`startCalls == 0`), после снятия гейта зелёный. Живучий guard: если кто-то вернёт app-active гейт, тест упадёт.
- RED→GREEN `EscapeCloseEventMonitorTests` (4 кейса): bare Esc → срабатывает; ⌘/⌥/⌃/⇧+Esc → нет; Caps Lock/fn+Esc → срабатывает; другие клавиши → нет.
- Прежние escape-тесты лайфцикла (Registers/TearsDown/StaysOff×2) — зелёные; тест #458 `ReleasedWhileAppNotFrontmost` удалён как выражающий отменённый контракт; инъекции `appActivePublisher` вычищены (параметр удалён — заодно ушла документированная order-dependent флейкость от реального `NSApp.isActive`).
- Полная свита `swift test` зелёная (см. PR).

## Отвергли

- **Carbon-захват при hover над островом** — Esc работал бы только с мышью над ответом; непредсказуемо и не соответствует привычке «нажал Esc, глядя на ответ».
- **Панель ответа = key window + локальный Escape** — уводит keyboard focus из приложения пользователя при каждом ответе; ломает флоу «спросил и продолжаешь печатать у себя».
- **Откат к #423 (Carbon при `answerPanelVisible`)** — возвращает исходный баг кражи Escape один-в-один.
- **CGEventTap с выборочным поглощением** — то же эксклюзивное владение клавишей, тот же исходный баг, плюс лишний tap-механизм.
- **Таймаут на панель/захват** — отвергнут ещё в #458 (магическое число, рассинхрон с видимым ответом).

---
2026-07-02 · PR: ветка `claude/optimistic-volhard-db7e72` · предыстория: `2026-06-24-escape-close-answer-panel-only.md`, `2026-06-29-escape-close-frontmost-only.md`
