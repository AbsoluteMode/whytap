import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

final class IslandHoverToolSearchTests: XCTestCase {
    func testFindsOutputLanguageWithoutPinningIt() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "output lang"), [.outputLang])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "OUTPUT LANGUAGE"), [.outputLang])
    }

    func testMatchesAliasesAndMultiwordTermsAcrossCatalog() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "язык вывода"), [.outputLang])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "clipboard"), [.clipboard])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "server status").first, .monitor)
        XCTAssertTrue(IslandHoverToolSearch.results(for: "language").contains(.inputLang))
        XCTAssertTrue(IslandHoverToolSearch.results(for: "language").contains(.outputLang))
    }

    func testFindsCaseByKeyTermsAndKeepsItsOldAliases() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "secrets"), [.caseVault])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "api keys"), [.caseVault])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "кейс"), [.caseVault])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "vault"), [.caseVault])
    }

    /// Copy text lives inside Shot's editor; people search for it by what it does.
    func testFindsShotCopyTextByOCRWords() {
        for query in ["OCR", "распознать", "распознавание текста", "скопировать текст", "скопируй текст с экрана",
                      "text from screen", "recognize text", "Copy text"] {
            XCTAssertEqual(IslandHoverToolSearch.results(for: query).first, .screenshot, query)
            let label = IslandHoverToolSearch.resultLabel(for: .screenshot, query: query)
            XCTAssertEqual(label.title, "Shot — Copy text", query)
            XCTAssertEqual(label.description, "Select an area, then click Copy text (OCR)", query)
        }
        XCTAssertEqual(IslandHoverToolSearch.results(for: "распознать"), [.screenshot])
        XCTAssertEqual(IslandHoverToolSearch.results(for: "ocr"), [.screenshot])
    }

    func testOrdinaryShotQueriesKeepShotLabelAndClipboardStaysFindable() {
        for query in ["shot", "скриншот", "blur text numbers", "текст"] {
            XCTAssertEqual(IslandHoverToolSearch.resultLabel(for: .screenshot, query: query).title, "Shot", query)
        }
        XCTAssertEqual(IslandHoverToolSearch.resultLabel(for: .clipboard, query: "copy").title,
                       HoverToolRegistry.info(for: .clipboard).title)
        XCTAssertTrue(IslandHoverToolSearch.results(for: "copy").contains(.clipboard))
        XCTAssertEqual(IslandHoverToolSearch.results(for: "clipboard"), [.clipboard])
        XCTAssertFalse(IslandHoverToolSearch.isCopyTextQuery(""))
    }

    func testEmptyAndUnknownQueriesHaveNoResults() {
        XCTAssertFalse(IslandHoverToolSearch.isFiltering("  \n"))
        XCTAssertFalse(IslandHoverToolSearch.isFiltering("!"))
        XCTAssertTrue(IslandHoverToolSearch.results(for: "  \n").isEmpty)
        XCTAssertTrue(IslandHoverToolSearch.results(for: "doesnotexist").isEmpty)
    }

    func testTitleMatchRanksBeforeDescriptionMatchAndUsesEveryTerm() {
        XCTAssertEqual(IslandHoverToolSearch.results(for: "record").first, .meetingRecord)
        XCTAssertEqual(IslandHoverToolSearch.results(for: "input output"), [])
    }

    func testKeyboardSelectionWrapsAndHandlesEmptyResults() {
        XCTAssertEqual(IslandHoverToolSearch.nextSelection(current: 0, direction: -1, count: 3), 2)
        XCTAssertEqual(IslandHoverToolSearch.nextSelection(current: 2, direction: 1, count: 3), 0)
        XCTAssertEqual(IslandHoverToolSearch.nextSelection(current: 0, direction: 1, count: 1), 0)
        XCTAssertNil(IslandHoverToolSearch.nextSelection(current: 0, direction: 1, count: 0))
    }

    @MainActor
    func testGlassSearchCellPreservesNativeTextAndButtonInsets() throws {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let native = NSSearchField(frame: .zero)
            let transparent = IslandHoverSearchNativeField(frame: .zero)
            for field in [native, transparent] {
                field.font = NSFont.systemFont(ofSize: 12)
                field.stringValue = "output language"
            }
            let nativeCell = try XCTUnwrap(native.cell as? NSSearchFieldCell)
            let glassCell = try XCTUnwrap(transparent.cell as? IslandHoverSearchGlassCell)
            XCTAssertEqual(transparent.isBezeled, native.isBezeled)
            for width in [CGFloat(150), 320, 500] {
                let bounds = CGRect(x: 0, y: 0, width: width, height: IslandHoverToolSearch.fieldHeight)
                // Native search/cancel button geometry also reads the actual
                // control bounds, not only the rect passed to the cell method.
                for field in [native, transparent] {
                    field.frame = bounds
                    field.layoutSubtreeIfNeeded()
                }
                XCTAssertEqual(glassCell.searchTextRect(forBounds: bounds), nativeCell.searchTextRect(forBounds: bounds))
                XCTAssertEqual(glassCell.searchButtonRect(forBounds: bounds), nativeCell.searchButtonRect(forBounds: bounds))
                XCTAssertEqual(glassCell.cancelButtonRect(forBounds: bounds), nativeCell.cancelButtonRect(forBounds: bounds))
            }
            return
        }
        #endif
        throw XCTSkip("Native transparent search cell is used on macOS 26+")
    }

    @MainActor
    func testGlassSearchEditorStaysTransparentOnRepeatedEditingEntry() {
        let cell = IslandHoverSearchGlassCell(textCell: "output")
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 30))
        for _ in 0..<2 {
            // Simulate a shared field editor arriving with another field's paint.
            editor.drawsBackground = true
            editor.backgroundColor = .black
            let configured = cell.setUpFieldEditorAttributes(editor)
            XCTAssertTrue(configured === editor)
            XCTAssertFalse(editor.drawsBackground)
            XCTAssertEqual(editor.backgroundColor.alphaComponent, 0)
        }
    }

    @MainActor
    func testHostedSearchKeepsNativeButtonsInsideItsFrameAfterReturningFromInlinePanel() throws {
        guard IslandHoverGlass.usesNativeLiquidGlass else {
            throw XCTSkip("Transparent search cell requires macOS 26+ and its SDK")
        }
        for panelWidth in [CGFloat(310), 312] {
            for monitorHeight in [CGFloat(243), 352] {
                for query in ["", "output"] {
                    try verifySearchReturn(panelWidth: panelWidth, monitorHeight: monitorHeight, query: query)
                }
            }
        }
    }

    @MainActor
    private func verifySearchReturn(panelWidth: CGFloat, monitorHeight: CGFloat, query: String) throws {
        // No app runtime, store, providers or user data. The window is never
        // ordered, activated or made key: only native layout/drawing is tested.
        _ = NSApplication.shared
        let state = SearchReturnFixtureState(query: query)
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: panelWidth, height: 243),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: SearchReturnFixture(state: state))
        host.sizingOptions = []
        host.frame = CGRect(x: 0, y: 0, width: panelWidth, height: 243)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        func settle(_ duration: TimeInterval) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: duration))
            host.layoutSubtreeIfNeeded()
        }
        func searchFields(in view: NSView) -> [IslandHoverSearchNativeField] {
            if let field = view as? IslandHoverSearchNativeField { return [field] }
            return view.subviews.flatMap { searchFields(in: $0) }
        }
        func validateField() throws -> Data {
            let fields = searchFields(in: host)
            XCTAssertEqual(fields.count, 1)
            let field = try XCTUnwrap(fields.first)
            XCTAssertEqual(field.bounds.height, IslandHoverToolSearch.fieldHeight)
            XCTAssertEqual(field.bounds.width, panelWidth - 36)
            XCTAssertEqual(field.stringValue, query)
            XCTAssertNil(field.currentEditor())
            let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
            // Compare against an ordinary AppKit cell in the SAME actual
            // bounds; the fix must not alter text/cancel/search geometry.
            let native = NSSearchField(frame: field.bounds)
            native.font = field.font
            native.stringValue = query
            let nativeCell = try XCTUnwrap(native.cell as? NSSearchFieldCell)
            let glyph = try XCTUnwrap(field.subviews.compactMap { $0 as? IslandHoverSearchGlyphView }.first)
            XCTAssertTrue(cell.searchButtonCell?.isTransparent == true)
            XCTAssertFalse(glyph.isHidden)
            XCTAssertFalse(glyph.isAccessibilityElement())
            XCTAssertNil(glyph.hitTest(CGPoint(x: glyph.bounds.midX, y: glyph.bounds.midY)))
            XCTAssertNotNil(glyph.image)
            XCTAssertTrue(cell.searchButtonRect(forBounds: field.bounds).contains(glyph.frame))
            XCTAssertTrue(field.bounds.contains(glyph.frame))
            for (actual, expected) in [
                (cell.searchTextRect(forBounds: field.bounds), nativeCell.searchTextRect(forBounds: native.bounds)),
                (cell.searchButtonRect(forBounds: field.bounds), nativeCell.searchButtonRect(forBounds: native.bounds)),
                (cell.cancelButtonRect(forBounds: field.bounds), nativeCell.cancelButtonRect(forBounds: native.bounds))
            ] {
                XCTAssertEqual(actual, expected)
                if !actual.isEmpty { XCTAssertTrue(field.bounds.contains(actual), "Native control must fit inside its view: \(actual)") }
            }
            let bitmap = try XCTUnwrap(field.bitmapImageRepForCachingDisplay(in: field.bounds))
            field.cacheDisplay(in: field.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }

        settle(0.05)
        let initialDrawing = try validateField()
        state.showsSearch = false
        window.setContentSize(CGSize(width: panelWidth, height: monitorHeight))
        settle(0.20)
        XCTAssertTrue(searchFields(in: host).isEmpty)
        state.showsSearch = true
        window.setContentSize(CGSize(width: panelWidth, height: 243))
        settle(0.20)
        XCTAssertEqual(try validateField(), initialDrawing, "Native loupe/text/cancel drawing must survive removal and remount")
        XCTAssertTrue(state.focusChanges.isEmpty, "Returning to Tools must not acquire keyboard focus")
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
    }

    @MainActor
    func testExplicitLoupePreservesNativeButtonIdentityTrackingAndAction() throws {
        guard IslandHoverGlass.usesNativeLiquidGlass else {
            throw XCTSkip("Transparent search cell requires macOS 26+ and its SDK")
        }
        _ = NSApplication.shared
        let field = IslandHoverSearchNativeField(frame: CGRect(x: 0, y: 0, width: 274, height: 30))
        let cell = try XCTUnwrap(field.cell as? NSSearchFieldCell)
        let button = try XCTUnwrap(cell.searchButtonCell)
        let action = SearchButtonActionFixture()
        button.target = action
        button.action = #selector(SearchButtonActionFixture.activate(_:))
        field.needsLayout = true
        field.layoutSubtreeIfNeeded()
        XCTAssertTrue(cell.searchButtonCell === button)
        XCTAssertTrue(button.target === action)
        XCTAssertEqual(button.action, #selector(SearchButtonActionFixture.activate(_:)))
        XCTAssertTrue(button.isTransparent)
        button.performClick(nil)
        XCTAssertEqual(action.activationCount, 1)

        // Public cell hit testing is still native, including the search
        // button's complete original target rather than the smaller glyph.
        let native = NSSearchField(frame: field.bounds)
        let nativeCell = try XCTUnwrap(native.cell as? NSSearchFieldCell)
        let nativeButton = try XCTUnwrap(nativeCell.searchButtonCell)
        let rect = cell.searchButtonRect(forBounds: field.bounds)
        for point in [CGPoint(x: rect.midX, y: rect.midY), CGPoint(x: rect.minX + 1, y: rect.minY + 1)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            ))
            XCTAssertEqual(button.hitTest(for: event, in: rect, of: field), nativeButton.hitTest(for: event, in: rect, of: field))
        }
    }

    @MainActor
    func testSearchingDoesNotChangeSavedLayoutOrPinnedSettings() {
        let suite = "IslandHoverToolSearchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: [.monitor])
        let before = defaults.stringArray(forKey: HoverLayoutStore.defaultsKey)
        XCTAssertFalse(store.slots.contains(.outputLang))
        XCTAssertEqual(IslandHoverToolSearch.results(for: "output").first, .outputLang)
        XCTAssertEqual(store.slots, [.monitor, .settings])
        XCTAssertEqual(defaults.stringArray(forKey: HoverLayoutStore.defaultsKey), before)
        XCTAssertEqual(HoverSlotRouter.effect(for: .outputLang), .openPanel(.outputLanguagePicker))
    }
}

@MainActor
private final class SearchReturnFixtureState: ObservableObject {
    @Published var showsSearch = true
    @Published var query: String
    var focusChanges: [Bool] = []

    init(query: String) { self.query = query }
}

@MainActor
private final class SearchButtonActionFixture: NSObject {
    var activationCount = 0
    @objc func activate(_ sender: Any?) { activationCount += 1 }
}

private struct SearchReturnFixture: View {
    @ObservedObject var state: SearchReturnFixtureState

    var body: some View {
        ZStack(alignment: .top) {
            if state.showsSearch {
                VStack(spacing: 0) {
                    IslandHoverSearchField(
                        text: $state.query,
                        onFocusChange: { state.focusChanges.append($0) },
                        onCommand: { _ in }
                    )
                    .frame(height: IslandHoverToolSearch.fieldHeight)
                    .padding(.horizontal, 18)
                    .padding(.vertical, IslandHoverToolSearch.fieldVerticalInset)
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                Text("Monitor")
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.16), value: state.showsSearch)
    }
}
