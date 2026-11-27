import Foundation

enum BuildFlavor: String, Codable, Equatable {
    case dev
    case beta
    case prod
}

/// Compile-time flavor selector. Two flavors of Whytap ship from the same
/// codebase: `prod` (default) and `beta` (built with `-Xswiftc -DBETA`).
///
/// Beta and prod installations are designed to coexist on the same machine
/// without conflict — different bundle identifiers, different keychain
/// services, different appcast feeds. All facets must change together.
// WHY: .project-docs/decisions/2026-10-19-whytap-name.md
enum BuildConfig {
    /// Source-customized dev bundles must never be replaced by a packaged release.
    static var allowsPackagedUpdates: Bool {
        allowsPackagedUpdates(
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            displayVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
    }

    static func allowsPackagedUpdates(buildVersion: String?, displayVersion: String?) -> Bool {
        guard let buildVersion, !buildVersion.isEmpty else { return false }
        return buildVersion != "9999" && !(displayVersion?.lowercased().contains("-dev") ?? false)
    }

    #if BETA
    static let flavor: BuildFlavor = .beta
    static let bundleID = "com.rootwise.sidekey.beta"
    static let keychainService = "com.rootwise.sidekey.beta"
    static let appcastURL = URL(string: "https://github.com/AbsoluteMode/whytap/releases/download/beta/appcast.xml")!
    static let landingURL = URL(string: "https://github.com/AbsoluteMode/whytap")!
    #else
    static let flavor: BuildFlavor = .prod
    static let bundleID = "com.rootwise.sidekey"
    static let keychainService = "com.rootwise.sidekey"
    static let appcastURL = URL(string: "https://github.com/AbsoluteMode/whytap/releases/latest/download/appcast.xml")!
    static let landingURL = URL(string: "https://github.com/AbsoluteMode/whytap")!
    #endif

    /// The Whytap website, opened in the user's browser only.
    static let websiteURL = URL(string: "https://whytap.ai")!

    /// Help Center: the Ask page where a question gets an answer. The single
    /// constant behind every Help item (Settings footer, Help window, island
    /// tool search). WHY: .project-docs/decisions/2026-11-26-help-center-link.md
    static let helpCenterURL = URL(string: "https://whytap.ai/help/")!

    /// Public-facing Privacy Policy URL. `nil` hides the link entirely so no
    /// surface renders a broken affordance.
    static let privacyPolicyURL: URL? = nil
}
