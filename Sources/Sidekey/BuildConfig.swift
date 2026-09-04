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
enum BuildConfig {
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

    /// Public-facing Privacy Policy URL. `nil` hides the link entirely so no
    /// surface renders a broken affordance.
    static let privacyPolicyURL: URL? = nil
}
