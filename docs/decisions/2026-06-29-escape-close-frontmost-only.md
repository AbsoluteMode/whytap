# Bare-Escape close агента: захват только пока whytap frontmost

**Дата:** 2026-06-29
**Где:** `Sources/Sidekey/Agent/AgentController.swift` (подписка `escapeCloseLifecycleCancellable`, инъекция `appActivePublisher`, диагностика в `start/stopEscapeCloseHotkey`); тест `AgentControllerStreamingTests.testEscapeCloseHotkeyReleasedWhileAppNotFrontmost`.

## Контекст

Симптом (рецидив): whytap снова глобально перехватывает Escape — клавиша перестаёт работать в других приложениях, «оживает сама через время», к конкретному действию не привязывается. Пользователь сообщил, что агентом сознательно **не** пользовался — но был в онбординге (`--force-onboarding`), где шаг Try-Agent армит реальный agent-флоу (`OnboardingAgentTryScreen`: «the real Right-⌘ gesture is armed on this step», ответ рендерится через реальный island `responseStore` — `OnboardingAgentLiveAnswer`).

Предыдущий фикс #423 (2026-06-24, `docs/decisions/2026-06-24-escape-close-answer-panel-only.md`) привязал захват к `answerPanelVisible`, убрав его во время невидимой фазы «думания». Но `answerPanelVisible` держится, пока ответ виден в острове, **без таймаута** — поэтому глобальный захват Escape оставался активным всё время показа ответа, в том числе когда пользователь ушёл работать в другое приложение. Это и есть остаточный путь рецидива.

Root cause механизма: `CarbonEscapeCloseHotkey` вешает голый Escape (`kVK_Escape`, без модификаторов) через Carbon `RegisterEventHotKey` — а такой хоткей забирает клавишу у всей системы, перед frontmost-приложением. Это **единственный** глобальный перехватчик Escape в коде (инвентаризация: `SpaceHoldMonitor` глотает Escape только в `.armed`; history/orb `addGlobalMonitorForEvents` пассивны и не крадут; `RightCmdGestureMonitor` Escape пропускает).

## Решение

Регистрировать bare-Escape Carbon-хоткей по **двум** условиям: панель ответа видна (`answerPanelVisible`) **И** whytap — frontmost-приложение. Подписка `escapeCloseLifecycleCancellable = Publishers.CombineLatest($answerPanelVisible, appActivePublisher).map(&&)`. `appActivePublisher` инъектируем (тесты передают детерминированный субъект), в проде = `NSApplication.didBecomeActive/didResignActive`, seed `NSApp.isActive`.

Диагностика: `os_log escape_close_registered frontmost=<bundle id>` / `escape_close_unregistered`. Раньше единственным сигналом был generic Carbon `tap_registered`, неотличимый от ⌥Q / ⌥-slash — застрявший захват был невидим в логах.

## Почему

- Корень рецидива — захват жил, пока ответ на экране (без таймаута), включая время, когда пользователь уже в другом приложении. Привязка к frontmost снимает захват ровно в момент, когда whytap перестаёт быть активным → Escape сразу работает в приложении пользователя, и возвращается при возврате в whytap (если ответ ещё виден).
- Escape как guaranteed-close осмыслен только когда пользователь смотрит на ответ (whytap frontmost). Ушёл — закрывать его клавишей нечего.
- Универсально: одним условием закрываются и обычный agent-путь, и онбординг Try-Agent (под капотом тот же agent-флоу).
- Диагностика: рецидивы этого класса нельзя было ловить (info-лог Carbon неспецифичен, к тому же не персистится). Теперь register/unregister с контекстом frontmost-приложения — дисбаланс пары виден сразу.

Компромисс: когда whytap **не** frontmost (island-ответ показан, а фокус в чужом приложении — island панель non-activating), Escape-close острова не срабатывает; закрытие через ✕ или новый turn. Это и есть желаемое поведение — Escape в чужом приложении важнее, чем закрытие острова этой клавишей.

## Что протестировали

- `testEscapeCloseHotkeyReleasedWhileAppNotFrontmost`: ответ виден + frontmost → Escape зарегистрирован (`startCalls == 1`); `appActive=false` (ушёл в другое приложение) → снят (`stopCalls >= 1`), панель ещё видна; `appActive=true` (вернулся) → перерегистрирован (`startCalls == 2`). Сначала RED (без gate `stopCalls` не растёт — `Condition was not met`), затем GREEN.
- Существующие escape-тесты (`Registers` / `TearsDown` / `StaysOff×2`) сделаны детерминированными инъекцией `appActivePublisher: Just(true)`. Без неё они неявно зависели бы от реального `NSApp.isActive` — это давало **order-dependent flaky** (2 падения в полной свите при зелёном изолированном прогоне; поймано до коммита).
- `swift test` — вся свита зелёная, escape-тесты проходят и в полном прогоне (детерминированы).

## Отвергли

- **Таймаут на захват/панель** — магическое число; в окне всё ещё крадёт; рассинхрон захвата и видимой панели (Escape перестаёт закрывать ещё видимый ответ).
- **Убрать bare-Escape совсем** — теряем Escape-close для видимого ответа без нужды; frontmost-гейт сохраняет его там, где он осмыслен.
- **Закрывать саму панель при уходе в фон** — большее UX-изменение (ответ исчезал бы при переключении приложений), для устранения бага не требуется.

## Хвост

Диагностика рецидива: триггер пользователя «не пользовался агентом» опроверг прямой agent-путь → инвентаризация всех глобальных перехватчиков Escape (единственный — Carbon Escape close) → онбординг Try-Agent как путь активации. «Оживает само» = `answerPanelVisible` сбрасывается при движении онбординга / новом turn. Точная последовательность залипания не воспроизведена (интермиттентный, пользователь не смог повторить по команде); фикс закрывает механизм независимо от пути активации, а добавленная диагностика ловит остаток, если он есть.

---
PR: TBD · ветка `claude/serene-hugle-d417cb`
