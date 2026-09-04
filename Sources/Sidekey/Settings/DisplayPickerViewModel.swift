import AppKit
import Combine

/// Settings → Other → "Show island on": which display anchors the Dynamic
/// Island (and every overlay panel that follows it).
///
/// "Automatic" (nil) delegates to `IslandScreenResolver.selectDescriptor`'s
/// chain: notched screen, else primary display. A saved pick that is
/// currently DISCONNECTED renders as Automatic but is never erased — the
/// display wins again the moment it reconnects (`selection` getter filters
/// by connected options; the setter is the only writer).
@MainActor
final class DisplayPickerViewModel: ObservableObject {
    struct Option: Identifiable, Equatable {
        /// Display UUID (`IslandScreenResolver.preferredDisplayUUIDKey`
        /// value); `nil` = Automatic.
        let value: String?
        let label: String
        var id: String? { value }
    }

    @Published private(set) var options: [Option]

    private let defaults: UserDefaults
    private let screens: @MainActor () -> [(uuid: String, name: String)]
    private let center: NotificationCenter
    private var screenObserver: Any?

    init(
        defaults: UserDefaults = .standard,
        screens: @escaping @MainActor () -> [(uuid: String, name: String)] = {
            NSScreen.screens.compactMap { screen in
                guard let uuid = screen.sidekeyDisplayUUID else { return nil }
                return (uuid: uuid, name: screen.localizedName)
            }
        },
        center: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.screens = screens
        self.center = center
        self.options = Self.makeOptions(displays: screens())

        screenObserver = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildOptions()
            }
        }
    }

    deinit {
        if let screenObserver {
            center.removeObserver(screenObserver)
        }
    }

    /// The saved pick while its display is connected; `nil` (Automatic)
    /// otherwise. Setting routes through the resolver so the change
    /// notification reaches every overlay panel; `nil` deletes the key.
    var selection: String? {
        get {
            guard
                let saved = IslandScreenResolver.preferredDisplayUUID(in: defaults),
                options.contains(where: { $0.value == saved })
            else {
                return nil
            }
            return saved
        }
        set {
            objectWillChange.send()
            IslandScreenResolver.setPreferredDisplayUUID(
                newValue,
                in: defaults,
                center: center
            )
        }
    }

    func rebuildOptions() {
        options = Self.makeOptions(displays: screens())
    }

    private static func makeOptions(
        displays: [(uuid: String, name: String)]
    ) -> [Option] {
        var seenNames: [String: Int] = [:]
        var options: [Option] = [Option(value: nil, label: "Automatic")]
        for display in displays {
            let occurrence = (seenNames[display.name] ?? 0) + 1
            seenNames[display.name] = occurrence
            let label = occurrence == 1
                ? display.name
                : "\(display.name) (\(occurrence))"
            options.append(Option(value: display.uuid, label: label))
        }
        return options
    }
}
