# Пакет Б: Toggle-активация голоса + рекордер без обязательного модификатора — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Voice-хоткеи получают выбор жеста Hold / Toggle (тап-старт → тап-стоп); рекордер принимает одиночную голую клавишу (включая Space → `.holdSpace`); чип-пресет «Hold Space» удаляется; Space остаётся hold-only.

**Architecture:** Toggle = реанимация живого `.tap`-роутинга (`dropHotkeyPressedRoute` `.tap`-ветка, «Tap-tap flow: the press both starts and stops», покрыта `AppDelegateDropFlowRouteTests`). Регистрация уже корректна: `onHotkeyReleased` подключается только при `.hold`, `isDropHoldTap` шлёт tap-combo в Carbon (без Input Monitoring), hold-combo/holdSpace — в CGEventTap. Блокировка чисто в UI/модели: `allowsGestureSwitch: false` у Drop-строки + `setDropCombo` форсит `.hold`. Рекордер: `comboIfComplete()` требует модификатор — снимаем требование; bare Space мапим на `.holdSpace`. `SpaceHoldMonitor(triggerKeyCode:requiredModifiers:[])` уже поддерживает bare-key hold по построению.

**Tech Stack:** Swift 6 (v5 mode), SwiftUI, Carbon (`RegisterEventHotKey`), CGEventTap, swift test (SPM). База — ветка `feature/hotkeys-followups` (после пакета А).

**Спека:** `docs/specs/hotkeys-followups.md` (Пакет Б).

**Рабочая директория:** `<local-checkout>`.

---

### Task B1: Рекордер — одиночная голая клавиша как валидный биндинг

Контекст: `HotkeyShortcutRecorder.record(.keyDown)` (Sources/Sidekey/Hotkeys/HotkeyPreferences.swift:754-770) возвращает шорткат только через `comboIfComplete()`, который требует и модификатор, и клавишу — голый Space/Tab записать нельзя. `Carbon.HIToolbox` в файле уже импортирован, `HotkeyTapCombo.keyTitle(for:)` мапит `kVK_Space` → "Space".

**Files:**
- Modify: `Sources/Sidekey/Hotkeys/HotkeyPreferences.swift:754-770` (`HotkeyShortcutRecorder.record`)
- Test: `Tests/SidekeyTests/Hotkeys/HotkeyRecorderBareKeyTests.swift` (новый)

- [ ] **Step 1: Падающие тесты**

Рекордер принимает `NSEvent` — в тестах использовать синтезированные события тем же способом, что существующие тесты рекордера в `Tests/SidekeyTests/Hotkeys/HotkeyPreferencesTests.swift` (найти там helper создания keyDown-события и переиспользовать; если helper приватный — продублировать локально):

```swift
import Carbon.HIToolbox
import XCTest
@testable import Sidekey

@MainActor
final class HotkeyRecorderBareKeyTests: XCTestCase {

    private func keyDownEvent(keyCode: UInt16, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testBareSpaceRecordsHoldSpace() {
        var recorder = HotkeyShortcutRecorder()
        let result = recorder.record(keyDownEvent(keyCode: UInt16(kVK_Space), characters: " "))
        XCTAssertEqual(result, .holdSpace)
    }

    func testBareLetterRecordsModifierlessCombo() {
        var recorder = HotkeyShortcutRecorder()
        let result = recorder.record(keyDownEvent(keyCode: UInt16(kVK_ANSI_T), characters: "t"))
        guard case .combo(let combo)? = result else {
            return XCTFail("expected modifierless combo, got \(String(describing: result))")
        }
        XCTAssertEqual(combo.modifiers, 0)
        XCTAssertEqual(combo.keyTitle, "T")
        // Контент хинтов: один кейкап, без модификаторного глифа.
        XCTAssertEqual(combo.contents.count, 1)
    }

    func testModifierPlusKeyStillRecordsCombo() {
        var recorder = HotkeyShortcutRecorder()
        let flagsEvent = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .option,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 58
        )!
        _ = recorder.record(flagsEvent)
        let result = recorder.record(keyDownEvent(keyCode: UInt16(kVK_ANSI_D), characters: "d"))
        guard case .combo(let combo)? = result else {
            return XCTFail("expected ⌥D combo")
        }
        XCTAssertEqual(combo.modifiers, UInt32(optionKey))
    }
}
```

Примечание: `.flagsChanged` через `NSEvent.keyEvent` может не собираться — тогда взять способ синтеза flagsChanged из существующих тестов рекордера (`HotkeyPreferencesTests`); третий тест можно свести к прямой проверке, что combo-путь не сломан, через уже существующие тесты (они остаются зелёными).

- [ ] **Step 2: Прогнать — падают**

Run: `swift test --filter HotkeyRecorderBareKeyTests`
Expected: FAIL — `testBareSpaceRecordsHoldSpace` и `testBareLetterRecordsModifierlessCombo` получают `nil` (рекордер ждёт модификатор).

- [ ] **Step 3: Реализация**

В `HotkeyShortcutRecorder.record`, ветка `case .keyDown:` (строки ~754-770) — после существующей попытки добрать модификатор из `event.modifierFlags` добавить bare-путь:

```swift
case .keyDown:
    let keyCode = UInt32(event.keyCode)
    guard let keyTitle = HotkeyTapCombo.keyTitle(for: keyCode, event: event) else {
        return nil
    }
    key = RecorderKey(
        keyCode: keyCode,
        keyTitle: keyTitle,
        content: HotkeyTapCombo(keyCode: keyCode, modifiers: 0, keyTitle: keyTitle).contents.last ?? .text(keyTitle)
    )
    if modifier == nil {
        modifier = RecorderModifier.first(in: event.modifierFlags)
    } else if modifier?.shortcutKey != nil,
              let genericModifier = modifier?.genericForCombo {
        modifier = genericModifier
    }
    if modifier == nil {
        // Bare single-key binding (no modifier held). Space maps onto the
        // dedicated `.holdSpace` sentinel — the recorder is now the way
        // back to the default after a rebind (the preset chip is gone).
        // Any other bare key becomes a modifierless combo.
        if keyCode == UInt32(kVK_Space) {
            return .holdSpace
        }
        return .combo(HotkeyTapCombo(keyCode: keyCode, modifiers: 0, keyTitle: keyTitle))
    }
    return comboIfComplete().map(HotkeyShortcut.combo)
```

- [ ] **Step 4: Прогнать — зелёные + регрессия рекордера**

Run: `swift test --filter 'HotkeyRecorderBareKeyTests|HotkeyPreferencesTests'`
Expected: PASS (старые тесты рекордера не сломаны).

- [ ] **Step 5: Commit**

```bash
git add Sources/Sidekey/Hotkeys/HotkeyPreferences.swift Tests/SidekeyTests/Hotkeys/HotkeyRecorderBareKeyTests.swift
git commit -m "feat(hotkey): рекордер принимает одиночную клавишу — bare combo, Space → holdSpace"
```

---

### Task B2: Модель — жест Drop разблокирован, holdSpace нормализуется в Hold

Контекст: `setDropCombo` (HotkeyPreferences.swift:994-997) форсит `.hold` для любого combo (D3 — устарело: tap-Drop больше не deferred). `.holdSpace` обязан оставаться `.hold` всегда (Space hold-only).

**Files:**
- Modify: `Sources/Sidekey/Hotkeys/HotkeyPreferences.swift` (`setDropCombo` → `setDropShortcut`, нормализация при загрузке `HotkeyPreferences`)
- Test: `Tests/SidekeyTests/Hotkeys/DropConfigurableTests.swift`

- [ ] **Step 1: Падающие тесты**

В `Tests/SidekeyTests/Hotkeys/DropConfigurableTests.swift` добавить:

```swift
func testSetDropShortcutComboPreservesGesture() {
    var config = HotkeyConfiguration.defaults
    config.dropVoiceGesture = .tap
    config.setDropShortcut(.combo(.optionSlash))
    XCTAssertEqual(config.dropVoiceShortcut, .combo(.optionSlash))
    XCTAssertEqual(config.dropVoiceGesture, .tap, "запись combo не должна сбрасывать выбранный жест")
}

func testSetDropShortcutHoldSpaceForcesHold() {
    var config = HotkeyConfiguration.defaults
    config.dropVoiceGesture = .tap
    config.setDropShortcut(.holdSpace)
    XCTAssertEqual(config.dropVoiceShortcut, .holdSpace)
    XCTAssertEqual(config.dropVoiceGesture, .hold, "Space hold-only")
}

func testNormalizedDropGestureFixesHoldSpaceTap() {
    var config = HotkeyConfiguration.defaults
    config.dropVoiceShortcut = .holdSpace
    config.dropVoiceGesture = .tap
    XCTAssertEqual(config.normalizedDropGesture, .hold)

    config.dropVoiceShortcut = .combo(.optionSlash)
    config.dropVoiceGesture = .tap
    XCTAssertEqual(config.normalizedDropGesture, .tap)
}
```

- [ ] **Step 2: Прогнать — падают**

Run: `swift test --filter DropConfigurableTests`
Expected: FAIL — нет `setDropShortcut` / `normalizedDropGesture`.

- [ ] **Step 3: Реализация в HotkeyConfiguration**

Заменить `setDropCombo` (994-997) на (старый метод удалить, его callsites правятся в Task B3):

```swift
/// Assign a recorded Drop binding. `.holdSpace` forces the `.hold` gesture
/// (Space is hold-only: a tap is indistinguishable from typing a space);
/// every other shortcut keeps the user's current gesture choice — `.tap`
/// (toggle) drops the release callback and runs the start/stop press
/// routing, `.hold` keeps the release-to-stop flow.
mutating func setDropShortcut(_ shortcut: HotkeyShortcut) {
    dropVoiceShortcut = shortcut
    if shortcut == .holdSpace {
        dropVoiceGesture = .hold
    }
}

/// The Drop gesture with the Space hold-only rule applied. Stale persisted
/// state (e.g. `.holdSpace` + `.tap` written by an older build) normalizes
/// to `.hold` instead of producing a tap-Space monitor that would fire on
/// every typed space.
var normalizedDropGesture: HotkeyGesture {
    dropVoiceShortcut == .holdSpace ? .hold : dropVoiceGesture
}
```

`resetDropToHoldSpace` оставить как есть (используется нормализацией/тестами).

- [ ] **Step 4: Применить нормализацию на потребителях**

Найти всех читателей `dropVoiceGesture` на пути регистрации и роутинга (а не в Settings-черновике):

```bash
grep -n 'dropVoiceGesture' Sources/Sidekey/AppDelegate.swift Sources/Sidekey/Hotkeys/HotkeyShortcutMonitor.swift
```

В `AppDelegate.registerHotkey` (~стр. 1670) заменить чтение `HotkeyPreferences.shared.dropVoiceGesture` на `HotkeyPreferences.shared.configuration.normalizedDropGesture`; в `onDropHotkeyPressed`/`onDropHotkeyReleased` (~стр. 2312+) — аналогично (`gesture:` аргументы роутов). Runtime-sink перерегистрации, передающий «свежие» значения параметрами (ROO-234 race, ~стр. 1652-1657 doc), оставить как есть — но прогонять переданное значение через ту же нормализацию пары (shortcut, gesture):

```swift
let effectiveGesture = (dropShortcut ?? ...) == .holdSpace ? .hold : (dropGesture ?? ...)
```

(точная форма — по месту; принцип: ни один монитор не должен быть собран с парой `.holdSpace` + `.tap`.)

- [ ] **Step 5: Прогнать**

Run: `swift test --filter 'DropConfigurableTests|DropReregisterRaceTests|AppDelegateDropFlowRouteTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Sidekey/Hotkeys/HotkeyPreferences.swift Sources/Sidekey/AppDelegate.swift Tests/SidekeyTests/Hotkeys/DropConfigurableTests.swift
git commit -m "feat(hotkey): setDropShortcut сохраняет жест, holdSpace нормализуется в hold"
```

---

### Task B3: Settings UI — переключатель Hold/Toggle, без пресета, предупреждения

Контекст: Drop-строка (HotkeysSettingsView.swift:73-94) держит `allowsGestureSwitch: false` + пресет-чип «Hold Space» (`ShortcutPresetSlot`); `assignShortcut` (~стр. 339-348) зовёт `setDropCombo`. `ShortcutGestureSlot` (строки 607-639) рендерит `gesture.title` («Tap»/«Hold») — для voice-строк нужен лейбл «Toggle» вместо «Tap».

**Files:**
- Modify: `Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift`
- Test: `Tests/SidekeyTests/Hotkeys/HotkeysSettingsViewTests.swift`

- [ ] **Step 1: Падающие тесты**

Посмотреть существующий стиль `HotkeysSettingsViewTests` (что там доступно: draft-логика, хелперы view). Добавить тесты на чистые правила (если view-хелперы приватны — вынести правила в internal статик-функции, как сделано с `IslandRightBandPriority`):

```swift
func testDropGestureSwitchEnabledForComboLockedForHoldSpace() {
    XCTAssertTrue(HotkeysSettingsView.dropGestureSwitchEnabled(shortcut: .combo(.optionSlash)))
    XCTAssertFalse(HotkeysSettingsView.dropGestureSwitchEnabled(shortcut: .holdSpace))
}

func testVoiceGestureTitleUsesToggleForTap() {
    XCTAssertEqual(HotkeysSettingsView.voiceGestureTitle(for: .tap), "Toggle")
    XCTAssertEqual(HotkeysSettingsView.voiceGestureTitle(for: .hold), "Hold")
}

func testDropDetailWarnsForBareKeyToggle() {
    let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: 48, modifiers: 0, keyTitle: "Tab"))
    let detail = HotkeysSettingsView.dropDetail(for: .tap, shortcut: bareTab)
    XCTAssertTrue(detail.contains("stops typing"), "голая клавиша + toggle = предупреждение")

    let holdSpaceDetail = HotkeysSettingsView.dropDetail(for: .hold, shortcut: .holdSpace)
    XCTAssertTrue(holdSpaceDetail.contains("hold-only"), "у Space объяснение, почему без toggle")

    let comboDetail = HotkeysSettingsView.dropDetail(for: .tap, shortcut: .combo(.optionSlash))
    XCTAssertFalse(comboDetail.contains("stops typing"), "модификаторный combo без предупреждения")
}
```

- [ ] **Step 2: Прогнать — падают**

Run: `swift test --filter HotkeysSettingsViewTests`
Expected: FAIL — нет статик-хелперов.

- [ ] **Step 3: Статик-правила + детали**

В `HotkeysSettingsView` (рядом с `voiceDetail`/`dropDetail`, ~стр. 447):

```swift
/// Drop's gesture switch is locked while the binding is Space: a tap-Space
/// trigger would fire on every typed space, so Space is hold-only by rule.
static func dropGestureSwitchEnabled(shortcut: HotkeyShortcut) -> Bool {
    shortcut != .holdSpace
}

/// Voice rows display `.tap` as "Toggle" (tap starts, tap stops) — for a
/// one-shot action "Tap" is accurate, for voice capture it reads wrong.
static func voiceGestureTitle(for gesture: HotkeyGesture) -> String {
    gesture == .tap ? "Toggle" : gesture.title
}

static func dropDetail(for gesture: HotkeyGesture, shortcut: HotkeyShortcut) -> String {
    if shortcut == .holdSpace {
        return "Hold starts recording; release stops and pastes. Space is hold-only — a tap is indistinguishable from typing a space."
    }
    var detail: String
    switch gesture {
    case .tap:
        detail = "Tap once to start recording, tap again to stop and paste."
    case .hold:
        detail = "Hold starts recording; release stops and pastes."
    }
    if gesture == .tap, let combo = shortcut.combo, combo.modifiers == 0 {
        detail += " While assigned, \(combo.keyTitle) stops typing its character."
    }
    return detail
}
```

Существующие приватные `dropDetail(for:)`/`voiceDetail(for:)` переключить: drop-строка зовёт новый статик с `draft.dropVoiceShortcut`; agent voice оставляет `voiceDetail(for:)` (R⌘ — модификатор, без bare-предупреждения), но её tap-лейбл тоже идёт через `voiceGestureTitle`.

- [ ] **Step 4: Перепрошить Drop-строку**

`HotkeySettingRow` Drop (строки 73-94) — включить переключатель, убрать пресет:

```swift
HotkeySettingRow(
    iconName: "mic",
    title: "Drop voice",
    detail: Self.dropDetail(for: draft.dropVoiceGesture, shortcut: draft.dropVoiceShortcut),
    gesture: draft.dropVoiceGesture,
    gestureTitle: Self.voiceGestureTitle(for: draft.dropVoiceGesture),
    allowsGestureSwitch: Self.dropGestureSwitchEnabled(shortcut: draft.dropVoiceShortcut),
    shortcutContents: shortcutContents(
        for: .dropVoice,
        fallback: draft.dropVoiceShortcut.contents
    ),
    isRecording: recordingTarget == .dropVoice,
    hasConflict: hasConflict(for: .dropVoice),
    onGestureChange: { draft.dropVoiceGesture = $0 },
    onRecord: { startRecording(.dropVoice) }
)
```

`HotkeySettingRow` — добавить поле `var gestureTitle: String? = nil` (отображаемый текст слота жеста; `nil` → `gesture.title`), прокинуть в `ShortcutGestureSlot`:

```swift
ShortcutGestureSlot(
    title: gestureTitle ?? gesture.title,
    isSwitchable: allowsGestureSwitch,
    hasConflict: hasConflict,
    onTap: { ... }  // без изменений
)
```

`ShortcutGestureSlot`: заменить `let gesture: HotkeyGesture` на `let title: String`, `Text(gesture.title)` → `Text(title)` (accessibility-строки аналогично).

Agent voice строка (51-65): `gestureTitle: Self.voiceGestureTitle(for: draft.agentVoiceGesture)`.

Удалить: `ShortcutPresetSlot` (646-675), поля `presetLabel`/`presetIsActive`/`onPreset` из `HotkeySettingRow` и их использование (560-566).

`assignShortcut` `.dropVoice` (339-348):

```swift
case .dropVoice:
    draft.setDropShortcut(shortcut)
```

- [ ] **Step 5: Сценарий «вернулся на Space»**

Проверить руками логику: рекордер вернул `.holdSpace` (Task B1) → `setDropShortcut` форсит `.hold` (Task B2) → переключатель лочится (`dropGestureSwitchEnabled == false`). Ничего дополнительно кодировать не надо — это сцепка трёх предыдущих шагов.

- [ ] **Step 6: Прогнать**

Run: `swift test --filter 'HotkeysSettingsViewTests|DropConfigurableTests'`
Expected: PASS (включая старые тесты строки Drop: тесты, пинявшие preset-чип, обновить/удалить — пресета больше нет).

- [ ] **Step 7: Commit**

```bash
git add Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift Tests/SidekeyTests/Hotkeys/HotkeysSettingsViewTests.swift
git commit -m "feat(hotkey): Drop voice — переключатель Hold/Toggle, без пресет-чипа, Space hold-only"
```

---

### Task B4: Роутинг мониторов — bare-key hold/tap

Контекст: `HotkeyShortcutMonitor.isDropHoldTap` уже верен для bare combo (`.combo` + `.hold` → CGEventTap/Input Monitoring; `.combo` + `.tap` → Carbon). `SpaceHoldMonitor(triggerKeyCode:requiredModifiers: [])` для bare-клавиши формально работает (пустые модификаторы = легаси Space-поведение: pass-through-then-delete, тапы печатают). Задача — запинить это тестами, чтобы не отъехало.

**Files:**
- Test: `Tests/SidekeyTests/Hotkeys/DropConfigurableTests.swift` (или соседний routing-тест в том же стиле — найти, где сейчас живут `routedMonitorIsCarbon`-проверки: `grep -rn routedMonitorIsCarbon Tests/`)

- [ ] **Step 1: Тесты роутинга**

```swift
func testBareKeyHoldRoutesToSpaceHoldMonitor() {
    let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: 48, modifiers: 0, keyTitle: "Tab"))
    let monitor = HotkeyShortcutMonitor(
        shortcut: bareTab,
        hotKeyIDValue: CarbonHotkeyMonitor.dropHotKeyID,
        onHotkey: {},
        onHotkeyReleased: {},
        dropHoldSwallow: HotkeyShortcutMonitor.isDropHoldTap(shortcut: bareTab, gesture: .hold)
    )
    XCTAssertTrue(monitor.routedMonitorIsSpaceHold)
}

func testBareKeyToggleRoutesToCarbon() {
    let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: 48, modifiers: 0, keyTitle: "Tab"))
    XCTAssertFalse(HotkeyShortcutMonitor.isDropHoldTap(shortcut: bareTab, gesture: .tap))
    let monitor = HotkeyShortcutMonitor(
        shortcut: bareTab,
        hotKeyIDValue: CarbonHotkeyMonitor.dropHotKeyID,
        onHotkey: {},
        dropHoldSwallow: false
    )
    XCTAssertTrue(monitor.routedMonitorIsCarbon)
}

func testModifierComboToggleRoutesToCarbon() {
    XCTAssertFalse(HotkeyShortcutMonitor.isDropHoldTap(shortcut: .combo(.optionSlash), gesture: .tap))
}
```

- [ ] **Step 2: Прогнать**

Run: `swift test --filter DropConfigurableTests`
Expected: PASS сразу (если что-то падает — чинить роутинг, не тест: правило в спеке).

- [ ] **Step 3: Commit**

```bash
git add Tests/SidekeyTests/Hotkeys/DropConfigurableTests.swift
git commit -m "test(hotkey): пин роутинга bare-key — hold → CGEventTap, toggle → Carbon"
```

---

### Task B5: Agent voice — tap = toggle-стоп (проверить и довести)

Контекст: `RightCmdGestureMonitor.agentComboRegistrations` уже различает `agentVoiceGesture` `.tap` (→ `tapAction = .voice` → `onVoiceTap`) и `.hold`. Открытый вопрос спеки: стопает ли второй тап запись. Дефолт-решение: второй тап = стоп записи (как toggle-Drop), окно агента живёт своей жизнью.

**Files:**
- Investigate: `Sources/Sidekey/Agent/RightCmdGestureMonitor.swift:630-660`, `Sources/Sidekey/AppDelegate.swift` (создание `RightCmdGestureMonitor`, callbacks `onVoiceTap`/`startVoiceAgent`/`stopVoiceAgent` — `IslandActions` биндинги на стр. 1279-1283)
- Modify (если стоп не доведён): callback `onVoiceTap` в AppDelegate
- Test: `Tests/SidekeyTests/Agent/AgentVoiceTapToggleTests.swift` (новый) или дополнение существующих `RightCmdGestureMonitorTests`

- [ ] **Step 1: Выяснить текущую tap-семантику**

```bash
grep -rn 'onVoiceTap' Sources/Sidekey/ | head
```

Прочитать обработчик: если при активной voice-записи второй тап уже останавливает (через `AgentController` / `agentPhase`-проверку) — задача сводится к Step 2 (пин тестом). Если второй тап игнорируется или перезапускает запись — Step 3.

- [ ] **Step 2: Тест на toggle-маршрут**

Завести pure-функцию маршрута (в `AppDelegate` рядом с `dropHotkeyPressedRoute`, или в `AgentController`, где уместнее по текущему коду):

```swift
enum AgentVoiceTapRoute: Equatable {
    case startVoiceCapture
    case stopVoiceCapture
    case noop
}

static func agentVoiceTapRoute(agentPhase: AgentPhase) -> AgentVoiceTapRoute {
    // Точные кейсы AgentPhase сверить по enum: capturing-voice фаза → stop;
    // idle/response-фазы → start; промежуточные (thinking/streaming) → noop.
}
```

Тест:

```swift
func testAgentVoiceTapTogglesCapture() {
    XCTAssertEqual(AppDelegate.agentVoiceTapRoute(agentPhase: .idle), .startVoiceCapture)
    XCTAssertEqual(AppDelegate.agentVoiceTapRoute(agentPhase: .voiceListening), .stopVoiceCapture)
}
```

(имена кейсов `AgentPhase` подставить из реального enum — `grep -n 'enum AgentPhase' Sources/Sidekey/`.)

- [ ] **Step 3: Довести onVoiceTap (если нужно)**

Обработчик `onVoiceTap` в AppDelegate переключить через маршрут, переиспользуя ровно те же замыкания, что у `IslandActions.startVoiceAgent`/`stopVoiceAgent` (AppDelegate:1279-1283) — никакой новой логики старта/стопа:

```swift
onVoiceTap: { [weak self] in
    guard let self else { return }
    switch AppDelegate.agentVoiceTapRoute(agentPhase: AppState.shared.agentPhase) {
    case .startVoiceCapture: self.startVoiceAgentFromHotkey()
    case .stopVoiceCapture: self.stopVoiceAgentFromHotkey()
    case .noop: break
    }
}
```

(точные имена приватных методов — те, что сейчас стоят за `startVoiceAgent:`/`stopVoiceAgent:` биндингами.)

- [ ] **Step 4: Прогнать**

Run: `swift test --filter 'AgentVoiceTapToggle|RightCmdGestureMonitorTests'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Sidekey/AppDelegate.swift Sources/Sidekey/Agent/ Tests/SidekeyTests/
git commit -m "feat(agent): tap-жест agent voice — toggle (тап-старт, тап-стоп)"
```

---

### Task B6: Документация — инвариант #6, hotkey.md, Help

**Files:**
- Modify: `CLAUDE.md` (инвариант #6)
- Modify: `docs/hotkey.md`
- Check: `Sources/Sidekey/HelpWindowController.swift`, `Sources/Sidekey/ShortcutHint.swift`, `Sources/Sidekey/DynamicIsland/IslandPassiveHints.swift` — все surfaces с жестом Drop
- Test: существующие хинт-тесты

- [ ] **Step 1: Помянуть Toggle на хинт-surfaces**

```bash
grep -rn 'dropVoiceGesture' Sources/Sidekey/HelpWindowController.swift Sources/Sidekey/ShortcutHint.swift Sources/Sidekey/DynamicIsland/IslandPassiveHints.swift
```

Везде, где жест Drop отображается словом (например «Hold» перед кейкапами), прогнать через тот же маппинг `tap → "Toggle"` (вынести `voiceGestureTitle` из `HotkeysSettingsView` в `HotkeyGesture` extension, если используется более чем в одном файле):

```swift
extension HotkeyGesture {
    /// Display name for VOICE bindings: `.tap` reads "Toggle" (tap starts,
    /// tap stops); one-shot rows keep `title` ("Tap").
    var voiceTitle: String { self == .tap ? "Toggle" : title }
}
```

(и переключить `HotkeysSettingsView.voiceGestureTitle` на этот extension — одна точка истины.)

- [ ] **Step 2: CLAUDE.md инвариант #6**

Дополнить текст инварианта #6:

```markdown
Жест Drop настраиваем: hold (дефолт) или toggle (тап-старт/тап-стоп).
Space — hold-only (тап неотличим от печати пробела). Рекордер принимает
1–2 клавиши: одиночная голая клавиша — валидный биндинг (bare Space =
пресет hold Space). Bare-key hold идёт через CGEventTap (Input Monitoring,
swallow — обычная печать клавиши сохраняется); bare-key toggle идёт через
Carbon и забирает клавишу глобально (она перестаёт печатать) — в Settings
показывается предупреждение.
```

- [ ] **Step 3: docs/hotkey.md**

Добавить раздел «Жесты voice-хоткеев»: Hold/Toggle, правило Space hold-only, голые клавиши, маршруты мониторов (таблица: holdSpace/bare+hold → CGEventTap+IM; combo+tap, bare+tap, combo+hold... — точно по `isDropHoldTap`).

- [ ] **Step 4: Прогон + commit**

Run: `swift test`
Expected: 0 failed.

```bash
git add CLAUDE.md docs/hotkey.md Sources/Sidekey/
git commit -m "docs(hotkey): инвариант #6 + hotkey.md — Hold/Toggle, Space hold-only, голые клавиши"
```

---

### Task B7: Финальная верификация пакета Б

- [ ] **Step 1: Полный прогон**

Run: `swift test`
Expected: 0 failed.

- [ ] **Step 2: Ручной чеклист на dev-билде**

```bash
doppler run --project sidekey --config dev -- ./scripts/dev-run.sh --run
```

- Settings → Hotkeys → Drop voice: пресет-чипа нет; жест переключается Hold ↔ Toggle для combo.
- Записать `⌥D`, жест Toggle → Save: тап `⌥D` старт (орб слушает), тап — стоп + транскрипция + paste; Escape во время записи — отмена.
- Записать голый `Tab`, жест Toggle: caption-предупреждение в строке; тап Tab — старт/стоп; Tab не печатает таб (ожидаемо, по предупреждению).
- Записать голый `Tab`, жест Hold: удержание — Drop; быстрый тап Tab печатает таб как обычно.
- В рекордере нажать Space → биндинг Hold Space, переключатель залочен на Hold, detail объясняет почему.
- Agent voice (R⌘): hold работает как раньше; перебиндить жест на Toggle → тап старт, тап стоп.
- `⌥1` пилюля (пакет А) не сломана.

- [ ] **Step 3: Отметить спеку + Input Monitoring заметка**

В `docs/specs/hotkeys-followups.md` — строка `> Статус: Пакет Б реализован <commit>`. Проверить: при Drop на toggle-combo и НИ ОДНОМ CGEventTap-биндинге приложение не должно требовать Input Monitoring заново (IM запрашивается только при `isDropHoldTap == true` — поведение не менялось, просто подтвердить на dev-билде).

```bash
git add docs/specs/hotkeys-followups.md
git commit -m "docs(hotkey): пакет Б (voice toggle + bare keys) реализован"
```
