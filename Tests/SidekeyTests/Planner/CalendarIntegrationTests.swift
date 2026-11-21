import XCTest
@testable import Sidekey

@MainActor
final class CalendarIntegrationTests: XCTestCase {
    override func setUp() { super.setUp(); openCalendarForThisTest() }

    private func info(_ provider: CalendarProvider, approval: Any? = nil) -> [String: Any] {
        var client: [String: Any] = ["clientID": "shared-fixture"]
        if let approval { client["publicAccessApproved"] = approval }
        return ["WhytapCalendarOAuthClients": [provider.rawValue: client]]
    }

    func testPublicGoogleAndZoomRequireExplicitApproval() throws {
        for provider in [CalendarProvider.google, .zoom] {
            let expected: CalendarConnectionReadiness = provider == .google ? .awaitingGoogleVerification : .awaitingZoomPublication
            for approval: Any? in [nil, "false", "TRUE", true, 1] {
                let configuration = try XCTUnwrap(CalendarClientConfiguration.registered(provider, info: info(provider, approval: approval)))
                XCTAssertFalse(configuration.publicAccessApproved)
                XCTAssertEqual(CalendarConnectionReadiness.shared(provider, configuration: configuration, googleReview: false), expected)
                XCTAssertEqual(CalendarConnectionReadiness.authorization(provider, clientID: " shared-fixture ",
                    info: info(provider, approval: approval), googleReview: false), expected)
            }
            XCTAssertEqual(CalendarConnectionReadiness.authorization(provider, clientID: "shared-fixture",
                info: info(provider, approval: "true")), .available)
        }
    }

    func testFeatureReadinessSeparatesProviderSetupFromPublicReview() {
        XCTAssertEqual(CalendarConnectionReadiness.shared(.apple, configuration: nil), .available)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.microsoft, configuration: .init(clientID: "fixture")), .available)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.microsoft, configuration: nil), .setupRequired)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.zoom, configuration: nil), .awaitingZoomPublication)
        XCTAssertEqual(CalendarConnectionReadiness.authorization(.google, clientID: "  ", info: info(.google)), .setupRequired)
        // Advanced setup is for a source user's independent native registration.
        XCTAssertEqual(CalendarConnectionReadiness.authorization(.google, clientID: "my-own-fixture", info: info(.google)), .available)
        XCTAssertEqual(CalendarConnectionReadiness.authorization(.zoom, clientID: "my-own-fixture", info: [:]), .available)
    }

    func testUnapprovedSharedClientsNeverOpenBrowserOrReceiveCallback() async throws {
        for provider in [CalendarProvider.google, .zoom] {
            var opened = false
            let browser = CalendarBrowserSignIn(configurationInfo: info(provider), googleReview: { false }) { _ in opened = true; return true }
            do {
                _ = try await browser.authorize(provider: provider, clientID: "shared-fixture", state: "fixture", verifier: "fixture")
                XCTFail("Public review must gate browser authorization")
            } catch {
                XCTAssertEqual((error as? CalendarConnectionError)?.errorDescription,
                    CalendarConnectionError.publicReviewPending.errorDescription)
            }
            XCTAssertFalse(opened)
        }
    }

    func testReviewAllowsOnlyConfiguredGoogleAndDoesNotChangePublicApproval() throws {
        let google = try XCTUnwrap(CalendarClientConfiguration.registered(.google, info: info(.google)))
        XCTAssertEqual(CalendarConnectionReadiness.shared(.google, configuration: google, googleReview: true), .available)
        XCTAssertEqual(CalendarConnectionReadiness.authorization(.google, clientID: "shared-fixture",
            info: info(.google), googleReview: true), .available)
        XCTAssertFalse(google.publicAccessApproved)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.google, configuration: google, googleReview: false), .awaitingGoogleVerification)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.google, configuration: nil, googleReview: true), .setupRequired)
        XCTAssertEqual(CalendarConnectionReadiness.shared(.zoom, configuration: google, googleReview: true), .awaitingZoomPublication)
    }

    func testDirectConnectUsesReviewSessionWithoutAnIntermediateForm() async throws {
        let suite = "test.calendar-review-direct." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connections = CalendarConnections(defaults: defaults)
        var active = true
        var authorizations = 0
        let flow = CalendarConnectionFlow(connections: connections, googleReview: { active }, authorize: { provider, clientID, _, _ in
            XCTAssertEqual(provider, .google); XCTAssertEqual(clientID, "shared-fixture")
            authorizations += 1
            throw CalendarConnectionError.denied
        })
        XCTAssertTrue(flow.startRegistered(provider: .google, info: info(.google)))
        for _ in 0..<100 where flow.working { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(authorizations, 1); XCTAssertFalse(connections.isConnecting)
        XCTAssertTrue(connections.accounts.isEmpty)
        active = false
        XCTAssertFalse(flow.startRegistered(provider: .google, info: info(.google)))
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(flow.error, CalendarConnectionReadiness.awaitingGoogleVerification.message)
        active = true
        XCTAssertFalse(flow.startRegistered(provider: .zoom, info: info(.zoom)))
        XCTAssertEqual(authorizations, 1)
    }

    func testReviewBrowserStillUsesRealPKCEStateAndLoopbackCallback() async throws {
        let opened = expectation(description: "review authorization")
        var authorization: URL?
        var active = true
        let browser = CalendarBrowserSignIn(timeoutSeconds: 3, configurationInfo: info(.google),
            googleReview: { active }) { url in authorization = url; opened.fulfill(); return true }
        let verifier = try CalendarPKCE.random()
        let task = Task { try await browser.authorize(provider: .google, clientID: "shared-fixture", state: "review-state", verifier: verifier) }
        await fulfillment(of: [opened], timeout: 2)
        let url = try XCTUnwrap(authorization)
        XCTAssertEqual(url.host, "accounts.google.com")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        let scopes = try XCTUnwrap(query.first { $0.name == "scope" }?.value)
        XCTAssertEqual(Set(scopes.split(separator: " ").map(String.init)), Set([
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
            "https://www.googleapis.com/auth/calendar.events.readonly"
        ]))
        let redirect = try XCTUnwrap(query.first { $0.name == "redirect_uri" }?.value)
        XCTAssertTrue(redirect.hasPrefix("http://127.0.0.1:"))
        let wrong = try XCTUnwrap(URL(string: redirect + "?state=wrong&code=fixture-code"))
        do {
            _ = try await URLSession.shared.data(from: wrong)
            XCTFail("An unrelated state must be ignored without accepting the callback")
        } catch { /* The loopback receiver closes unrelated requests. */ }
        let callback = try XCTUnwrap(URL(string: redirect + "?state=review-state&code=fixture-code"))
        let (_, accepted) = try await URLSession.shared.data(from: callback)
        XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
        let result = try await task.value
        XCTAssertEqual(result.code, "fixture-code")
        active = false
        do {
            _ = try await browser.authorize(provider: .google, clientID: "shared-fixture", state: "other", verifier: verifier)
            XCTFail("An expired review must not start another authorization")
        } catch {
            XCTAssertEqual((error as? CalendarConnectionError)?.errorDescription, CalendarConnectionError.publicReviewPending.errorDescription)
        }
    }

    func testConnectionLeaseSerializesSettingsAndPlannerAndReleasesActivity() throws {
        let suite = "test.calendar-connection-lease." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var activity: [Bool] = []
        let connections = CalendarConnections(defaults: defaults, activityChanged: { activity.append($0) })
        XCTAssertTrue(connections.beginConnecting(provider: .microsoft))
        XCTAssertFalse(connections.beginConnecting(provider: .apple))
        XCTAssertEqual(connections.connectingProvider, .microsoft)
        XCTAssertEqual(activity, [true])
        connections.endConnecting()
        XCTAssertFalse(connections.isConnecting)
        XCTAssertTrue(connections.beginConnecting(provider: .apple))
        connections.endConnecting()
        XCTAssertEqual(activity, [true, false, true, false])
        XCTAssertNil(defaults.object(forKey: CalendarAccountSettings.accountsKey))
    }

    func testAccountStorageIssueIsReportedBeforeStartingNewSignIn() async throws {
        let suite = "test.calendar-connection-capacity." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accounts = (0..<64).map { ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Fixture \($0)") }
        defaults.set(try JSONEncoder().encode(accounts), forKey: CalendarAccountSettings.accountsKey)
        let connections = CalendarConnections(defaults: defaults, oauth: CalendarOAuthClient(storage: PlannerMemoryCredentials()))
        XCTAssertNotNil(connections.accountConnectionIssue)
        try await connections.remove(accounts[0])
        XCTAssertNil(connections.accountConnectionIssue)
        defaults.set(Data("invalid fixture".utf8), forKey: CalendarAccountSettings.accountsKey)
        let damaged = CalendarConnections(defaults: defaults)
        XCTAssertNotNil(damaged.accountConnectionIssue)
        XCTAssertEqual(defaults.data(forKey: CalendarAccountSettings.accountsKey), Data("invalid fixture".utf8))
    }

    func testChangingClientIDCannotReuseTheOtherGoogleDesktopSecret() {
        let registered = CalendarClientConfiguration(clientID: "shared-fixture", clientSecret: "shared-desktop-fixture")
        XCTAssertEqual(CalendarClientConfiguration.secretAfterClientIDChange(from: "shared-fixture", to: "own-client",
            currentSecret: "shared-desktop-fixture", registered: registered), "")
        XCTAssertEqual(CalendarClientConfiguration.secretAfterClientIDChange(from: "own-client", to: "other-client",
            currentSecret: "own-desktop-fixture", registered: registered), "")
        XCTAssertEqual(CalendarClientConfiguration.secretAfterClientIDChange(from: "own-client", to: "shared-fixture",
            currentSecret: "own-desktop-fixture", registered: registered), "shared-desktop-fixture")
        XCTAssertEqual(CalendarClientConfiguration.secretAfterClientIDChange(from: "own-client", to: " own-client ",
            currentSecret: "own-desktop-fixture", registered: registered), "own-desktop-fixture")
    }
}
