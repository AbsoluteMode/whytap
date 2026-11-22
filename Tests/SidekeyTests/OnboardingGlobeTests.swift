import simd
import XCTest
@testable import Sidekey

/// The language step's globe (REV 50): the typed text and a click on a
/// country are equal ways to the same country and language, and only
/// languages the speech route can take are offered.
@MainActor
final class OnboardingGlobeTests: XCTestCase {
    private let mesh = OnboardingGlobeMesh.shared

    private func code(_ match: OnboardingGlobeMatch?) -> String? { match.map { mesh.countries[$0.country].code } }

    func testTheDataHasTheCountriesThePrototypeShowed() {
        XCTAssertGreaterThanOrEqual(mesh.countries.count, 79)
        for code in ["RU", "US", "GB", "BR", "PT", "ES", "MX", "JP", "DE", "FR", "CH", "AU", "IN", "CN"] {
            XCTAssertNotNil(mesh.index(of: code), code)
        }
        XCTAssertFalse(mesh.baseEdges.isEmpty)
        XCTAssertFalse(mesh.graticuleEdges.isEmpty)
        XCTAssertTrue(mesh.countries.allSatisfy { !$0.languages.isEmpty }, "every country names its languages")
    }

    /// "Rus", "Port", "Jap": the prototype's examples; a language's name
    /// lights its home country with that language.
    func testTypingTurnsTheGlobeToTheCountry() {
        XCTAssertEqual(code(OnboardingGlobeSearch.best("Rus")), "RU")
        XCTAssertEqual(code(OnboardingGlobeSearch.best("Jap")), "JP")
        XCTAssertEqual(code(OnboardingGlobeSearch.best("Port")), "PT", "a country's name before a language's")
        XCTAssertEqual(code(OnboardingGlobeSearch.best("Brazil")), "BR")
        XCTAssertEqual(code(OnboardingGlobeSearch.best("uk")), "GB")
        let russian = OnboardingGlobeSearch.best("Русский")
        XCTAssertEqual(code(russian), "RU")
        XCTAssertEqual(russian?.language, "ru")
        let english = OnboardingGlobeSearch.best("English")
        XCTAssertEqual(code(english), "US")
        XCTAssertEqual(english?.language, "en")
        let catalan = OnboardingGlobeSearch.best("Catalan")
        XCTAssertEqual(code(catalan), "ES", "a language of a country lights that country")
        XCTAssertEqual(catalan?.language, "ca")
        XCTAssertNil(OnboardingGlobeSearch.best("Xyzzy"))
        XCTAssertNil(OnboardingGlobeSearch.best("   "))
    }

    func testAClickFindsTheCountryUnderIt() {
        func at(_ lat: Double, _ lon: Double) -> String? {
            mesh.country(at: OnboardingGlobeMesh.point(lat: lat, lon: lon)).map { mesh.countries[$0].code }
        }
        XCTAssertEqual(at(56, 60), "RU")
        XCTAssertEqual(at(-10, -52), "BR")
        XCTAssertEqual(at(39, -100), "US")
        XCTAssertEqual(at(36, 138), "JP")
        XCTAssertNil(at(-40, -130), "the open Pacific is no country")
    }

    /// A click lands where the globe drew it, at any turn of the globe.
    func testAPointOfTheViewMapsBackToTheSphere() throws {
        let motion = OnboardingGlobeMotion()
        let center = CGPoint(x: 260, y: 85)
        for (yaw, pitch) in [(0.0, 0.0), (-0.3, 0.4), (2.1, -0.6)] {
            motion.yaw = yaw
            motion.pitch = pitch
            let v = OnboardingGlobeMesh.point(lat: 20, lon: -yaw * 180 / .pi + 10)
            let projected = motion.project(v, center: center, radius: 70)
            XCTAssertGreaterThan(projected.q.z, 0, "on the near side")
            let back = try XCTUnwrap(motion.unproject(projected.point, center: center, radius: 70))
            XCTAssertLessThan(simd_distance(back, v), 0.02, "\(yaw), \(pitch)")
        }
        XCTAssertNil(motion.unproject(CGPoint(x: 0, y: 0), center: center, radius: 70), "off the globe")
    }

    func testTheSpringLandsOnThePickedCountry() throws {
        OnboardingGlobeMotion.settlesAtOnce = true
        defer { OnboardingGlobeMotion.settlesAtOnce = false }
        let motion = OnboardingGlobeMotion()
        let brazil = try XCTUnwrap(mesh.index(of: "BR"))
        motion.aim(at: mesh.countries[brazil])
        motion.advance(to: 1, still: false) { $0 == brazil ? 1 : 0 }
        XCTAssertEqual(motion.lit[brazil], 1)
        let center = motion.project(OnboardingGlobeMesh.point(lat: mesh.countries[brazil].lat, lon: mesh.countries[brazil].lon),
                                    center: .zero, radius: 70)
        XCTAssertLessThan(hypot(center.point.x, center.point.y), 8, "the country faces the viewer")
    }

    /// Only languages the speech route can take: a Deepgram model's own list,
    /// otherwise Whytap's dictation menu.
    func testOnlyTheSpeechRoutesLanguagesAreOffered() {
        XCTAssertEqual(OnboardingJourneyModel.languages(account: .soniox, model: "stt-rt-v4").count, AppLanguage.all.count)
        let nova2 = OnboardingJourneyModel.languages(account: .deepgram, model: "nova-2").map(\.code)
        XCTAssertTrue(nova2.contains("ru"))
        XCTAssertFalse(nova2.contains("ar"), "nova-2 has no Arabic")
        let medical = OnboardingJourneyModel.languages(account: .deepgram, model: "nova-3-medical").map(\.code)
        XCTAssertEqual(medical, ["en"])
        XCTAssertFalse(OnboardingJourneyModel.detectsLanguage(account: .deepgram, model: "enhanced"),
                       "no Auto-detect where the model has none")
        XCTAssertTrue(OnboardingJourneyModel.detectsLanguage(account: .soniox, model: "stt-rt-v4"))
    }
}
