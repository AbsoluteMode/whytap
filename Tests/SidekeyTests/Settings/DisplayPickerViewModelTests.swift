import AppKit
import XCTest
@testable import Sidekey

/// Settings → Other → "Show island on" picker view model. Fully DI'd:
/// ephemeral UserDefaults suite, fake display provider, private
/// NotificationCenter — no real NSScreen involved.
@MainActor
final class DisplayPickerViewModelTests: XCTestCase {

    // MARK: - Options

    func test_optionsListAutomaticFirstThenDisplaysByName_disambiguatingDuplicates() {
        let (vm, _, _) = makeVM(displays: [
            (uuid: "u-builtin", name: "Built-in Display"),
            (uuid: "u-lg-1", name: "LG HDR 4K"),
            (uuid: "u-lg-2", name: "LG HDR 4K"),
        ])

        XCTAssertEqual(vm.options.map(\.value), [nil, "u-builtin", "u-lg-1", "u-lg-2"])
        XCTAssertEqual(
            vm.options.map(\.label),
            ["Automatic", "Built-in Display", "LG HDR 4K", "LG HDR 4K (2)"]
        )
    }

    // MARK: - Selecting a display

    func test_selectingDisplayWritesPreferredKeyAndPostsSelectionChangeOnce() {
        let (vm, defaults, center) = makeVM(displays: [
            (uuid: "u-builtin", name: "Built-in Display"),
            (uuid: "u-ext", name: "External"),
        ])
        let posts = SelectionChangeCounter(center: center)

        vm.selection = "u-ext"

        XCTAssertEqual(
            defaults.string(forKey: IslandScreenResolver.preferredDisplayUUIDKey),
            "u-ext"
        )
        XCTAssertEqual(vm.selection, "u-ext")
        XCTAssertEqual(posts.count, 1)
    }

    func test_reselectingTheSameDisplayDoesNotPostAgain() {
        let (vm, _, center) = makeVM(displays: [
            (uuid: "u-ext", name: "External"),
        ])
        let posts = SelectionChangeCounter(center: center)

        vm.selection = "u-ext"
        vm.selection = "u-ext"

        XCTAssertEqual(posts.count, 1)
    }

    // MARK: - Automatic

    func test_selectingAutomaticRemovesKeyAndPostsSelectionChange() {
        let (vm, defaults, center) = makeVM(displays: [
            (uuid: "u-ext", name: "External"),
        ])
        defaults.set("u-ext", forKey: IslandScreenResolver.preferredDisplayUUIDKey)
        let posts = SelectionChangeCounter(center: center)

        vm.selection = nil

        XCTAssertNil(defaults.string(forKey: IslandScreenResolver.preferredDisplayUUIDKey))
        XCTAssertNil(vm.selection)
        XCTAssertEqual(posts.count, 1)
    }

    // MARK: - Disconnect / reconnect

    func test_disconnectedSavedDisplayShowsAutomaticButKeepsTheKey() {
        var displays = [
            (uuid: "u-builtin", name: "Built-in Display"),
            (uuid: "u-ext", name: "External"),
        ]
        let (vm, defaults, _) = makeVM(displays: displays, provider: { displays })
        defaults.set("u-ext", forKey: IslandScreenResolver.preferredDisplayUUIDKey)
        XCTAssertEqual(vm.selection, "u-ext")

        // The external display goes away: the picker falls back to Automatic
        // in the UI, but the stored pick must survive the disconnect.
        displays = [(uuid: "u-builtin", name: "Built-in Display")]
        vm.rebuildOptions()

        XCTAssertNil(vm.selection)
        XCTAssertEqual(
            defaults.string(forKey: IslandScreenResolver.preferredDisplayUUIDKey),
            "u-ext"
        )

        // ...and wins again the moment the display reconnects.
        displays = [
            (uuid: "u-builtin", name: "Built-in Display"),
            (uuid: "u-ext", name: "External"),
        ]
        vm.rebuildOptions()

        XCTAssertEqual(vm.selection, "u-ext")
    }

    // MARK: - Fixtures

    private func makeVM(
        displays: [(uuid: String, name: String)],
        provider: (() -> [(uuid: String, name: String)])? = nil
    ) -> (DisplayPickerViewModel, UserDefaults, NotificationCenter) {
        let defaults = UserDefaults(suiteName: "display.picker.\(UUID().uuidString)")!
        let center = NotificationCenter()
        let vm = DisplayPickerViewModel(
            defaults: defaults,
            screens: provider ?? { displays },
            center: center
        )
        return (vm, defaults, center)
    }
}

/// Counts `IslandScreenResolver.selectionDidChangeNotification` posts on the
/// injected center.
private final class SelectionChangeCounter {
    private(set) var count = 0
    private var observer: Any?
    private let center: NotificationCenter

    init(center: NotificationCenter) {
        self.center = center
        observer = center.addObserver(
            forName: IslandScreenResolver.selectionDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.count += 1
        }
    }

    deinit {
        if let observer {
            center.removeObserver(observer)
        }
    }
}
