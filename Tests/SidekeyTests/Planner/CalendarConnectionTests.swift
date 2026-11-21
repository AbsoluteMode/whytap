import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

final class PlannerMemoryCredentials: CalendarCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: CalendarCredential] = [:]
    private var saves = 0
    private var backupSaves = 0
    var saveCount: Int { lock.lock(); defer { lock.unlock() }; return saves }
    var backupRelevantSaves: Int { lock.lock(); defer { lock.unlock() }; return backupSaves }
    func read(_ id: UUID) throws -> CalendarCredential? { lock.lock(); defer { lock.unlock() }; return values[id] }
    func save(_ credential: CalendarCredential, id: UUID, backupRelevant: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        values[id] = credential; saves += 1
        if backupRelevant { backupSaves += 1 }
    }
    func delete(_ id: UUID) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: id) }
}

final class PlannerURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: Any]))?
    static var delay = 0.0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, json) = try XCTUnwrap(Self.handler)(request)
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            let finish = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            if Self.delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: finish) }
            else { finish() }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class CalendarConnectionTests: XCTestCase {
    private var storage: PlannerMemoryCredentials!
    private var http: CalendarHTTP!
    private var oauth: CalendarOAuthClient!
    override func setUp() async throws {
        openCalendarForThisTest()
        storage = PlannerMemoryCredentials()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PlannerURLProtocol.self]
        http = CalendarHTTP(session: URLSession(configuration: configuration))
        oauth = CalendarOAuthClient(http: http, storage: storage)
    }
    override func tearDown() async throws { PlannerURLProtocol.handler = nil; PlannerURLProtocol.delay = 0 }
    private func credential(_ provider: CalendarProvider, expires: Date = .distantFuture) -> CalendarCredential {
        CalendarCredential(provider: provider, clientID: "fixture-client", accessToken: "fixture-access",
            refreshToken: "fixture-refresh", expiresAt: expires)
    }

    func testRotatingRefreshIsPersistedOnceAcrossConcurrentRequests() async throws {
        let id = UUID()
        try storage.save(credential(.zoom, expires: .distantPast), id: id)
        var requests = 0
        PlannerURLProtocol.delay = 0.04
        PlannerURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.absoluteString, "https://zoom.us/oauth/token")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["access_token": "fixture-updated", "refresh_token": "fixture-rotated", "expires_in": 3600, "token_type": "bearer"])
        }
        async let first = oauth.accessToken(id)
        async let second = oauth.accessToken(id)
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["fixture-updated", "fixture-updated"])
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(storage.saveCount, 2)
        XCTAssertEqual(storage.backupRelevantSaves, 1, "Rotation is durable without requesting a full backup")
        XCTAssertEqual(try storage.read(id)?.refreshToken, "fixture-rotated")
    }

    func testAccessOnlyRefreshIsCachedWithoutChangingBackupCredentials() async throws {
        let id = UUID()
        let original = credential(.google, expires: .distantPast)
        try storage.save(original, id: id)
        var requests = 0
        PlannerURLProtocol.handler = { _ in
            requests += 1
            return (200, ["access_token": "fixture-new-access", "expires_in": 3600, "token_type": "Bearer"])
        }
        let first = try await oauth.accessToken(id)
        let second = try await oauth.accessToken(id)
        XCTAssertEqual(first, "fixture-new-access")
        XCTAssertEqual(second, first)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(storage.saveCount, 1, "An access-only change must not notify backup or replace its credential")
        XCTAssertEqual(try storage.read(id)?.refreshToken, original.refreshToken)
        let data = try JSONEncoder().encode(original)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["accessToken"]); XCTAssertNil(json["expiresAt"])
        let restored = try JSONDecoder().decode(CalendarCredential.self, from: data)
        XCTAssertTrue(restored.accessToken.isEmpty)
        XCTAssertEqual(restored.expiresAt, .distantPast)
        XCTAssertTrue(original.hasSameAuthorization(as: restored))
    }

    func testFirstConnectTokenErrorsExplainConfigurationInsteadOfDisconnect() async throws {
        for status in [400, 401] {
            PlannerURLProtocol.handler = { _ in (status, ["error": "invalid_client"]) }
            do {
                try await oauth.connect(provider: .google, clientID: "fixture", clientSecret: nil,
                    code: "fixture-code", redirect: "http://127.0.0.1/callback", verifier: "fixture", id: UUID())
                XCTFail("Invalid client must fail")
            } catch {
                XCTAssertEqual((error as? CalendarConnectionError)?.errorDescription, CalendarConnectionError.configuration.errorDescription)
            }
        }
        XCTAssertEqual(storage.saveCount, 0)
        let id = UUID()
        try storage.save(credential(.google, expires: .distantPast), id: id)
        do { _ = try await oauth.accessToken(id); XCTFail("Expired authorization must fail") }
        catch { XCTAssertEqual((error as? CalendarConnectionError)?.errorDescription, CalendarConnectionError.signInRequired.errorDescription) }
    }

    func testRemovingAnAccountPrunesHiddenIDsEvenBeforeItsFeedsLoad() async throws {
        let suite = "planner.visibility." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let removed = ConnectedCalendarAccount(id: UUID(), provider: .google, label: "Remove")
        let kept = ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Keep")
        defaults.set(try JSONEncoder().encode([removed, kept]), forKey: CalendarAccountSettings.accountsKey)
        let wanted: Set<String> = ["local", kept.id.uuidString + ":work"]
        defaults.set(Array(wanted.union([removed.id.uuidString + ":old", "apple:old"])), forKey: CalendarAccountSettings.hiddenFeedsKey)
        let connections = CalendarConnections(defaults: defaults, oauth: oauth, http: http)
        try await connections.remove(removed)
        connections.disableApple()
        XCTAssertEqual(connections.hiddenFeeds, wanted)
        XCTAssertEqual(Set(defaults.stringArray(forKey: CalendarAccountSettings.hiddenFeedsKey) ?? []), wanted)
        let hidden = (0..<CalendarAccountSettings.maximumHiddenFeeds).map { "fixture:\($0)" }
        defaults.set(hidden, forKey: CalendarAccountSettings.hiddenFeedsKey)
        let capped = CalendarConnections(defaults: defaults, oauth: oauth, http: http)
        capped.setVisible(false, feedID: "fixture:extra")
        XCTAssertEqual(capped.hiddenFeeds.count, hidden.count)
        XCTAssertNotNil(capped.errors["visibility"])
        XCTAssertNoThrow(try ConfigBackupRegistry.validate([CalendarAccountSettings.hiddenFeedsKey: .strings(Array(capped.hiddenFeeds))]))
        capped.setVisible(true, feedID: hidden[0])
        XCTAssertNil(capped.errors["visibility"])
    }

    func testDisconnectDuringRefreshCannotRecreateCredentials() async throws {
        let id = UUID()
        try storage.save(credential(.google, expires: .distantPast), id: id)
        let started = expectation(description: "token request")
        PlannerURLProtocol.delay = 0.08
        PlannerURLProtocol.handler = { _ in
            started.fulfill()
            return (200, ["access_token": "fixture-updated", "refresh_token": "fixture-rotated", "expires_in": 3600, "token_type": "bearer"])
        }
        let task = Task { try await oauth.accessToken(id) }
        await fulfillment(of: [started], timeout: 2)
        try await oauth.disconnect(id)
        do { _ = try await task.value; XCTFail("Disconnected refresh must fail") } catch { }
        XCTAssertNil(try storage.read(id))
    }

    func testGoogleAndZoomPaginationRecurrenceAndURLScoping() async throws {
        for provider in [CalendarProvider.google, .zoom] {
            let account = ConnectedCalendarAccount(id: UUID(), provider: provider, label: "Fixture")
            try storage.save(credential(provider), id: account.id)
            var requests = 0
            PlannerURLProtocol.handler = { request in
                requests += 1
                XCTAssertEqual(request.url?.host, provider.apiHost)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
                let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
                if components.path.hasSuffix("calendarList") {
                    return (200, ["kind": "calendar#calendarList", "items": [["id": "work/one@example.com", "summary": "Work"]]])
                }
                XCTAssertTrue(request.url!.absoluteString.contains("work%2Fone%40example.com"))
                XCTAssertEqual(components.queryItems?.first { $0.name == "singleEvents" }?.value, "true")
                if components.queryItems?.contains(where: { $0.name == "pageToken" }) == true { return (200, ["kind": "calendar#events", "items": []]) }
                return (200, ["kind": "calendar#events", "nextPageToken": "next+page", "items": [[
                    "id": "occurrence", "summary": "Meeting", "start": ["dateTime": "2026-10-19T10:00:00Z"],
                    "end": ["dateTime": "2026-10-19T11:00:00Z"]]]])
            }
            let snapshot = try await CalendarRemoteClient(http: http, oauth: oauth).snapshot(account: account,
                interval: DateInterval(start: CalendarDateCodec.parse("2026-10-01")!, duration: 42 * 86400))
            XCTAssertEqual(snapshot.feeds.count, 1); XCTAssertEqual(snapshot.events.count, 1)
            XCTAssertTrue(snapshot.events[0].id.hasPrefix(account.id.uuidString))
            XCTAssertEqual(requests, 3)
        }
    }

    func testMicrosoftRejectsOffHostPaginationBeforeSendingCredentials() async throws {
        let account = ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Work")
        try storage.save(credential(.microsoft), id: account.id)
        var requests = 0
        PlannerURLProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.url?.host, "graph.microsoft.com")
            return (200, ["value": [], "@odata.nextLink": "https://other.example/steal"])
        }
        do {
            _ = try await CalendarRemoteClient(http: http, oauth: oauth).snapshot(account: account, interval: DateInterval(start: Date(), duration: 86400))
            XCTFail("Untrusted pagination must fail")
        } catch { XCTAssertEqual(requests, 1) }
    }

    func test401RefreshAndGraphUTCHeader() async throws {
        let account = ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Work")
        try storage.save(credential(.microsoft), id: account.id)
        var requests = 0
        PlannerURLProtocol.handler = { request in
            requests += 1
            if request.url?.host == "login.microsoftonline.com" {
                return (200, ["access_token": "new-access", "expires_in": 3600, "token_type": "Bearer"])
            }
            XCTAssertTrue(request.value(forHTTPHeaderField: "Prefer")?.contains("UTC") == true)
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access" { return (401, ["error": "expired"]) }
            return (200, ["value": []])
        }
        let snapshot = try await CalendarRemoteClient(http: http, oauth: oauth).snapshot(account: account, interval: DateInterval(start: Date(), duration: 86400))
        XCTAssertTrue(snapshot.feeds.isEmpty); XCTAssertEqual(requests, 3)
        XCTAssertEqual(try storage.read(account.id)?.refreshToken, "fixture-refresh")
    }

    func testBrowserCallbackUsesLoopbackAndCanFinishWithoutOpeningBrowser() async throws {
        for provider in [CalendarProvider.google, .microsoft, .zoom] {
        let opened = expectation(description: "browser authorization")
        var authorization: URL?
        let info: [String: Any] = ["WhytapCalendarOAuthClients": [provider.rawValue: ["clientID": "fixture", "publicAccessApproved": "true"]]]
        let browser = CalendarBrowserSignIn(timeoutSeconds: 3, configurationInfo: info) { url in authorization = url; opened.fulfill(); return true }
        let task = Task { try await browser.authorize(provider: provider, clientID: "fixture", state: "expected", verifier: CalendarPKCE.random()) }
        await fulfillment(of: [opened], timeout: 2)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(authorization), resolvingAgainstBaseURL: false)?.queryItems)
        let redirect = try XCTUnwrap(query.first { $0.name == "redirect_uri" }?.value)
        XCTAssertTrue(redirect.hasPrefix(provider == .microsoft ? "http://localhost:" : "http://127.0.0.1:"))
        let url = try XCTUnwrap(URL(string: redirect + "?state=expected&code=fixture-code"))
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let result = try await task.value
        XCTAssertEqual(result.code, "fixture-code"); XCTAssertEqual(result.redirect, redirect)
        }
    }

    func testBrowserCancellationAndTimeoutReleasePendingSignIn() async throws {
        for cancel in [true, false] {
            let opened = expectation(description: "authorization ready")
            let browser = CalendarBrowserSignIn(timeoutSeconds: 0.05) { _ in opened.fulfill(); return true }
            let task = Task { try await browser.authorize(provider: .zoom, clientID: "fixture", state: "expected", verifier: CalendarPKCE.random()) }
            await fulfillment(of: [opened], timeout: 2)
            if cancel { browser.cancel() }
            do { _ = try await task.value; XCTFail("Cancelled or expired sign-in must fail") } catch { }
        }
    }
}
