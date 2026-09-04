import XCTest
@testable import Sidekey

/// The resolver must surface the on-device cleanup route on the `.local` LLM
/// level, while the cloud-only `routeIfEnabled()` used by the meetings BYOK
/// path keeps returning `nil` for `.local` (the fully-local meetings pipeline
/// owns that level).
final class DirectLLMRouteResolverLocalTests: XCTestCase {
    @MainActor
    private func makeResolver(level: LLMIsolationLevel, openRouterKey: String? = nil) -> DirectLLMRouteResolver {
        let defaults = UserDefaults(suiteName: "resolver.local.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.llmLevel = level
        return DirectLLMRouteResolver(
            prefs: prefs,
            llmKeyStore: FakeKeyStore(key: openRouterKey),
            customLLMKeyStore: FakeKeyStore(key: nil)
        )
    }

    @MainActor
    func testCleanupRouteIsLocalOnLocalLevel() async throws {
        let resolver = makeResolver(level: .local)
        let route = try await resolver.cleanupRoute()
        XCTAssertEqual(route, .local)
    }

    @MainActor
    func testCleanupRouteIsDirectOnYourKeyLevelWithKey() async throws {
        let resolver = makeResolver(level: .yourKey, openRouterKey: "or-key")
        let route = try await resolver.cleanupRoute()
        guard case .direct(let direct) = route else {
            return XCTFail("expected a direct OpenRouter route, got \(route)")
        }
        XCTAssertEqual(direct.endpoint, .openRouter(apiKey: "or-key"))
    }

    @MainActor
    func testCleanupRouteThrowsOnYourKeyLevelWithoutKey() async {
        // No key configured: there is no cleanup route. The Drop path treats
        // the throw as "no LLM available" and pastes the raw transcript.
        let resolver = makeResolver(level: .yourKey, openRouterKey: nil)
        do {
            _ = try await resolver.cleanupRoute()
            XCTFail("expected missingKey")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .missingKey)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    @MainActor
    func testRouteIfEnabledStaysNilForLocalLevel() async throws {
        // Meetings BYOK path: `.local` must not resolve to a cloud route here.
        let resolver = makeResolver(level: .local)
        let route = try await resolver.routeIfEnabled()
        XCTAssertNil(route)
    }
}

private final class FakeKeyStore: OpenRouterLLMKeyStoring {
    var key: String?
    init(key: String?) { self.key = key }
    func save(key: String) throws { self.key = key }
    func read() throws -> String? { key }
    func delete() throws { key = nil }
}
