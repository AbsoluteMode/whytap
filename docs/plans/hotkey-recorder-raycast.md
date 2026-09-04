# Рекордер хоткеев — Raycast-модель (release-to-commit) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Переписать `HotkeyShortcutRecorder` на модель Raycast — пользователь жмёт комбинацию клавиш, она фиксируется по отпусканию (release-to-commit), без очистки модификатора на отпускании и без мельтешения.

**Architecture:** Рекордер ведёт высоководный снимок (`captured*`) комбинации, набираемой пока что-то зажато (`held*`); по отпусканию всех клавиш снимок коммитится в `HotkeyShortcut`. Combo = маска модификаторов (любая комбинация ⌘⌥⌃⇧, сторона не важна — `carbonModifiers`) + один символ (keyCode). Голый правый модификатор (R⌘/R⌥) коммитится как `.modifier`. Структура данных (`HotkeyTapCombo`), мониторы, роутинг, конфликт-модель, агент — не трогаем.

**Tech Stack:** Swift 6 (v5 mode), SwiftUI, Carbon (`carbonModifiers`, `RegisterEventHotKey`), CGEventTap, swift test (SPM). База — ветка `feature/hotkeys-followups` (после A5/B1–B8).

**Спека:** `docs/specs/hotkey-recorder-raycast.md`.

**Рабочая директория:** `/Users/maxim/sidekey-worktrees/configurable-hotkeys`.

## File Structure

- `Sources/Sidekey/Hotkeys/HotkeyPreferences.swift` — переписывается `HotkeyShortcutRecorder` (struct, ~строки 758–862); переиспользуются `HotkeyTapCombo.carbonModifiers(from:)`, `HotkeyTapCombo.keyTitle(for:event:)`, `RecorderKey`, `modifierOnlyKey(from:)`, `HotkeyModifierKey.keycapContent`, `HotkeyGlyph`. Удаляется ставший неиспользуемым `HotkeyShortcutRecorder.RecorderModifier` (если компилятор подтвердит отсутствие ссылок). НЕ трогаем `HotkeyComboRecorder` (другой рекордер в этом же файле).
- `Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift` — в `startRecording` добавить `.keyUp` в маску локального монитора; в `handleRecordingEvent` пропускать `.keyUp` в рекордер. Caption bare-key (B3) — оставить как есть.
- `Tests/SidekeyTests/Hotkeys/HotkeyRecorderBareKeyTests.swift` — переписать под release-to-commit; удалить тесты механизма `modifierIsSeeded`/clear-on-release (B1/B8) — механизм удалён.
- `CLAUDE.md`, `docs/hotkey.md` — описание рекордера (Raycast-модель).

---

### Task R1: Переписать `HotkeyShortcutRecorder` на release-to-commit

Контекст: текущий `record(_:)` (HotkeyPreferences.swift ~804–862) возвращает шорткат на каждом событии и чистит модификатор на отпускании (`modifier = nil`), что теряет завершённый combo и мельтешит. Новый рекордер копит снимок и коммитит по отпусканию.

**Files:**
- Modify: `Sources/Sidekey/Hotkeys/HotkeyPreferences.swift` (`HotkeyShortcutRecorder`)
- Test: `Tests/SidekeyTests/Hotkeys/HotkeyRecorderBareKeyTests.swift`

- [ ] **Step 1: Переписать тест-файл под release-to-commit (падающие тесты)**

Заменить ВСЁ содержимое `Tests/SidekeyTests/Hotkeys/HotkeyRecorderBareKeyTests.swift` на:

```swift
import Carbon.HIToolbox
import XCTest
@testable import Sidekey

@MainActor
final class HotkeyRecorderBareKeyTests: XCTestCase {

    private func keyDown(_ keyCode: Int, _ chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    private func keyUp(_ keyCode: Int, _ chars: String, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(keyCode)
        )!
    }

    private func flags(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 0
        )!
    }

    // MARK: - Release-to-commit: building returns nil, release commits

    func testBareLetterCommitsOnKeyUp() {
        var r = HotkeyShortcutRecorder()
        XCTAssertNil(r.record(keyDown(kVK_ANSI_T, "t")), "пока клавиша зажата — не коммитим")
        let committed = r.record(keyUp(kVK_ANSI_T, "t"))
        guard case .combo(let c)? = committed else { return XCTFail("expected bare T combo, got \(String(describing: committed))") }
        XCTAssertEqual(c.modifiers, 0)
        XCTAssertEqual(c.keyTitle, "T")
        XCTAssertEqual(c.contents.count, 1, "один кейкап, без модификаторного глифа")
    }

    func testBareSpaceCommitsHoldSpace() {
        var r = HotkeyShortcutRecorder()
        XCTAssertNil(r.record(keyDown(kVK_Space, " ")))
        XCTAssertEqual(r.record(keyUp(kVK_Space, " ")), .holdSpace)
    }

    func testBareArrowCommitsModifierlessCombo() {
        var r = HotkeyShortcutRecorder()
        XCTAssertNil(r.record(keyDown(kVK_LeftArrow, "")))
        guard case .combo(let c)? = r.record(keyUp(kVK_LeftArrow, "")) else { return XCTFail("expected bare arrow combo") }
        XCTAssertEqual(c.modifiers, 0)
        XCTAssertEqual(c.keyCode, UInt32(kVK_LeftArrow))
    }

    // MARK: - Combo keeps the modifier through key release (the B1/B8 regression)

    func testComboKeepsModifierUntilAllReleased() {
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags(.option))                 // hold ⌥
        _ = r.record(keyDown(kVK_ANSI_D, "d", flags: .option))  // press D
        XCTAssertEqual(r.contents.count, 2, "поле показывает ⌥D пока зажато")
        XCTAssertNil(r.record(keyUp(kVK_ANSI_D, "d", flags: .option)), "D отпущена, ⌥ ещё зажат — не коммитим")
        let committed = r.record(flags([]))          // release ⌥
        guard case .combo(let c)? = committed else { return XCTFail("expected ⌥D, got \(String(describing: committed))") }
        XCTAssertEqual(c.modifiers, UInt32(optionKey))
        XCTAssertEqual(c.keyCode, UInt32(kVK_ANSI_D))
    }

    func testMultiModifierCombo() {
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags([.command, .shift]))                       // hold ⌘⇧
        _ = r.record(keyDown(kVK_ANSI_A, "a", flags: [.command, .shift]))
        _ = r.record(keyUp(kVK_ANSI_A, "a", flags: [.command, .shift]))
        let committed = r.record(flags([]))
        guard case .combo(let c)? = committed else { return XCTFail("expected ⌘⇧A") }
        XCTAssertEqual(c.modifiers, UInt32(cmdKey) | UInt32(shiftKey))
        XCTAssertEqual(c.keyCode, UInt32(kVK_ANSI_A))
    }

    // MARK: - Invalid combinations do not commit

    func testMultipleModifiersWithoutKeyDoesNotCommit() {
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags([.command, .shift]))
        XCTAssertNil(r.record(flags([])), "несколько модификаторов без символа — не коммитим")
    }

    func testLeftBareModifierDoesNotCommit() {
        // A synthesized .option flagsChanged carries no device right-bit, so it is
        // treated as a non-right (left/ambiguous) modifier — invalid alone.
        var r = HotkeyShortcutRecorder()
        _ = r.record(flags(.option))
        XCTAssertNil(r.record(flags([])), "одиночный не-правый модификатор — не коммитим")
    }

    // MARK: - Re-record after commit

    func testNewPressAfterCommitReplaces() {
        var r = HotkeyShortcutRecorder()
        _ = r.record(keyDown(kVK_ANSI_T, "t"))
        _ = r.record(keyUp(kVK_ANSI_T, "t"))          // committed bare T
        _ = r.record(keyDown(kVK_ANSI_N, "n"))         // fresh press resets
        guard case .combo(let c)? = r.record(keyUp(kVK_ANSI_N, "n")) else { return XCTFail("expected bare N") }
        XCTAssertEqual(c.keyTitle, "N")
    }

    // MARK: - keyTitle coverage retained (B1/B3): Tab / F-keys / nav / Delete

    func testTitledKeysRecordReadableTitles() {
        let cases: [(Int, String, String)] = [
            (kVK_Tab, "\t", "Tab"),
            (kVK_F5, "\u{F70E}", "F5"),
            (kVK_Home, "\u{F729}", "Home"),
            (kVK_ForwardDelete, "\u{F728}", "Forward Delete"),
            (kVK_Delete, "\u{7F}", "Delete")
        ]
        for (code, chars, title) in cases {
            var r = HotkeyShortcutRecorder()
            _ = r.record(keyDown(code, chars))
            guard case .combo(let c)? = r.record(keyUp(code, chars)) else { return XCTFail("expected combo for \(title)") }
            XCTAssertEqual(c.keyTitle, title, "keyCode \(code) → \(title)")
        }
    }

    // MARK: - Seeded display

    func testSeededComboShowsInContents() {
        let r = HotkeyShortcutRecorder(shortcut: .combo(.optionD))
        XCTAssertEqual(r.contents.count, 2, "seeded ⌥D показывается до ввода")
    }

    func testSeededModifierOnlyShowsInContents() {
        let r = HotkeyShortcutRecorder(shortcut: .modifier(.rightOption))
        XCTAssertEqual(r.contents.count, 1)
    }
}
```

- [ ] **Step 2: Прогнать — падают/не компилируются**

Run: `swift test --filter HotkeyRecorderBareKeyTests`
Expected: FAIL/compile error — старый `record` возвращает на keyDown, нет release-to-commit, нет нужного `contents`; новые тесты красные.

- [ ] **Step 3: Переписать `HotkeyShortcutRecorder`**

Заменить весь блок `struct HotkeyShortcutRecorder { ... }` (от `struct HotkeyShortcutRecorder` до его закрывающей `}` перед `struct HotkeyConfiguration`) на:

```swift
struct HotkeyShortcutRecorder {
    // High-water snapshot of the combination built since the field was last
    // empty. Survives key release — release is the COMMIT signal, never a
    // clear (the B1/B8 regression was clearing the modifier on release).
    private var capturedModifierMask: UInt32 = 0
    private var capturedKey: RecorderKey?
    /// A lone RIGHT modifier (R⌘/R⌥) captured as a modifier-only binding.
    /// Only right modifiers are detectable/safe standalone (left ⌘ fires on
    /// every ⌘C); set from `modifierOnlyKey(from:)`, cleared when a key or a
    /// non-right modifier joins.
    private var capturedRightModifier: HotkeyModifierKey?
    // Currently physically held.
    private var heldModifierMask: UInt32 = 0
    private var heldKeyCodes: Set<UInt32> = []
    /// True while a fresh combination is being held. A press while not building
    /// resets the captured snapshot (start over / re-record); commit fires only
    /// when `building` and everything has been released.
    private var building = false

    init(shortcut: HotkeyShortcut? = nil) {
        switch shortcut {
        case .combo(let combo):
            capturedModifierMask = combo.modifiers
            capturedKey = RecorderKey(
                keyCode: combo.keyCode,
                keyTitle: combo.keyTitle,
                content: combo.contents.last ?? .text(combo.keyTitle)
            )
        case .modifier(let key):
            capturedRightModifier = key
        case .holdSpace:
            capturedKey = RecorderKey(
                keyCode: UInt32(kVK_Space),
                keyTitle: "Space",
                content: HotkeyTapCombo(keyCode: UInt32(kVK_Space), modifiers: 0, keyTitle: "Space").contents.last ?? .text("Space")
            )
        case nil:
            break
        }
    }

    var contents: [KeycapContent] {
        if capturedKey == nil, capturedModifierMask == 0, let rm = capturedRightModifier {
            return [rm.keycapContent]
        }
        var result = Self.modifierContents(for: capturedModifierMask)
        if let capturedKey {
            result.append(capturedKey.content)
        }
        return result
    }

    mutating func reset() {
        capturedModifierMask = 0
        capturedKey = nil
        capturedRightModifier = nil
        heldModifierMask = 0
        heldKeyCodes = []
        building = false
    }

    /// Feed a recording event. Returns the committed `HotkeyShortcut` once the
    /// whole combination is released; nil while building or on a non-committing
    /// event. Escape is intercepted by the caller (cancel) before `record`.
    mutating func record(_ event: NSEvent) -> HotkeyShortcut? {
        switch event.type {
        case .keyDown:
            let keyCode = UInt32(event.keyCode)
            guard let keyTitle = HotkeyTapCombo.keyTitle(for: keyCode, event: event) else {
                return nil
            }
            if !building {
                resetCaptured()
                building = true
            }
            heldKeyCodes.insert(keyCode)
            capturedKey = RecorderKey(
                keyCode: keyCode,
                keyTitle: keyTitle,
                content: HotkeyTapCombo(keyCode: keyCode, modifiers: 0, keyTitle: keyTitle).contents.last ?? .text(keyTitle)
            )
            capturedRightModifier = nil
            capturedModifierMask |= HotkeyTapCombo.carbonModifiers(from: event.modifierFlags)
            return nil

        case .keyUp:
            heldKeyCodes.remove(UInt32(event.keyCode))
            return commitIfReleased()

        case .flagsChanged:
            let newMask = HotkeyTapCombo.carbonModifiers(from: event.modifierFlags)
            let added = newMask & ~heldModifierMask
            if added != 0, !building {
                resetCaptured()
                building = true
            }
            heldModifierMask = newMask
            capturedModifierMask |= newMask
            if capturedKey == nil {
                if let rm = modifierOnlyKey(from: event) {
                    capturedRightModifier = rm        // lone right modifier
                } else if newMask != 0 {
                    capturedRightModifier = nil        // multi/left → not modifier-only
                }
                // newMask == 0 (release): keep capturedRightModifier high-water.
            }
            return commitIfReleased()

        default:
            return nil
        }
    }

    private mutating func resetCaptured() {
        capturedModifierMask = 0
        capturedKey = nil
        capturedRightModifier = nil
    }

    private mutating func commitIfReleased() -> HotkeyShortcut? {
        guard building, heldModifierMask == 0, heldKeyCodes.isEmpty else {
            return nil
        }
        building = false
        if let capturedKey {
            if capturedKey.keyCode == UInt32(kVK_Space), capturedModifierMask == 0 {
                return .holdSpace
            }
            return .combo(HotkeyTapCombo(
                keyCode: capturedKey.keyCode,
                modifiers: capturedModifierMask,
                keyTitle: capturedKey.keyTitle
            ))
        }
        if let capturedRightModifier {
            return .modifier(capturedRightModifier)
        }
        return nil   // invalid (left/multi modifier with no key)
    }

    private static func modifierContents(for mask: UInt32) -> [KeycapContent] {
        var result: [KeycapContent] = []
        if mask & UInt32(controlKey) != 0 { result.append(.text(HotkeyGlyph.control)) }
        if mask & UInt32(optionKey) != 0 { result.append(.text(HotkeyGlyph.option)) }
        if mask & UInt32(shiftKey) != 0 { result.append(.text(HotkeyGlyph.shift)) }
        if mask & UInt32(cmdKey) != 0 { result.append(.text(HotkeyGlyph.command)) }
        return result
    }

    private func modifierOnlyKey(from event: NSEvent) -> HotkeyModifierKey? {
        let rawFlags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
        if HotkeyFlags.isOnly(.rightCommand, rawFlags) {
            return .rightCommand
        }
        if HotkeyFlags.isOnly(.rightOption, rawFlags) {
            return .rightOption
        }
        return nil
    }

    private struct RecorderKey {
        let keyCode: UInt32
        let keyTitle: String
        let content: KeycapContent
    }
}
```

Примечания:
- Если после замены компилятор сообщит, что `HotkeyShortcutRecorder.RecorderModifier` (старый вложённый тип со `specs`/`genericForCombo`/`modifierOnly`/`first`) больше не используется — удалить его. НЕ путать с `RecorderModifier` внутри `HotkeyComboRecorder` (тот не трогаем).
- `RecorderKey` оставлен вложённым (используется выше). `modifierOnlyKey` перенесён внутрь (он и был приватным методом рекордера).
- `HotkeyFlags.isOnly`, `HotkeyTapCombo.carbonModifiers`, `HotkeyTapCombo.keyTitle`, `HotkeyModifierKey.keycapContent`, `HotkeyGlyph.*` уже существуют в файле/проекте.

- [ ] **Step 4: Прогнать — зелёные**

Run: `swift test --filter HotkeyRecorderBareKeyTests`
Expected: PASS (все тесты Step 1).

- [ ] **Step 5: Регрессия рекордерных консьюмеров**

Run: `swift test --filter 'HotkeyRecorderBareKeyTests|HotkeyPreferencesTests|DropConfigurableTests|HotkeysSettingsViewTests|HotkeyConflictModelTests'`
Expected: PASS. Если падает тест, пинявший удалённый механизм (`modifierIsSeeded`, clear-on-release, B8 `testSeededModifierOnlyBindingSurvivesKeyRelease`/`testHeldComboPrefixStillClearsOnReleaseForBareComeback`) — он жил в `HotkeyRecorderBareKeyTests` и уже удалён Step 1; если ссылки на эти механизмы остались в других файлах — удалить их (механизма больше нет). Любой ДРУГОЙ упавший тест чинить по существу, не подгоняя.

- [ ] **Step 6: Commit**

```bash
git add Sources/Sidekey/Hotkeys/HotkeyPreferences.swift Tests/SidekeyTests/Hotkeys/HotkeyRecorderBareKeyTests.swift
git commit -m "feat(hotkey): рекордер на release-to-commit (Raycast-модель)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task R2: Подать `.keyUp` в рекордер из Settings

Контекст: release-to-commit требует событий отпускания. Сейчас локальный монитор `startRecording` слушает только `[.keyDown, .flagsChanged]`, а `handleRecordingEvent` отбрасывает всё кроме keyDown/flagsChanged. Без `.keyUp` голая клавиша (нет модификатора, нет flagsChanged-release) никогда не закоммитится. `handleRecordingEvent` уже коммитит в draft на ненулевой возврат `record` — менять эту логику не надо, только пропустить `.keyUp`.

**Files:**
- Modify: `Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift` (`startRecording` ~311, `handleRecordingEvent` ~332)
- Test: `Tests/SidekeyTests/Hotkeys/HotkeysSettingsViewTests.swift`

- [ ] **Step 1: Пин-тест монитора (падающий)**

В `Tests/SidekeyTests/Hotkeys/HotkeysSettingsViewTests.swift` добавить (рядом с прочими source-pin тестами; helper чтения исходника `source(...)` там уже есть — переиспользовать его именем, как в соседних тестах):

```swift
func testRecordingMonitorListensForKeyUp() throws {
    // Release-to-commit needs keyUp; the local monitor and the event guard
    // must both admit .keyUp or a bare key (no modifier release) never commits.
    let src = try Self.source("Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift")
    XCTAssertTrue(
        src.contains("matching: [.keyDown, .keyUp, .flagsChanged]"),
        "startRecording must listen for keyUp (release-to-commit)."
    )
    XCTAssertTrue(
        src.contains("event.type == .keyUp"),
        "handleRecordingEvent must pass keyUp through to the recorder."
    )
}
```

(Сверить точное имя helper'а чтения исходника в этом файле — если он называется иначе, использовать существующий; не плодить новый.)

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter HotkeysSettingsViewTests/testRecordingMonitorListensForKeyUp`
Expected: FAIL — монитор пока без `.keyUp`.

- [ ] **Step 3: Добавить `.keyUp` в монитор и guard**

В `startRecording` заменить:

```swift
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
```

на:

```swift
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
```

В `handleRecordingEvent` заменить строку guard:

```swift
        guard event.type == .keyDown || event.type == .flagsChanged else { return nil }
```

на:

```swift
        guard event.type == .keyDown || event.type == .keyUp || event.type == .flagsChanged else { return nil }
```

(Escape-перехват выше остаётся: `if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) { stopRecording(); return nil }` — Escape по-прежнему отменяет запись до вызова `record`.)

- [ ] **Step 4: Прогнать**

Run: `swift test --filter 'HotkeysSettingsViewTests|HotkeyRecorderBareKeyTests'`
Expected: PASS. (Caption-тесты B3 остаются зелёными — мы их не трогаем.)

- [ ] **Step 5: Полный прогон**

Run: `swift test`
Expected: 0 failures (известный неотносящийся flaky: `MeetingPolling` CGImageDestinationFinalize — перезапустить, если единственная).

- [ ] **Step 6: Commit**

```bash
git add Sources/Sidekey/Hotkeys/HotkeysSettingsView.swift Tests/SidekeyTests/Hotkeys/HotkeysSettingsViewTests.swift
git commit -m "feat(hotkey): Settings подаёт keyUp в рекордер — release-to-commit работает в приложении

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task R3: Документация — рекордер = Raycast-модель

**Files:**
- Modify: `CLAUDE.md` (инвариант #6 — строка про рекордер)
- Modify: `docs/hotkey.md` (раздел рекордера)

- [ ] **Step 1: CLAUDE.md инвариант #6**

Найти в инварианте #6 фрагмент про рекордер (`Рекордер (\`HotkeyShortcutRecorder\`) принимает 1–2 клавиши…`) и заменить его описание на release-to-commit:

```
Рекордер (`HotkeyShortcutRecorder`) — Raycast-модель: жмёшь комбинацию,
по ОТПУСКАНИЮ фиксируется (release-to-commit, не очищается на отпускании).
Хоткей = маска модификаторов (любая комбинация ⌘⌥⌃⇧, сторона не важна) +
один символ (keyCode); голый символ ок (Space → `.holdSpace`); голый
ОДИНОЧНЫЙ модификатор — только правые R⌘/R⌥ (device-bit). Escape =
отмена записи; применение в рантайм — по Save (`apply(draft)`).
```

(Сохранить связность инварианта — встроить, не приклеивать; остальное #6 — Drop hold/toggle, Space hold-only, мониторы — не менять.)

- [ ] **Step 2: docs/hotkey.md**

В разделе про рекордер/запись (где описана прежняя модель «1 модификатор + клавиша») заменить описание на Raycast-модель: release-to-commit, комбинация модификаторов (без left/right) + один символ, голый символ, голый правый модификатор, Escape-отмена, Save-применение, триггер по keyCode. Если есть строки, утверждающие старую модель (clear-on-release, «один модификатор») — заменить их.

- [ ] **Step 3: Прогон + commit**

Run: `swift test`
Expected: 0 failures (доки код не трогают; прогон — sanity).

```bash
git add CLAUDE.md docs/hotkey.md
git commit -m "docs(hotkey): рекордер = Raycast release-to-commit (инвариант #6 + hotkey.md)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task R4: Финальная верификация

- [ ] **Step 1: Полный прогон**

Run: `swift test`
Expected: 0 failures.

- [ ] **Step 2: Dev-билд + ручной чеклист**

```bash
doppler run --project sidekey --config dev -- ./scripts/dev-run.sh --run
```

- Settings → Hotkeys → любая строка → Record: жмёшь `⌘⇧A`, отпускаешь → в поле фиксируется `⌘⇧A` (модификаторы не теряются).
- Жмёшь `⌥D`, отпускаешь → `⌥D` (не превращается в `D` на отпускании — прежний баг).
- Жмёшь голую букву `N`, отпускаешь → `N`. Голую стрелку → стрелка. `Space` → Hold Space.
- Drop voice: правый `⌥` (один), отпускаешь → фиксируется как модификатор; Save → удержание R⌥ запускает Drop (рантайм).
- Несколько модификаторов без символа (`⌘⇧`) или одиночный ЛЕВЫЙ модификатор → в поле не фиксируется (ждёт символ).
- Escape во время записи → поле не меняет биндинг.
- Save применяет; Revert/Reset работают. Агент (R⌘) и hover `⌥1..⌥5` не затронуты.
- voice-строки показывают tap/hold (Toggle/Hold); остальные — tap.

- [ ] **Step 3: Отметить спеку**

В `docs/specs/hotkey-recorder-raycast.md` — строка `> Статус: реализован <commit>`.

```bash
git add docs/specs/hotkey-recorder-raycast.md
git commit -m "docs(hotkey): рекордер на Raycast-модель реализован

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
