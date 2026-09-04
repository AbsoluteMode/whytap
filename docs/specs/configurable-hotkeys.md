# Spec: Настраиваемые хоткеи + хоткеи Hover (ROO-234 + ROO-210)

> Одобрено Андреем (brainstorm → writing-plans). План реализации: `docs/plans/configurable-hotkeys.md`.

## Что строим
Две связанные вещи поверх существующей системы хоткеев:
1. **ROO-234** — делаем хоткеи по-настоящему настраиваемыми: корректная модель конфликтов на уровне
   физической клавиши (tap/hold больше не перекрываются), Drop становится переназначаемым (дефолт
   остаётся hold Space), явное ограничение «≤2 клавиши», динамические подсказки везде.
2. **ROO-210** — каждой из 5 кнопок Hover даём хоткей (дефолт ⌥1..⌥5, настраиваемый), под кнопкой —
   keycap-подсказка; нажатие раскрывает Hover и выполняет действие кнопки.

ROO-234 — фундамент (модель конфликтов + настраиваемость), ROO-210 встраивается в него (5 hover-хоткеев
живут в той же модели конфликтов и динамических подсказках).

## Почему
Сейчас система гибридная: часть хоткеев настраивается, Drop жёстко зашит (read-only), а модель
конфликтов не ловит главный класс ошибок — tap и hold на одной физической клавише
(`conflicts` группирует по `(gesture, key)`, поэтому `hold Space` и `tap Space` не считаются
конфликтом, хотя физически неразличимы). Кнопки Hover вообще не имеют клавиатурного доступа.

## Scope v1
### In
- Модель конфликтов на уровне физической клавиши (`HotkeyConfiguration.conflicts` / `HotkeyBinding`).
- Drop переназначаемый: снять `displayOnly`, разрешить запись combo + пресет «Hold Space (default)»;
  дефолт = hold Space; combo-Drop форсит gesture `.hold`.
- 5 настраиваемых **позиционных** hover-хоткеев (дефолт ⌥1..⌥5), регистрация + переподписка,
  callback «активировать слот N» (раскрыть Hover + выполнить действие).
- Keycap-подсказки под кнопками Hover (compact `HotkeyHintView`), динамические.
- Явный энфорс «≤2 клавиши» (1 модификатор + 1 клавиша).
- Обновить инвариант #6 (CLAUDE.md + `workspace.c4` + `/pr-review` guard), `docs/hotkey.md`, Help window.
- Тесты (TDD) на модель конфликтов, регистрацию hover-хоткеев, routing Drop combo↔holdSpace.

### Out (deferred)
- Предупреждение «хоткей занят системой/меню другого приложения» (практика KeyboardShortcuts).
- tap-Drop (combo-Drop с gesture tap) — combo-Drop форсит `.hold`.
- Комбинации >2 клавиш, multi-key последовательности.
- Замена своей системы на стороннюю библиотеку.

## Ключевые решения
| Решение | Обоснование |
|---|---|
| Не переходить на `sindresorhus/KeyboardShortcuts` | Наша система зрелее: modifier-only, holdSpace, tap/hold gesture — либа этого не умеет. |
| tap/hold split разрешён только на **модификаторе** | Karabiner подтверждает: на обычной клавише tap/hold надёжно неразличимы. Модификатор (R⌘ tap=text, hold=voice) — рабочий паттерн. |
| Обычная клавиша/combo: одна клавиша = одно действие | Любое второе использование клавиши (любой gesture) = конфликт. Решает требование hold/tap. |
| Drop дефолт = hold Space, но переназначаемый | Решение Андрея. Routing уже есть в `HotkeyShortcutMonitor`. |
| Hover-хоткеи позиционные (⌥N → слот N) | Хоткей привязан к позиции, а не к инструменту; при reorder в Toolbox ⌥1 всегда «первый слот». |
| Нажатие ⌥N раскрывает Hover + выполняет | Единообразно и наглядно (inline-панель видна в раскрытом Hover). Уважает `IslandHoverPolicy.allowsExpansion`. |
| ⌥5 — locked Settings: клавиша переназначаема, действие фиксировано | `HoverLayoutStore.lockSlotIndex=4`: 5-я позиция всегда `.settings`. |

## Как работает
- **Модель конфликтов.** `HotkeyBinding.Key` различает `.modifier`/`.combo`/`.holdSpace`. Для `.modifier`
  конфликт = совпадение `(gesture, key)` (tap+hold на одном модификаторе — ОК); для `.combo`/`.holdSpace`
  конфликт = совпадение физической клавиши **без учёта gesture**.
- **Drop настраиваемый.** В `HotkeysSettingsView` Drop-строка получает recorder + пресет «Hold Space (default)»;
  combo-Drop форсит `.hold` (release-callback load-bearing). `observeHotkeyPreferences()` переподписывает монитор;
  `HotkeyShortcutMonitor` выбирает `SpaceHoldMonitor` или `CarbonHotkeyMonitor`. Удаляется cutover-миграция
  `migrateDropComboToHoldSpaceIfNeeded`.
- **Hover-хоткеи.** 5 `@Published` шорткатов в `HotkeyPreferences` (дефолт ⌥1..⌥5); регистрация 5 мониторов
  + подписки; единый callback `onHoverSlotActivated(index)` (раскрыть Hover через AppState при policy-allow +
  выполнить действие слота). Подсказки в `IslandView` под `IslandHoverPanelControl` через compact `HotkeyHintView`.
- **Динамические подсказки.** Все surfaces читают из `HotkeyConfiguration` → обновляются после Save.

## User flows (happy path)
- **Сменить хоткей Agent voice:** Settings → Hotkeys → tap по слоту → новая комбинация → конфликт краснит строку → Save → подсказки обновились.
- **Переназначить Drop:** Settings → Hotkeys → Drop → combo (или пресет Hold Space) → Save → монитор переподписался.
- **Hover с клавиатуры:** ⌥3 (мышь не на острове) → Hover раскрывается, действие 3-го слота → под кнопками `⌥1..⌥5`.

## Сценарии / edge cases
- `tap Space` при `hold Space` на Drop → конфликт, Save заблокирован.
- Drop переназначен на `⌥D` → `SpaceHoldMonitor.stop()` освобождает Input Monitoring, Carbon регистрирует ⌥D.
- ⌥N конфликтует с другим hover-слотом/agent-хоткеем → строка краснеет.
- Reorder в Toolbox → ⌥N указывает на ту же позицию (позиционная привязка).
- Слот 5 (locked Settings) по ⌥5 → открывает Settings.
- Во время митинга (`allowsExpansion=false`) ⌥N не форсит раскрытие.

## Ограничения (honored)
- Инвариант #3: содержимое нажатий не логируется/не персистится (расширяется на новые мониторы).
- Инвариант #6 переписывается: Drop по умолчанию hold Space, но переназначаем.
- `docs/hotkey.md`: каждый хоткей в Help window; подсказки через `HotkeyHintView`; глифы `HotkeyGlyph`.
- TDD ≥80%, иммутабельность `HotkeyConfiguration`.

## Prior art
- **KeyboardShortcuts (sindresorhus):** взять — system/menu-conflict warning (→ deferred), recorder-UX (есть аналог). Избегать — single-combo-only, нет modifier-only/tap-hold.
- **Karabiner:** tap/hold надёжно различимы по таймпорогу только на модификаторах → отсюда правило «обычная клавиша = одно действие».

## Boundaries
- **Always:** модель конфликтов на физ.клавише; ≤2 клавиши; дефолты (Drop=holdSpace, hover=⌥1..5);
  динамические подсказки на всех surfaces; обновить docs/hotkey.md + инвариант #6 + Help; TDD.
- **Never:** не заменять систему сторонней либой; не ломать дефолт Drop=hold Space; не логировать
  содержимое нажатий; не вводить >2 клавиши; не переписывать `SpaceHoldDetector` FSM без необходимости.
- **Ask (в реализации):** финальные copy/SF-символы подсказок; поведение при конфликте ⌥N с системным шорткатом (deferred).

## Open questions
- **Возврат Drop на hold Space через UI** — не блокирующий; решает пресет-кнопка «Hold Space (default)».
- **Системные конфликты (вне приложения)** — не блокирующий; deferred.
- **`EventTracker.hotkeyTrigger` контракт** — проверить в начале Stage 3.
