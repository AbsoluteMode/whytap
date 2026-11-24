import Foundation

/// What changed for the person in each release, written by hand for the
/// release and bundled in the app as `Resources/WhatsNew.json` (never
/// fetched: the list matches the binary and needs no network).
// WHY: .project-docs/decisions/2026-11-24-whats-new-window.md
struct WhatsNewItem: Codable, Equatable, Identifiable {
    struct Link: Codable, Equatable {
        /// The button's words ("Open Models").
        let title: String
        /// A `SettingsWindowTab` raw value.
        let settings: String

        var tab: SettingsWindowTab? { SettingsWindowTab(rawValue: settings) }
    }

    let title: String
    let body: String
    /// An SF Symbol name for the row's mark.
    var symbol: String?
    /// A `FeatureVideo` raw value; the clip is bundled in the app.
    var video: String?
    var link: Link?

    var id: String { title }
    var featureVideo: FeatureVideo? { video.flatMap(FeatureVideo.init(rawValue:)) }
}

struct WhatsNewRelease: Codable, Equatable, Identifiable {
    let version: String
    var date: String?
    /// Empty for a release that changed nothing the person can notice.
    let items: [WhatsNewItem]

    var id: String { version }
}

struct WhatsNewCatalog: Codable, Equatable {
    static let resourceName = "WhatsNew"
    /// Limits of one release's list, shared with `scripts/whats-new.py`.
    static let maxItems = 5
    static let maxTitleLength = 36
    static let maxBodyLength = 120

    let releases: [WhatsNewRelease]

    static let empty = WhatsNewCatalog(releases: [])

    /// The bundled list; a build without the file, or with a damaged one,
    /// has no list and shows nothing.
    static func bundled(in bundle: Bundle = .main) -> WhatsNewCatalog {
        guard let url = bundle.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return .empty }
        return decode(data) ?? .empty
    }

    static func decode(_ data: Data) -> WhatsNewCatalog? {
        try? JSONDecoder().decode(WhatsNewCatalog.self, from: data)
    }

    /// Releases with something to show, newer than `seen` (all of them when
    /// `seen` is nil) and not newer than `current`, newest first.
    func releases(after seen: String?, through current: String) -> [WhatsNewRelease] {
        let current = WhatsNewVersion(current)
        let seen = seen.map(WhatsNewVersion.init)
        return releases
            .filter { !$0.items.isEmpty && WhatsNewVersion.isCatalogVersion($0.version) }
            .filter { release in
                let version = WhatsNewVersion(release.version)
                if let seen, version <= seen { return false }
                return version <= current
            }
            .sorted { WhatsNewVersion($0.version) > WhatsNewVersion($1.version) }
    }
}

/// A display version compared by its numbers: "2.2.9" < "2.2.27",
/// "2.3" equals "2.3.0", "0.0.0-dev" is 0.0.0.
///
/// The numbers are one to four components of one to six ASCII digits, the
/// same rule as `scripts/whats-new.py`; anything else at the start of the
/// text (full-width digits, a longer number) has no numbers and compares as
/// zero. A list entry must be exactly such numbers (`isCatalogVersion`), so
/// the release check and the app always agree on which entry is which.
struct WhatsNewVersion: Comparable, Equatable {
    static let maxComponents = 4
    static let maxComponentDigits = 6

    let parts: [Int]

    init(_ text: String) {
        var parts = Self.components(text.prefix { Self.isDigit($0) || $0 == "." }) ?? []
        while parts.last == 0 { parts.removeLast() }
        self.parts = parts
    }

    /// `true` for a version a list entry may have: the numbers and nothing else.
    static func isCatalogVersion(_ text: String) -> Bool {
        text.allSatisfy { isDigit($0) || $0 == "." } && components(text[...]) != nil
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func components(_ numeric: Substring) -> [Int]? {
        let pieces = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...maxComponents).contains(pieces.count),
              pieces.allSatisfy({ (1...maxComponentDigits).contains($0.count) }) else { return nil }
        return pieces.compactMap { Int($0) }
    }

    static func < (lhs: WhatsNewVersion, rhs: WhatsNewVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

/// Decides, once per launch, whether the window opens by itself.
///
/// - A new Mac (the onboarding opens): nothing, the version is remembered.
/// - The same version as the last launch: nothing.
/// - A newer version: every release since the remembered one that has
///   something for the person, newest first; none of them has: nothing.
/// - A Mac that ran Whytap before this window existed (nothing remembered):
///   the running version's list only.
/// - An older version than remembered (a rollback, a developer build):
///   nothing, and the remembered version stays, so the return to the newer
///   one shows nothing again.
///
/// The highest launched version is remembered as soon as the decision is
/// made, so the window never comes back by itself until the next update.
enum WhatsNewLaunch {
    static let seenVersionKey = "sidekey.whatsNew.seenVersion.v1"

    static func consume(currentVersion: String, isFirstLaunch: Bool, catalog: WhatsNewCatalog,
                        defaults: UserDefaults) -> [WhatsNewRelease] {
        let seen = defaults.string(forKey: seenVersionKey)
        // The highest version ever launched: an older build in between
        // (a rollback, a developer build) never brings a seen list back.
        if seen.map({ WhatsNewVersion($0) < WhatsNewVersion(currentVersion) }) ?? true {
            defaults.set(currentVersion, forKey: seenVersionKey)
        }
        guard !isFirstLaunch else { return [] }
        guard let seen else {
            return catalog.releases(after: nil, through: currentVersion)
                .filter { WhatsNewVersion($0.version) == WhatsNewVersion(currentVersion) }
        }
        guard WhatsNewVersion(seen) < WhatsNewVersion(currentVersion) else { return [] }
        return catalog.releases(after: seen, through: currentVersion)
    }
}
