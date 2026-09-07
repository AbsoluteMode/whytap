# Пакет А: Полировка hover-хоткеев — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌥1 переключает Smart/Fast с пилюлей `ON Smart`/`ON Fast` в правом крыле; inline-панели по хоткею открываются без hover-in промелька; хинты над тайлами — два мини-кейкапа.

**Architecture:** Транзиентная статус-пилюля Drop Mode уже существует (`IslandDropModeStatusView` + `showDropModeStatus` в `IslandView`, копия «ON Smart/Fast» готова) — её дёргает только клик по тайлу. Добавляем мостик: `AppState.publishDropModeHotkeyToggle` (mode + монотонный токен) из хоткей-пути `AppDelegate.onHoverSlotActivated`, `IslandView.onChange` его потребляет. Промельк лечится pure-функцией `hoverExpansionAnimation(programmatic:)` (nil-анимация для программного раскрытия). Хинты: `KeycapView` уже умеет tiny-чип (`tinyCornerRadius` — заготовка), добавляем `chrome`-параметр + стиль `.keycaps` в `HotkeyHintView`.

**Tech Stack:** Swift 6 (v5 mode), SwiftUI, swift test (SPM). База — ветка `feature/hotkeys-followups` (поверх `feature/configurable-hotkeys`, PR #314).

**Спека:** `docs/specs/hotkeys-followups.md` (Пакет А).

**Рабочая директория:** `<local-checkout>`.

---

### Task A1: ⌥1 → переключение режима + пилюля `ON Smart`/`ON Fast`

Контекст бага: `⌥1` → `onHoverSlotActivated(1)` → `.toggleDropMode` → `effect.invoke` → `toggleDropModeFromIsland()` — режим в `UserPreferencesCache` реально переключается, но возвращённый mode выбрасывается: ни пилюли, ни обновления `@State dropMode` в `IslandView`. Выглядит как «не работает».

**Files:**
- Modify: `Sources/Sidekey/AppState.swift` (рядом с `programmaticHoverPanelRequest`, ~стр. 131)
- Modify: `Sources/Sidekey/AppDelegate.swift:1959-1976` (`onHoverSlotActivated`)
- Modify: `Sources/Sidekey/DynamicIsland/IslandView.swift` (~стр. 992, блок `.onChange`)
- Test: `Tests/SidekeyTests/Hotkeys/DropModeHotkeyToggleTests.swift` (новый)

- [ ] **Step 1: Написать падающий тест на транзиентное событие**

```swift
import XCTest
@testable import Sidekey

@MainActor
final class DropModeHotkeyToggleTests: XCTestCase {

    func testPublishStoresModeAndBumpsToken() {
        let state = AppState.shared
        state.publishDropModeHotkeyToggle(.smart)
        let first = state.dropModeHotkeyToggle
        XCTAssertEqual(first?.mode, .smart)

        state.publishDropModeHotkeyToggle(.smart)
        let second = state.dropModeHotkeyToggle
        XCTAssertEqual(second?.mode, .smart)
        // Тот же mode дважды подряд = два разных события (токен растёт),
        // иначе SwiftUI .onChange не сработает на повторном ⌥1⌥1.
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThan(second?.token ?? 0, first?.token ?? 0)
    }

    func testPublishAlternatingModes() {
        let state = AppState.shared
        state.publishDropModeHotkeyToggle(.fast)
        XCTAssertEqual(state.dropModeHotkeyToggle?.mode, .fast)
        state.publishDropModeHotkeyToggle(.smart)
        XCTAssertEqual(state.dropModeHotkeyToggle?.mode, .smart)
    }
}
```

- [ ] **Step 2: Прогнать тест — убедиться, что падает**

Run: `swift test --filter DropModeHotkeyToggleTests`
Expected: FAIL — `AppState has no member 'publishDropModeHotkeyToggle'`.

- [ ] **Step 3: Добавить событие в AppState**

В `Sources/Sidekey/AppState.swift`, сразу после `@Published var programmaticHoverPanelRequest: HoverPanelRequest?`:

```swift
/// One-shot "Drop mode was toggled by its hover-slot hotkey" event.
/// `IslandView` observes it to sync its local `dropMode` state and to show
/// the same transient `ON Smart`/`ON Fast` right-band status the tile click
/// shows. The monotonic `token` makes two consecutive toggles to the same
/// mode distinct `@Published` events (mirrors `HoverPanelRequest`).
@Published var dropModeHotkeyToggle: DropModeHotkeyToggle?

private var dropModeHotkeyToggleToken = 0

func publishDropModeHotkeyToggle(_ mode: TranscriptionMode) {
    dropModeHotkeyToggleToken += 1
    dropModeHotkeyToggle = DropModeHotkeyToggle(
        mode: mode,
        token: dropModeHotkeyToggleToken
    )
}
```

Рядом (вне класса, в том же файле) — сам тип:

```swift
/// Payload of `AppState.dropModeHotkeyToggle`.
struct DropModeHotkeyToggle: Equatable {
    let mode: TranscriptionMode
    let token: Int
}
```

- [ ] **Step 4: Прогнать тест — зелёный**

Run: `swift test --filter DropModeHotkeyToggleTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Публиковать событие из хоткей-пути**

В `Sources/Sidekey/AppDelegate.swift`, `onHoverSlotActivated(index:)` — заменить switch (строки ~1959-1976):

```swift
switch effect {
case .openPanel(let panel):
    // Inline-panel tools render their sub-panel INSIDE the drawer, so
    // they need programmatic expansion (still gated on `allowsExpansion`
    // in `IslandView`, D4).
    AppState.shared.programmaticHoverExpansion = true
    hoverPanelRequestToken += 1
    AppState.shared.programmaticHoverPanelRequest = HoverPanelRequest(
        panel: panel,
        token: hoverPanelRequestToken
    )
case .toggleDropMode:
    // The keyboard path bypasses the hover tile, so the toggled mode must
    // be published for IslandView to sync its tile state AND show the
    // transient ON Smart/Fast right-band status — otherwise the toggle is
    // invisible and reads as "the hotkey does nothing".
    let newMode = IslandPanel.shared.actions.toggleDropMode()
    AppState.shared.publishDropModeHotkeyToggle(newMode)
case .openSettings, .openHotkeys, .openNotes, .quit:
    // Action/navigate tools open their own surfaces (window / toggle)
    // instantly — forcing the drawer open here would flash an empty
    // Hover for ~4s (Stage 3 review fix). Run the effect directly
    // without requesting expansion.
    effect.invoke(on: IslandPanel.shared.actions)
}
```

- [ ] **Step 6: Потребить событие в IslandView**

В `Sources/Sidekey/DynamicIsland/IslandView.swift`, после `.onChange(of: appState.programmaticHoverExpansion)` блока (~стр. 1005, после закрытия его скобки):

```swift
// ⌥N Drop-Mode toggle: sync the tile's local state and show the same
// transient right-band ON Smart/Fast status the tile click shows. The
// monotonic token makes repeated toggles to the same mode re-fire.
.onChange(of: appState.dropModeHotkeyToggle) { _, toggle in
    guard let toggle else { return }
    dropMode = toggle.mode
    showDropModeStatus(toggle.mode)
}
```

- [ ] **Step 7: Полный прогон тестов**

Run: `swift test`
Expected: все зелёные (база PR #314: 2529 passed; новые +2).

- [ ] **Step 8: Commit**

```bash
git add Sources/Sidekey/AppState.swift Sources/Sidekey/AppDelegate.swift Sources/Sidekey/DynamicIsland/IslandView.swift Tests/SidekeyTests/Hotkeys/DropModeHotkeyToggleTests.swift
git commit -m "fix(hotkey): ⌥N Drop-Mode toggle публикует событие — пилюля ON Smart/Fast в правом крыле"
```

---

### Task A2: Программное раскрытие hover без анимации-промелька

Контекст: `⌥2`/`⌥3` (inline-панели) ставят `programmaticHoverExpansion = true`, и `IslandView` проигрывает ту же `hoverMotion`-анимацию, что и наведение мыши + анимацию смены `hoverPanelMode` — отсюда «промельк ховера». Программное раскрытие должно появляться мгновенно.

**Files:**
- Modify: `Sources/Sidekey/DynamicIsland/IslandView.swift:953-954` (`.animation` модификаторы) + статическая секция рядом с `passiveHintGateAnimation` (~стр. 313) + onHover-блок, где `programmaticHoverExpansion = false` (~стр. 955-965)
- Test: `Tests/SidekeyTests/DynamicIsland/IslandHoverPanelControlTests.swift`

- [ ] **Step 1: Падающий тест на pure-функцию анимации**

В `Tests/SidekeyTests/DynamicIsland/IslandHoverPanelControlTests.swift` добавить:

```swift
func testHoverExpansionAnimationIsNilForProgrammaticPath() {
    XCTAssertNil(IslandView.hoverExpansionAnimation(programmatic: true))
}

func testHoverExpansionAnimationIsHoverMotionForMousePath() {
    XCTAssertNotNil(IslandView.hoverExpansionAnimation(programmatic: false))
}
```

- [ ] **Step 2: Прогнать — падает**

Run: `swift test --filter IslandHoverPanelControlTests`
Expected: FAIL — `IslandView has no member 'hoverExpansionAnimation'`.

- [ ] **Step 3: Реализовать gate**

В `Sources/Sidekey/DynamicIsland/IslandView.swift`, рядом со `static func passiveHintGateAnimation` (~стр. 313):

```swift
/// Animation for the hover drawer's expand/collapse and panel-mode swap.
/// The mouse path animates with the standard `hoverMotion`; a hotkey-driven
/// (programmatic) expansion renders instantly — replaying the hover-in
/// motion for a keyboard action reads as a stray flicker.
static func hoverExpansionAnimation(programmatic: Bool) -> Animation? {
    programmatic ? nil : hoverMotion
}
```

Строки 953-954 заменить:

```swift
.animation(
    Self.hoverExpansionAnimation(programmatic: appState.programmaticHoverExpansion),
    value: isHoverExpanded
)
.animation(
    Self.hoverExpansionAnimation(programmatic: appState.programmaticHoverExpansion),
    value: hoverPanelMode
)
```

- [ ] **Step 4: Мышь перехватывает — сбрасывать флаг на входе курсора**

Сейчас `appState.programmaticHoverExpansion = false` выставляется только на mouse-exit (~стр. 963). Найти onHover/mouse-enter обработчик острова (блок, где меняется `isHovering`) и сбрасывать флаг при ВХОДЕ курсора тоже — чтобы после программного открытия наведение мыши возвращало обычные анимации:

```swift
// Mouse takes over the drawer: drop the programmatic latch in both
// directions. On exit it collapses the keyboard-opened drawer (D4);
// on enter it hands animation control back to the hover path.
appState.programmaticHoverExpansion = false
```

(точное место — рядом с существующим сбросом; `isHovering == true` держит drawer открытым, так что поведение не меняется, меняется только источник анимации.)

- [ ] **Step 5: Прогнать тесты**

Run: `swift test --filter IslandHoverPanelControlTests`
Expected: PASS.

- [ ] **Step 6: Ручная проверка (визуальная)**

```bash
doppler run --project sidekey --config dev -- ./scripts/dev-run.sh --run
```

Проверить: `⌥2` (Notifs) и `⌥3` (History) открываются мгновенно, без промелька hover-in; обычное наведение мыши анимируется как раньше; mouse-exit после `⌥3` сворачивает панель плавно.

- [ ] **Step 7: Commit**

```bash
git add Sources/Sidekey/DynamicIsland/IslandView.swift Tests/SidekeyTests/DynamicIsland/IslandHoverPanelControlTests.swift
git commit -m "fix(island): программное раскрытие hover по ⌥N — без hover-in анимации"
```

---

### Task A3: Хинты над тайлами — два мини-кейкапа `[⌥][1]` (вариант 3)

Контекст: сейчас `hoverSlotHint` рендерит `HotkeyHintView(style: .bare, size: .tiny)` — голые глифы без чипов (в `KeycapView` `drawsCapChrome = size != .tiny` прячет чип). Вариант 3 = каждый глиф в собственном мини-чипе, без внешней капсулы. Заготовка уже есть: `tinyCornerRadius` в `KeycapView` описан как «fallback for any future tiny-but-contained caller».

**Files:**
- Modify: `Sources/Sidekey/KeycapView.swift` (параметр `chrome`)
- Modify: `Sources/Sidekey/HotkeyHintView.swift` (стиль `.keycaps`)
- Modify: `Sources/Sidekey/DynamicIsland/IslandView.swift:2048-2057` (`hoverSlotHint`)
- Modify: `docs/hotkey.md` (описание нового стиля)
- Test: `Tests/SidekeyTests/KeycapViewTests.swift`, `Tests/SidekeyTests/HotkeyHintViewTests.swift`, `Tests/SidekeyTests/Hotkeys/HoverHintsTests.swift`

- [ ] **Step 1: Падающие тесты**

В `Tests/SidekeyTests/KeycapViewTests.swift`:

```swift
func testTinyCapHidesChromeByDefault() {
    let cap = KeycapView(content: .text("1"), size: .tiny)
    XCTAssertFalse(cap.showsCapChrome)
}

func testTinyCapDrawsChromeWhenForced() {
    let cap = KeycapView(content: .text("1"), size: .tiny, chrome: .chip)
    XCTAssertTrue(cap.showsCapChrome)
}

func testRegularCapKeepsChromeRegardlessOfChromeMode() {
    XCTAssertTrue(KeycapView(content: .text("Q"), size: .regular).showsCapChrome)
    XCTAssertTrue(KeycapView(content: .text("Q"), size: .regular, chrome: .chip).showsCapChrome)
}
```

В `Tests/SidekeyTests/HotkeyHintViewTests.swift`:

```swift
func testKeycapsStyleStripsContainerButKeepsCapChips() {
    let hint = HotkeyHintView(
        contents: [.text("⌥"), .text("1")],
        style: .keycaps,
        size: .tiny
    )
    XCTAssertFalse(hint.showsContainer)
    XCTAssertEqual(hint.capChrome, .chip)
}

func testBareStyleKeepsAutomaticCapChrome() {
    let hint = HotkeyHintView(
        contents: [.text("⌥"), .text("1")],
        style: .bare,
        size: .tiny
    )
    XCTAssertEqual(hint.capChrome, .automatic)
}
```

- [ ] **Step 2: Прогнать — падают**

Run: `swift test --filter 'KeycapViewTests|HotkeyHintViewTests'`
Expected: FAIL — нет `chrome:`, нет `.keycaps`, нет `showsCapChrome`/`capChrome`.

- [ ] **Step 3: KeycapView — параметр chrome**

В `Sources/Sidekey/KeycapView.swift` над структурой:

```swift
/// Whether a cap draws its rounded-chip background+border.
/// `.automatic` — the existing rule (every tier except `.tiny` draws chrome;
/// `.tiny` renders bare glyphs for the light overline hints).
/// `.chip` — force the chip chrome even at `.tiny` (the Hover-slot keycap-pair
/// hints: each glyph in its own mini keycap, per docs/hotkey.md).
enum KeycapChrome: Equatable {
    case automatic
    case chip
}
```

В `KeycapView`: новое поле + параметр designated init (с дефолтом, чтобы все существующие callsites не менялись):

```swift
let chrome: KeycapChrome

init(
    content: KeycapContent,
    accessibilityLabel: String? = nil,
    size: KeycapSize = .regular,
    chrome: KeycapChrome = .automatic
) {
    self.content = content
    self.customAccessibilityLabel = accessibilityLabel
    self.size = size
    self.chrome = chrome
}
```

(в back-compat convenience-инициализаторах ничего не менять — они зовут designated, который получит дефолт `.automatic`.)

Заменить `drawsCapChrome` (~стр. 194):

```swift
/// `.tiny` caps render as bare glyphs by default; `.chip` chrome forces the
/// rounded cap even at `.tiny` (Hover-slot keycap-pair hints). The larger
/// tiers always draw the keycap chrome.
private var drawsCapChrome: Bool {
    chrome == .chip || size != .tiny
}

/// Exposed `internal` so unit tests pin the chrome rule without
/// introspecting the rendered tree.
var showsCapChrome: Bool { drawsCapChrome }
```

- [ ] **Step 4: HotkeyHintView — стиль .keycaps**

В `Sources/Sidekey/HotkeyHintView.swift`:

`HotkeyHintStyle` (~стр. 101) — добавить кейс с докой:

```swift
/// - `.keycaps` — no outer capsule (like `.bare`), but every cap draws its
///   own mini keycap chip. Used by the Hover-slot hints above the tiles:
///   `[⌥][1]` reads as two tiny keys rather than loose glyphs.
enum HotkeyHintStyle {
    case container
    case bare
    case keycaps
}
```

В `HotkeyHintView`:
- `var showsContainer: Bool { style == .container }` — уже корректен для `.keycaps` (false), не трогать.
- Добавить проекцию chrome + прокинуть в `KeycapView` (в `body`, ~стр. 300):

```swift
/// Cap chrome derived from the hint style: `.keycaps` forces per-cap chips,
/// the other styles keep the size-tier default. Exposed `internal` for tests.
var capChrome: KeycapChrome {
    style == .keycaps ? .chip : .automatic
}
```

```swift
ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
    KeycapView(content: content, size: size, chrome: capChrome)
}
```

- Проверить все `switch style`/тернарники в файле (`containerFill`, `containerWash`, `containerStroke`, `horizontalPadding`, `verticalPadding` используют `showsContainer` — `.keycaps` автоматически получает прозрачный контейнер и нулевые паддинги; если где-то матчится `style` напрямую — добавить `.keycaps` в ветку `.bare`).

- [ ] **Step 5: Переключить hoverSlotHint + межкейкапный зазор**

В `Sources/Sidekey/DynamicIsland/IslandView.swift`, `hoverSlotHint(for:)` (~стр. 2048):

```swift
HotkeyHintView(
    contents: shortcuts[offset].contents,
    style: .keycaps,
    size: .tiny
)
```

В `HotkeyHintView` tiny-зазор оставить 2pt (`tinyElementSpacing`) — чипы с рамкой при 2pt читаются раздельно (как в утверждённом мокапе «вариант 3»).

- [ ] **Step 6: Обновить HoverHintsTests**

В `Tests/SidekeyTests/Hotkeys/HoverHintsTests.swift` найти тесты, пиняющие `style == .bare` для hover-хинтов, и заменить ожидание на `.keycaps` (+ `capChrome == .chip`). Если тест называется в духе `testHoverSlotHintIsBareTiny` — переименовать в `testHoverSlotHintIsKeycapsTiny`.

- [ ] **Step 7: Прогнать всё**

Run: `swift test --filter 'KeycapViewTests|HotkeyHintViewTests|HoverHintsTests'`
Expected: PASS.

- [ ] **Step 8: docs/hotkey.md**

В разделе про представление хоткеев добавить:

```markdown
- Hover-slot хинты над тайлами: `HotkeyHintView(style: .keycaps, size: .tiny)` —
  каждый глиф в собственном мини-кейкапе (`KeycapChrome.chip`), без внешней
  капсулы. `.bare` остаётся для надписей-overline без чипов.
```

- [ ] **Step 9: Ручная проверка (визуальная)**

```bash
doppler run --project sidekey --config dev -- ./scripts/dev-run.sh --run
```

Навести на остров: над пятью тайлами — пары мини-кейкапов `[⌥][1]..[⌥][5]`; сравнить с утверждённым мокапом (вариант 3); убедиться, что панель не подросла и хинты не клипаются.

- [ ] **Step 10: Commit**

```bash
git add Sources/Sidekey/KeycapView.swift Sources/Sidekey/HotkeyHintView.swift Sources/Sidekey/DynamicIsland/IslandView.swift docs/hotkey.md Tests/SidekeyTests/KeycapViewTests.swift Tests/SidekeyTests/HotkeyHintViewTests.swift Tests/SidekeyTests/Hotkeys/HoverHintsTests.swift
git commit -m "feat(hotkey): hover-хинты — пара мини-кейкапов [⌥][N] (style .keycaps)"
```

---

### Task A4: Финальная верификация пакета А

**Files:** нет новых; только проверка.

- [ ] **Step 1: Полный тестовый прогон**

Run: `swift test`
Expected: 0 failed (база 2529 + новые).

- [ ] **Step 2: Ручной чеклист на dev-билде**

```bash
doppler run --project sidekey --config dev -- ./scripts/dev-run.sh --run
```

- `⌥1` (курсор вне острова): в правом крыле на ~3 с появляется `ON Smart` → повторный `⌥1` → `ON Fast`; hover не раскрывается.
- `⌥1` при открытом hover: тайл Drop Mode обновляет подпись режима.
- `⌥2`/`⌥3`: панель появляется без промелька.
- Хинты `[⌥][N]` над тайлами соответствуют мокапу.
- Во время митинг-записи `⌥1` переключает режим, пилюля не показывается (слот занят).

- [ ] **Step 3: Зафиксировать готовность**

Отметить в `docs/specs/hotkeys-followups.md` пакет А как реализованный (строка `> Статус: Пакет А реализован <commit>`), commit:

```bash
git add docs/specs/hotkeys-followups.md
git commit -m "docs(hotkey): пакет А (hover-полировка) реализован"
```
