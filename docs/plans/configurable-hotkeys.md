# Plan: Configurable hotkeys + Hover hotkeys (ROO-234 + ROO-210)

## Context
Сейчас система хоткеев гибридная: часть настраивается, Drop жёстко зашит на hold Space
(read-only, инвариант #6), а модель конфликтов не ловит главный класс ошибок — tap и hold
на одной физической клавише (`HotkeyConfiguration.conflicts` группирует по `(gesture, key)`,
поэтому `hold Space` и `tap Space` не считаются конфликтом, хотя физически неразличимы).
Кнопки Hover не имеют клавиатурного доступа. Делаем хоткеи по-настоящему настраиваемыми
(ROO-234) и даём 5 кнопкам Hover настраиваемые хоткеи ⌥1..⌥5 с подсказками (ROO-210).

## Plan status
Status: ready-for-execution
Reason: спека одобрена Андреем; все требования трассируются к стадиям; гейты бинарные;
открытые вопросы не блокирующие (UX возврата Drop на hold Space — пресет, Stage 2;
системные конфликты и tap-Drop — deferred). Замечания reviewer-агента учтены (C1, I1–I5, S1–S3).

## Source spec
- Spec: одобрена в brainstorm (в контексте; материализуется в `docs/specs/configurable-hotkeys.md`)
- Approved by: Андрей (явное «Одобряю → writing-plans»)
- Scope summary: корректная модель конфликтов на уровне физической клавиши + ограничение
  ≤2 клавиши; переназначаемый Drop (дефолт hold Space); 5 настраиваемых **позиционных**
  hover-хоткеев ⌥1..⌥5 с динамическими keycap-подсказками; обновление инвариантов и документации.

## Key design decisions (фиксируются до исполнения)
- **D1 — Hover-хоткеи позиционные.** ⌥N привязан к **позиции слота** `HoverLayoutStore.slots[N-1]`,
  а не к конкретному инструменту. При reorder в Toolbox ⌥N начинает активировать новый инструмент в
  этой позиции — это намеренно. Keycap-подсказки и Settings-строки берут **живой** layout из
  `HoverLayoutStore`. `IslandView.tileView(for:)` диспатчит по идентичности `HoverTool`, поэтому
  «активировать слот i» = взять `slots[i]` и выполнить действие этого инструмента.
- **D2 — Слот 5 (locked Settings).** `HoverLayoutStore.lockSlotIndex=4` делает 5-ю позицию всегда
  `.settings`. ⌥5 активирует Settings; его **клавиша переназначаема**, но **действие фиксировано**
  (5-я Settings-строка показывает редактируемую клавишу и нередактируемое действие «Settings»).
- **D3 — combo-Drop форсится `.hold`.** Gesture-switch для Drop остаётся disabled. `.hold` load-bearing:
  `registerHotkey` вяжет release-callback (stop+transcribe) только при `.hold` (HotkeyPreferences.swift:924-926).
  tap-Drop — deferred (Open questions).
- **D4 — Программное раскрытие Hover уважает policy.** ⌥N раскрывает Hover только если
  `IslandHoverPolicy.allowsExpansion(...)` истинно (не раскрывает во время митинга/agent-flow);
  иначе действие слота либо выполняется без раскрытия (для `.action`), либо игнорируется (для `.inlinePanel`).
  Программное раскрытие схлопывается при уходе мыши/следующем взаимодействии (как обычный hover).

## Current state context

**Affected modules (evidence-based):**
- `Sources/Sidekey/Hotkeys/HotkeyPreferences.swift` — `HotkeyShortcut`(:58), `HotkeyTapCombo`(:200),
  `HotkeyComboRecorder`(:537), `HotkeyShortcutRecorder`(:633), `HotkeyConfiguration`(:770),
  `HotkeyGesture`(:936), `HotkeyBinding`/`.Key`(:952), `assignments`(:997), `conflicts`(:1034),
  `HotkeyPreferences`(:1082), `defaults`(:918), `migrateDropComboToHoldSpaceIfNeeded`(:1325), `migrationLog`(:1336).
- `Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift` — Drop-строка `displayOnly:true`(:67-79),
  `HotkeySettingRow`(:401), `ShortcutGestureSlot`(:481), `assignShortcut`(:270), `hasConflict`(:312),
  `binding(for:)`(:317), `RecordingTarget`(:356), footer apply/revert(:367).
- `Sources/Sidekey/Hotkeys/HotkeyShortcutMonitor.swift` — routing switch(:33): combo→Carbon,
  modifier→ModifierOnly, holdSpace→SpaceHold.
- `Sources/Sidekey/Hotkeys/SpaceHoldMonitor.swift` — `start()`(:237)/`stop()`(:253) освобождает Input Monitoring.
- `Sources/Sidekey/CarbonHotkeyMonitor.swift` — hotKeyID константы (dropHotKeyID=1 … agentVoiceHotKeyID=12, :104); ID 13..17 свободны.
- `Sources/Sidekey/AppDelegate.swift` — `registerHotkey()`(:1623), `observeHotkeyPreferences()`(:1727)
  Combine sink → `reregisterDropHotkey()`(:1746), `onDropHotkeyPressed/Released/Cancelled`(:2043+),
  `handleDropHotkeyRoute`(:2109), `makeIslandActions()`(:1266).
- `Sources/Sidekey/DynamicIsland/IslandView.swift` — `controls`(:1800), `IslandDropModeHoverPanel`(:1654),
  `IslandHoverPanelControl`(:2564), `tileView(for:)`(:1849), `isHoverExpanded`(:271)=`isHovering && IslandHoverPolicy.allowsExpansion`,
  `isHovering`(:232)=`pillHovering||panelHovering`.
- `Sources/Sidekey/DynamicIsland/IslandActions.swift` — `struct IslandActions`(:1) (closures: startDictate, openClipboard, …).
- `Sources/Sidekey/Settings/HoverLayoutStore.swift` — `slotCount=5`, `lockSlotIndex=4`,
  `defaultSlots=[.dropMode,.notifs,.clipboard,.vocab,.settings]`, `@Published slots`, `setSlot(_:to:)`(:38).
- `Sources/Sidekey/Settings/HoverTool.swift` — `HoverTool` enum, `HoverToolRegistry.info`, `HoverToolKind`(.inlinePanel/.action/.navigate).
- `Sources/Sidekey/HotkeyHintView.swift` (+`HotkeyGlyph`:9), `KeycapView.swift` — подсказки/keycaps, `compact` режим, `combinedAccessibilityLabel`.
- `Sources/Sidekey/HelpWindowController.swift` — `HelpWindowContent.hotkeyRows(for:)` (config-driven rows).
- `Sources/Sidekey/DynamicIsland/IslandPassiveHints.swift` — rotating hints (live config binding).
- `Sources/Sidekey/AppState.swift` — `orbHovered`(:108); НЕ читается в `isHoverExpanded` — нужно новое поле программного раскрытия.

**Reusable (не писать с нуля):**
- `HotkeyShortcutMonitor` уже маршрутизирует combo↔holdSpace (был legacy combo-Drop до Stage 4 cutover).
- `observeHotkeyPreferences()` уже переподписывает мониторы на изменение `@Published`.
- `HotkeyShortcutRecorder`/`HotkeyComboRecorder` уже структурно держат 1 модификатор + 1 клавишу (≤2 клавиши — инвариант уже выполнен).
- `IslandActions.startDictate` уже переиспользует `onDropHotkeyPressed()` — паттерн «клик зовёт тот же callback, что хоткей».
- `HotkeyHintView(contents:compact:)` + `KeycapView` — готовый рендер keycap-подсказок.
- `dropHotkeyPressedRoute`/`dropHotkeyReleasedRoute` уже разводят tap/hold маршруты.

**Constraints:**
- Инвариант #3: содержимое нажатий не логируется/не персистится — распространить на новые мониторы.
- Инвариант #6: переписывается (Drop становится настраиваемым; дефолт hold Space).
- `docs/hotkey.md`: каждый хоткей в Help window; подсказки через `HotkeyHintView`; глифы из `HotkeyGlyph`.
- Агентам запрещены фоновые билды; SwiftUI-специфика → пара `dev-foundation`+`swiftui-expert`; TDD ≥80%.

## Spec coverage map

| Spec requirement | Stage | Validation signal |
|---|---:|---|
| Конфликты hold/tap на физ.клавише не перекрываются | 1 | `conflicts` ловит (tap X, hold X) для combo/holdSpace; modifier tap/hold split — не конфликт; R⌘ text/voice split сохранён |
| Ограничение ≤2 клавиши | 1 | recorder отклоняет >2 клавиши (regression-lock тест) |
| Drop переназначаем (дефолт hold Space) | 2 | apply Drop=combo сохраняется; routing переключается; пресет Hold Space восстанавливает дефолт; combo-Drop форсит `.hold` |
| Hover ⌥1..⌥5 срабатывают (раскрыть + выполнить) | 3 | нажатие ⌥N → Hover раскрыт (если policy allows) + действие `slots[N-1]` |
| Hover-хоткеи настраиваемые (5 строк Settings) | 4 | Settings → Hotkeys содержит 5 редактируемых hover-строк; 5-я (Settings) — клавиша editable, действие fixed |
| Keycap-подсказки под кнопками Hover, динамические | 4 | подсказка позиции N = `config.hoverSlotN.contents`; обновляется после Save |
| Динамические подсказки везде (Help/IslandPassiveHints) | 4 | Help/hover читают из `HotkeyConfiguration` |
| Обновить инвариант #6 + docs/hotkey.md + Help + workspace.c4 + pr-review guard | 5 | ревью: docs соответствуют коду |

## Cross-cutting concerns

| Concern | Plan |
|---|---|
| Auth / authorization | Not applicable (локальный клиент, без ролей) |
| Observability | Per-stage: `EventTracker.hotkeyTrigger` для новых hover-хоткеев + Drop (Stage 3); только факт срабатывания, НЕ содержимое (инвариант #3). ⚠️ Stage 3: проверить, что `EventTracker.hotkeyTrigger` существует с таким контрактом, иначе подобрать существующий аналог |
| Testing | TDD per-stage: автотесты (логика/конфликты/routing/регистрация) + user handoff на рендер UI (Stage 2,3,4) |
| Documentation | Stage 5 (CLAUDE.md, docs/hotkey.md, Help, workspace.c4, pr-review guard) |
| Migration data | Stage 2: УДАЛИТЬ `migrateDropComboToHoldSpaceIfNeeded` (cutover Stage 4) — иначе затрёт пользовательский combo-Drop при следующем запуске; убрать мёртвый `migrationLog`. Fresh install (пустые defaults) по-прежнему сидит `.holdSpace` через else-ветку (:1253-1254). Новые `hoverSlotN` ключи имеют дефолты при отсутствии |
| Backward compatibility | UserDefaults: новые ключи `hotkeys.hoverSlotNShortcut` с дефолтами; снятие форс-миграции Drop не ломает существующие holdSpace-конфиги |
| Feature flags / rollout | Not applicable (нет staged rollout; локальная фича) |
| Security / privacy | Инвариант #3 (не логировать нажатия) — проверить в Stage 3 для новых мониторов |
| Idempotency / concurrency | Мониторы @MainActor; регистрация идемпотентна (`guard hotkey == nil`); N/A далее |
| Failure modes | Carbon-регистрация может упасть → `hotkeyRegistrationFailed` уже есть; hover-хоткеи аналогично (не крашить, лог) |
| Accessibility | keycap-подсказки: `HotkeyHintView.combinedAccessibilityLabel` (уже есть) — проверить для hover (Stage 4) |

## Stages

### Stage 1 — Модель валидности хоткеев (конфликты на физ.клавише + ≤2 клавиши)
- **Behavioral delta:** `HotkeyConfiguration.conflicts` считает конфликт на уровне физической
  клавиши: для `.combo`/`.holdSpace` — любое второе использование клавиши конфликтует независимо
  от gesture; для `.modifier` — tap/hold split допустим (конфликт только при совпадении и gesture, и key).
- **Scope:**
  - In: переработка `conflicts`/группировки в `HotkeyConfiguration`(:1034) (+ helper на
    `HotkeyBinding.Key` «физический ключ» при необходимости); regression-тест инварианта «≤2 клавиши»;
    тесты. modifier-split (R⌘ tap=text/hold=voice) сохраняется намеренно.
  - Out: UI, регистрация мониторов, Drop, hover (следующие стадии).
- **Dependencies:** none (foundation).
- **Affected modules:** `HotkeyPreferences.swift` (`conflicts`:1034, `assignments`:997, `HotkeyBinding`:952, recorders:537/633).
- **Artifacts:** изменения в `HotkeyPreferences.swift`; новый тест-файл
  `Tests/SidekeyTests/Hotkeys/HotkeyConflictModelTests.swift`.
- **Validation gate (automatic):** написать тесты ДО реализации:
  - `test_modifier_tap_hold_split_is_not_conflict` — (tap R⌘, hold R⌘) → 0 конфликтов
  - `test_agent_text_and_voice_share_rcmd_without_conflict` — РЕАЛЬНЫЙ дефолт: `agentTextShortcut`=.modifier(.rightCommand)+tap
    и `agentVoiceShortcut`=.modifier(.rightCommand)+hold → 0 конфликтов (защищаемый modifier-split; правило не «упрощать»)
  - `test_modifier_same_gesture_same_key_is_conflict` — два tap на R⌘ → 1 конфликт
  - `test_combo_same_key_any_gesture_is_conflict` — (tap ⌥D, hold ⌥D) → 1 конфликт
  - `test_holdspace_conflicts_with_other_space_binding` — holdSpace + второе действие на Space → конфликт
  - `test_recorder_rejects_more_than_two_keys` — REGRESSION-LOCK: recorder'ы уже держат 1 модификатор+1 клавишу;
    тест фиксирует инвариант, НЕ добавлять новый guard под несуществующий баг
  - `test_default_configuration_has_no_conflicts` — `HotkeyConfiguration.defaults.conflicts.isEmpty` (regression)
  - Команда: `swift test --filter "HotkeyConflictModelTests|HotkeyPreferencesTests"` → all green.
- **Validator:** agent (pure logic) + reviewer (`pr-review`, усиленно — ядро фичи).
- **Failure strategy:** revert PR (чистая логика, изолировано).
- **Observability:** not applicable (чистая модель данных).

### Stage 2 — Drop переназначаемый (Settings + routing + Input Monitoring)
- **Behavioral delta:** пользователь может переназначить Drop в Settings → Hotkeys на combo или вернуть
  пресет «Hold Space (default)»; монитор переподписывается; Input Monitoring запрашивается только при holdSpace.
- **Scope:**
  - In: снять `displayOnly` у Drop-строки (`HotkeysSettingsView`:67-79); добавить recorder для Drop +
    явную кнопку-пресет «Hold Space (default)» (т.к. `.holdSpace` не записывается combo-recorder'ом);
    **combo-Drop форсится `.hold`, gesture-switch для Drop disabled** (D3 — `.hold` load-bearing для release-callback);
    УДАЛИТЬ `migrateDropComboToHoldSpaceIfNeeded`(:1325) + вызов(:1307) + мёртвый `migrationLog`(:1336) + doc-ссылки
    (grep `migrateDropCombo`/`hotkey_migration`); переподписка `$dropVoiceShortcut` уже есть(`observeHotkeyPreferences`:1727).
    Drop-конфликты используют модель Stage 1.
  - Out: hover-хоткеи; правки Help window (Stage 5).
- **Dependencies:** Stage 1 (`blocking-required`).
- **Affected modules:** `HotkeysSettingsView.swift`, `HotkeyPreferences.swift` (убрать миграцию),
  `HotkeyShortcutMonitor.swift` (routing уже готов — только проверить тестом).
- **Artifacts:** изменения в `HotkeysSettingsView.swift`, `HotkeyPreferences.swift`; тесты
  `Tests/SidekeyTests/Hotkeys/DropConfigurableTests.swift`; обновить `HotkeyPreferencesTests` (миграция убрана).
- **Validation gate (automatic + user handoff):**
  - Auto тесты (ДО реализации):
    - `test_drop_can_be_assigned_combo` — apply config Drop=`.combo(⌥D)` сохраняется в prefs
    - `test_drop_holdspace_preset_sets_holdspace_and_hold` — пресет → `.holdSpace` + gesture `.hold`
    - `test_combo_drop_uses_hold_gesture` — при выборе combo-Drop gesture остаётся `.hold` (switch disabled)
    - `test_drop_combo_routes_to_carbon` — `HotkeyShortcutMonitor(.combo)` создаёт Carbon-монитор
    - `test_drop_holdspace_routes_to_spacehold` — `.holdSpace` создаёт SpaceHoldMonitor
    - `test_reinit_preserves_user_combo_drop` — после удаления миграции combo-Drop переживает re-init
    - `test_fresh_install_defaults_to_hold_space` — пустые UserDefaults → Drop = `.holdSpace`+`.hold` (else-ветка :1253-1254)
    - Команда: `swift test --filter "DropConfigurable|HotkeyPreferences"` → all green.
  - User handoff (Андрей, рендер Settings): открыть Settings → Hotkeys → сменить Drop на ⌥D → Save →
    проверить срабатывание по ⌥D; вернуть «Hold Space (default)» → удержание Space снова работает, Escape отменяет;
    конфликт Drop с другим действием — строка краснеет, Save заблокирован.
- **Validator:** agent (logic/routing) + user (рендер Settings и реальное срабатывание) + reviewer (`pr-review`).
- **Failure strategy:** revert PR; дефолт `.holdSpace`+`.hold` в `defaults`, поэтому откат возвращает прежнее поведение.
- **Observability:** существующий `EventTracker.hotkeyTrigger metadata:["hotkey":"drop"]` сохраняется для обоих путей.

### Stage 3 — Hover-хоткеи: регистрация + действие (⌥1..⌥5 → раскрыть + выполнить)
- **Behavioral delta:** нажатие ⌥N (N=1..5) раскрывает Hover (если policy позволяет) и выполняет действие
  слота на позиции N (`slots[N-1]`), через единый callback — то же, что клик по тайлу.
- **Scope:**
  - In: 5 новых `@Published hoverSlot1Shortcut`…`hoverSlot5Shortcut` в `HotkeyPreferences` + поля в
    `HotkeyConfiguration` (дефолты `.combo(.optionOne)`…`.combo(.optionFive)` — новые пресеты `HotkeyTapCombo`
    optionKey+`kVK_ANSI_1..5`, добавить в `legacyPreset`/`legacyRawValue` switches:415-479 для raw-value round-trip);
    добавить 5 в `assignments`(:997) (для conflict-графа Stage 1); 5 hotKeyID в `CarbonHotkeyMonitor` (13..17);
    регистрация 5 мониторов в `registerHotkey()` + подписки в `observeHotkeyPreferences()`;
    `onHoverSlotActivated(index:)` в AppDelegate (index 1-based позиция); `activateHoverSlot:(Int)->Void` в `IslandActions`;
    единый роутер «взять `HoverLayoutStore.slots[i]` и выполнить действие этого инструмента» в IslandView
    (переиспользуется кликом и хоткеем — D1); `AppState.programmaticHoverExpansion: Bool` + учёт в
    `IslandView.isHoverExpanded`(:271) **только когда `IslandHoverPolicy.allowsExpansion` истинно** (D4),
    схлопывание по уходу мыши/следующему взаимодействию; `EventTracker.hotkeyTrigger ["hotkey":"hoverSlotN"]`.
  - Out: keycap-подсказки под кнопками, 5 строк в Settings, Help (Stage 4).
- **Dependencies:** Stage 1 (`blocking-required` — conflict-граф), Stage 2 (`blocking-required` — общие файлы
  `AppDelegate.registerHotkey`/`HotkeysSettingsView`/`HotkeyPreferences`, избегаем merge-конфликта).
- **Affected modules:** `HotkeyPreferences.swift`, `CarbonHotkeyMonitor.swift`, `AppDelegate.swift`,
  `IslandActions.swift`, `DynamicIsland/IslandView.swift`, `AppState.swift`.
- **Artifacts:** изменения в перечисленных файлах; тесты `Tests/SidekeyTests/Hotkeys/HoverHotkeyTests.swift`.
- **Validation gate (automatic + user handoff):**
  - Auto тесты (ДО реализации):
    - `test_hover_shortcut_defaults_are_option_digits` — `config.hoverSlot1..5` = ⌥1..⌥5
    - `test_option_digit_presets_round_trip` — `.optionOne..optionFive` round-trip через rawValue/Codable
    - `test_hover_shortcuts_in_assignments` — `assignments` содержит 5 hover-bindings (участвуют в `conflicts`)
    - `test_activate_hover_slot_sets_expansion_and_invokes_action` — `onHoverSlotActivated(i)` при policy-allow ставит
      `programmaticHoverExpansion=true` и вызывает действие `slots[i-1]` (мок IslandActions)
    - `test_hover_slot_action_follows_layout_reorder` — после `HoverLayoutStore.setSlot`, `onHoverSlotActivated(i)`
      вызывает действие НОВОГО инструмента в позиции i (позиционная привязка, D1)
    - `test_hover_slot_routes_same_action_as_click` — роутер действия позиции i идентичен click-обработчику
    - `test_programmatic_expansion_respects_hover_policy` — при `allowsExpansion=false` (митинг) ⌥N не форсит раскрытие
    - Команда: `swift test --filter HoverHotkey` → all green.
  - User handoff (Андрей, рендер острова, дефолтный layout): при свёрнутом Hover ⌥3 → Hover раскрывается,
    действие 3-й позиции; ⌥1 (Drop mode по дефолту) переключает режим; ⌥5 открывает Settings.
- **Validator:** agent (callback/registration/routing logic) + user (реальное раскрытие+действие) + reviewer (`pr-review`).
- **Failure strategy:** revert PR; hover-мониторы регистрируются отдельно от Drop — их сбой не влияет на Drop
  (`hotkeyRegistrationFailed` логируется, не крашит).
- **Observability:** `EventTracker.hotkeyTrigger metadata:["hotkey":"hoverSlotN"]` (факт срабатывания, без содержимого).

### Stage 4 — Hover-подсказки + Settings-строки + Help + динамика
- **Behavioral delta:** под каждой кнопкой Hover видна keycap-подсказка её хоткея (из живого layout); 5 hover-хоткеев
  редактируются в Settings → Hotkeys; Help window перечисляет их; подсказки обновляются после Save.
- **Scope:**
  - In: рендер `HotkeyHintView(contents: config.hoverSlotN.contents, compact:true)` под `IslandHoverPanelControl`
    (`IslandView`), где N — позиция тайла; 5 редактируемых строк hover в `HotkeysSettingsView` (+`RecordingTarget`
    кейсы, `assignShortcut`/`shortcut(for:)`/`binding(for:)` ветки), строки подписаны живым `HoverLayoutStore.slots`;
    **5-я строка (Settings, locked): клавиша editable, действие fixed/non-editable** (D2); 5 rows в
    `HelpWindowContent.hotkeyRows(for:)`.
  - Out: инварианты/CLAUDE.md/workspace.c4 (Stage 5).
- **Dependencies:** Stage 3 (`blocking-required` — хоткеи и поля должны существовать), Stage 1 (conflict-UI).
- **Affected modules:** `DynamicIsland/IslandView.swift`, `HotkeysSettingsView.swift`, `HelpWindowController.swift`,
  переиспользует `HotkeyHintView.swift`/`KeycapView.swift`.
- **Artifacts:** изменения в перечисленных файлах; дополнить `HotkeyHintViewTests`, `HotkeysSettingsViewTests`, при необходимости новый.
- **Validation gate (automatic + user handoff):**
  - Auto тесты (ДО реализации):
    - `test_hover_hint_contents_match_config` — подсказка позиции N == `config.hoverSlotN.contents`
    - `test_settings_exposes_five_editable_hover_rows` — Settings-логика отдаёт 5 hover RecordingTarget
    - `test_settings_slot5_key_editable_action_fixed` — 5-я строка: клавиша редактируема, действие=Settings нередактируемо (D2)
    - `test_help_rows_include_hover_hotkeys` — `hotkeyRows(for:)` содержит 5 hover-строк
    - `test_hover_hotkey_conflict_flagged_in_settings` — конфликт ⌥N с другим действием помечается (модель Stage 1)
    - Команда: `swift test --filter "HotkeyHintView|HotkeysSettings|Help"` → all green.
  - User handoff (Андрей, рендер): Hover показывает ⌥1..⌥5 под кнопками; смена hover-хоткея в Settings →
    после Save подсказка под кнопкой обновилась; Help window показывает все хоткеи (вкл. Drop и hover).
- **Validator:** agent (contents/logic) + user (визуал подсказок, обновление, Help) + reviewer (`pr-review`).
- **Failure strategy:** revert PR; подсказки — презентационный слой поверх Stage 3, откат не ломает поведение хоткеев.
- **Observability:** not applicable (презентация).

### Stage 5 — Инварианты + документация
- **Behavioral delta:** проектные инварианты и документация отражают настраиваемый Drop и hover-хоткеи.
- **Scope:**
  - In: переписать инвариант #6 в `CLAUDE.md` (Drop по умолчанию hold Space, но переназначаемый;
    Input Monitoring нужен только при holdSpace); обновить `docs/hotkey.md` (Drop editable, 5 позиционных
    hover-хоткеев, подсказки в Hover); обновить `workspace.c4` + `/pr-review` guard в репо
    `rootwise-team/architecture` (products/sidekey) — снять «Drop фиксирован», добавить «Drop настраиваемый,
    дефолт hold Space»; Notion Docs (раздел Архитектура/Ключевые файлы — по правилу обновления docs).
  - Out: код приложения (предыдущие стадии).
- **Dependencies:** Stage 2, 3, 4 (`blocking-required` — документируем финальное поведение).
- **Affected modules:** `CLAUDE.md`, `docs/hotkey.md`, репо `architecture` (`workspace.c4`, pr-review guard).
- **Artifacts:** правки документации в двух репозиториях.
- **Validation gate (review):**
  - Инвариант #6 в `CLAUDE.md` больше не утверждает «Drop фиксирован/не конфигурируется».
  - `docs/hotkey.md` описывает настраиваемый Drop + позиционные hover-хоткеи + подсказки.
  - `workspace.c4` guard в репо `architecture` обновлён — `/pr-review` не падает на инварианте.
  - Команда: `git -C <architecture-repo> grep -n "Drop" workspace.c4` показывает обновлённую формулировку; ревью.
- **Validator:** reviewer (`pr-review`) + user (Андрей подтверждает формулировки).
- **Failure strategy:** revert PR (только документация).
- **Observability:** not applicable.

## Execution sequencing

| Stage | Dependency type | Parallel with | Notes |
|---:|---|---|---|
| 1 | foundation / none | none | Чистая логика конфликтов — фундамент |
| 2 | blocking-required: Stage 1 | none | Делит файлы с Stage 3 → перед ним |
| 3 | blocking-required: Stage 1, 2 | none | Регистрация + действие hover |
| 4 | blocking-required: Stage 3 (и 1) | none | UI поверх Stage 3 |
| 5 | blocking-required: Stage 2, 3, 4 | none | Docs/инварианты в самом конце |

Sequential 1→2→3→4→5. Параллелизма нет: стадии делят `AppDelegate.registerHotkey`,
`HotkeysSettingsView`, `HotkeyPreferences` — параллельные правки = merge-конфликты.

## User handoffs

| Stage | Что валидирует Андрей | Чеклист |
|---:|---|---|
| 2 | Рендер Settings + Drop срабатывание | (1) Drop→⌥D, Save, проверить срабатывание по ⌥D; (2) пресет «Hold Space», проверить удержание Space + Escape-cancel; (3) конфликт Drop с другим — строка краснеет, Save заблокирован |
| 3 | Hover-хоткеи раскрытие+действие (дефолтный layout) | (1) свёрнутый Hover, ⌥3 → раскрылся + действие 3-й позиции; (2) ⌥1 переключает Drop mode; (3) ⌥5 открывает Settings; (4) во время митинга ⌥N не ломает запись |
| 4 | Подсказки + настройка + Help | (1) ⌥1..⌥5 видны под кнопками Hover; (2) сменить hover-хоткей в Settings, Save → подсказка обновилась; (3) 5-я строка — клавиша меняется, действие Settings зафиксировано; (4) Help window перечисляет Drop + 5 hover |

## Specialist review requirements

| Area | Stage | Review skill |
|---|---:|---|
| Каждый PR | 1–5 | `pr-review` (confidence ≥80%, 5 углов) |
| Конфликт-модель (корректность) | 1 | `pr-review` усиленно (ядро фичи) |

## Open questions / blockers

| Question | Why it matters | Blocks |
|---|---|---|
| UX возврата Drop на hold Space | holdSpace не записывается combo-recorder'ом | Решено (D3/Stage 2): кнопка-пресет «Hold Space (default)» — не блокирует |
| tap-Drop (combo-Drop с gesture tap) | release-callback load-bearing при `.hold` | Deferred (D3): combo-Drop форсит `.hold` — не блокирует |
| Конфликт ⌥N с системным шорткатом другого приложения | Возможны коллизии вне приложения | Deferred (как KeyboardShortcuts warning) — не блокирует |
| Существование `EventTracker.hotkeyTrigger` | Observability hover-хоткеев | Проверить в начале Stage 3; при отсутствии — существующий аналог. Не блокирует |

## Out of scope (deferred)
- Предупреждение «хоткей занят системой/меню» (практика KeyboardShortcuts) — revisit при жалобах на коллизии.
- tap-Drop (combo-Drop с gesture tap) — revisit при запросе.
- Комбинации >2 клавиш, multi-key последовательности.
- Замена своей системы хоткеев на стороннюю библиотеку.

## Risks

| Risk | Impact | Mitigation | Stage |
|---|---|---|---|
| Снятие `migrateDropComboToHoldSpaceIfNeeded` сломает чей-то конфиг | Drop не зарегистрируется | Дефолт остаётся `.holdSpace`; тесты `test_reinit_preserves_user_combo_drop`+`test_fresh_install_defaults_to_hold_space`; existing holdSpace не затрагивается | 2 |
| combo-Drop с `.tap` начнёт запись и не остановит | Drop «залипает» в записи | D3: combo-Drop форсит `.hold`, switch disabled; `test_combo_drop_uses_hold_gesture` | 2 |
| ⌥1..⌥5 конфликтуют с существующими/системными хоткеями | Не срабатывает или перехватывает чужое | Включены в conflict-граф (Stage 1); дефолты редко заняты; настраиваемость позволяет сменить | 3,4 |
| Программное раскрытие Hover конфликтует с hover-by-mouse или policy | Двойное состояние / раскрытие во время митинга | D4: `isHoverExpanded` = (`programmaticHoverExpansion` ∪ mouse) ∧ `allowsExpansion`; `test_programmatic_expansion_respects_hover_policy` | 3 |
| Reorder layout «ломает» ожидания пользователя по ⌥N | ⌥N активирует другой инструмент | D1: позиционная модель документирована; подсказки/Settings читают живой layout; `test_hover_slot_action_follows_layout_reorder` | 3,4 |
| Регрессия в SpaceHoldMonitor при переключении Drop combo↔holdSpace | Drop перестаёт работать | `stop()` уже освобождает tap; тесты routing; user handoff | 2 |

## Handoff for execution
- **Status:** ready-for-execution
- **Recommended PR boundaries:** один PR на стадию (5 PR).
- **Recommended execution:** sequential 1→2→3→4→5.
- **Parallelizable stages:** none.
- **User validation required:** Stage 2, 3, 4 (Андрей; и финальный тест перед пушем).
- **Specialist review required:** `pr-review` на каждой стадии.
- **All hard gates passed:** yes.

Исполнение оркеструет основная сессия: на каждую стадию — dev-агент в worktree (пара
`dev-foundation`+`swiftui-expert`) + reviewer-агент (`pr-review`) на гейте. Перед пушем на
GitHub — обязательный тест Андреем (его требование).
