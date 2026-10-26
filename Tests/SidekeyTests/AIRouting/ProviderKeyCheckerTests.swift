import XCTest
@testable import Sidekey

final class ProviderKeyCheckerTests: XCTestCase {
    private func makeChecker(
        handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)
    ) -> ProviderKeyChecker {
        StubURLProtocol.reset()
        addTeardownBlock { StubURLProtocol.reset() }
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return ProviderKeyChecker(session: session)
    }

    private func checker(status: Int, body: String = "{}") -> ProviderKeyChecker {
        makeChecker { _ in (status, [:], Data(body.utf8)) }
    }

    private func server(_ baseURL: String = "https://llm.example.com/v1") -> ServerEndpoint {
        ServerEndpoint(id: UUID(), name: "Local", baseURL: baseURL, keyAccount: "byok.server.test.api_key")
    }

    private func check(
        _ checker: ProviderKeyChecker,
        _ account: ProviderAccount,
        key: String? = "the-key",
        server: ServerEndpoint? = nil,
        paidProbe: Bool = false
    ) async -> KeyStatus {
        await checker.check(account, apiKey: key, server: server, allowPaidProbe: paidProbe)
    }

    // MARK: Requests

    func test_each_provider_sends_its_free_request_with_its_own_auth_header() async throws {
        let expectations: [(ProviderAccount, String, String, String)] = [
            (.soniox, "https://api.soniox.com/v1/models", "Authorization", "Bearer the-key"),
            (.deepgram, "https://api.deepgram.com/v1/projects", "Authorization", "Token the-key"),
            (.elevenLabs, "https://api.elevenlabs.io/v1/user", "xi-api-key", "the-key"),
            (.openRouter, "https://openrouter.ai/api/v1/key", "Authorization", "Bearer the-key"),
            (.openAI, "https://api.openai.com/v1/models", "Authorization", "Bearer the-key"),
        ]
        for (account, url, header, value) in expectations {
            let checker = checker(status: 200)
            let status = await check(checker, account)
            XCTAssertEqual(status, .valid, account.storageID)
            XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, account.storageID)
            let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, url)
            XCTAssertEqual(request.value(forHTTPHeaderField: header), value, account.storageID)
        }
    }

    func test_server_checks_its_models_url_with_bearer() async throws {
        let checker = checker(status: 200)
        let status = await check(checker, .server(UUID()), server: server("https://llm.example.com/v1"))
        XCTAssertEqual(status, .valid)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://llm.example.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer the-key")
    }

    func test_server_without_a_key_sends_no_authorization() async throws {
        let checker = checker(status: 200)
        let status = await check(checker, .server(UUID()), key: nil, server: server())
        XCTAssertEqual(status, .valid)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_built_in_provider_without_a_key_is_rejected_without_a_request() async {
        let checker = checker(status: 200)
        let status = await check(checker, .soniox, key: nil)
        XCTAssertEqual(status, .rejected(.invalidKey))
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: Status tables

    func test_soniox_codes() async {
        let table: [(Int, KeyStatus)] = [
            (200, .valid), (204, .valid), (401, .rejected(.invalidKey)),
            (403, .limited), (402, .rejected(.outOfCredit)),
        ]
        for (code, expected) in table {
            let status = await check(checker(status: code), .soniox)
            XCTAssertEqual(status, expected, "soniox \(code)")
        }
    }

    func test_deepgram_codes() async {
        let table: [(Int, String, KeyStatus)] = [
            (200, "{}", .valid),
            (401, #"{"err_code":"INVALID_AUTH"}"#, .rejected(.invalidKey)),
            (401, "", .rejected(.invalidKey)),
            (401, #"{"err_code":"INSUFFICIENT_PERMISSIONS"}"#, .limited),
            (403, "{}", .limited),
            (402, "{}", .rejected(.outOfCredit)),
        ]
        for (code, body, expected) in table {
            let status = await check(checker(status: code, body: body), .deepgram)
            XCTAssertEqual(status, expected, "deepgram \(code) \(body)")
        }
    }

    func test_elevenlabs_codes() async {
        let table: [(Int, KeyStatus)] = [
            (200, .valid), (401, .rejected(.invalidKey)),
            (403, .limited), (402, .rejected(.outOfCredit)),
        ]
        for (code, expected) in table {
            let status = await check(checker(status: code), .elevenLabs)
            XCTAssertEqual(status, expected, "elevenlabs \(code)")
        }
    }

    func test_openrouter_codes() async {
        let table: [(Int, KeyStatus)] = [
            (200, .valid), (401, .rejected(.invalidKey)),
            (402, .rejected(.outOfCredit)), (403, .unreachable),
        ]
        for (code, expected) in table {
            let status = await check(checker(status: code), .openRouter)
            XCTAssertEqual(status, expected, "openrouter \(code)")
        }
    }

    func test_openrouter_metadata_permission_refusal_is_limited_not_out_of_credit() async {
        let status = await check(checker(status: 403, body: #"{"error":{"code":403,"message":"Insufficient permissions"}}"#), .openRouter)
        XCTAssertEqual(status, .limited)
    }

    func test_openrouter_proxy_html_forbidden_is_not_a_key_or_credit_verdict() async {
        let status = await check(checker(status: 403, body: "<html><title>Access denied</title></html>"), .openRouter)
        XCTAssertEqual(status, .unreachable)
    }

    /// The free models list, with Anthropic's own headers and no Bearer.
    func test_anthropic_key_check_uses_x_api_key_and_version() async throws {
        let ok = checker(status: 200, body: #"{"data":[],"has_more":false}"#)
        let status = await check(ok, .anthropic)
        XCTAssertEqual(status, .valid)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "the-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let table: [(Int, KeyStatus)] = [
            (401, .rejected(.invalidKey)), (403, .rejected(.outOfCredit)),
            (429, .unreachable), (500, .unreachable), (529, .unreachable),
        ]
        for (code, expected) in table {
            let result = await check(checker(status: code), .anthropic)
            XCTAssertEqual(result, expected, "anthropic \(code)")
        }
        let missing = checker(status: 200)
        let noKey = await check(missing, .anthropic, key: nil)
        XCTAssertEqual(noKey, .rejected(.invalidKey))
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    func test_server_codes() async {
        let table: [(Int, KeyStatus)] = [
            (200, .valid), (404, .valid),
            (401, .rejected(.invalidKey)), (403, .rejected(.invalidKey)),
        ]
        for (code, expected) in table {
            let status = await check(checker(status: code), .server(UUID()), server: server())
            XCTAssertEqual(status, expected, "server \(code)")
        }
    }

    func test_server_with_an_unusable_address_is_unreachable() async {
        let checker = checker(status: 200)
        let status = await check(checker, .server(UUID()), server: server("not a url"))
        XCTAssertEqual(status, .unreachable)
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    func test_server_errors_are_unreachable() async {
        for code in [500, 502, 503] {
            let status = await check(checker(status: code), .soniox)
            XCTAssertEqual(status, .unreachable, "\(code)")
        }
    }

    func test_offline_is_unreachable() async {
        let checker = makeChecker { _ in throw URLError(.notConnectedToInternet) }
        for account in [ProviderAccount.soniox, .deepgram, .elevenLabs, .openRouter] {
            let status = await check(checker, account)
            XCTAssertEqual(status, .unreachable, account.storageID)
        }
    }

    // MARK: ElevenLabs paid probe

    func test_elevenlabs_scoped_key_is_limited_without_paid_probe() async {
        let checker = checker(status: 403)
        let status = await check(checker, .elevenLabs, paidProbe: false)
        XCTAssertEqual(status, .limited)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
    }

    func test_elevenlabs_paid_probe_rejects_a_dead_key() async throws {
        let checker = makeChecker { request in
            request.url?.path == "/v1/speech-to-text" ? (401, [:], Data("{}".utf8)) : (403, [:], Data("{}".utf8))
        }
        let status = await check(checker, .elevenLabs, paidProbe: true)
        XCTAssertEqual(status, .rejected(.invalidKey))
        XCTAssertEqual(StubURLProtocol.capturedRequests.map { $0.url?.path }, ["/v1/user", "/v1/speech-to-text"])
        let probe = try XCTUnwrap(StubURLProtocol.capturedRequests.last)
        XCTAssertEqual(probe.value(forHTTPHeaderField: "xi-api-key"), "the-key")
    }

    func test_elevenlabs_paid_probe_keeps_a_working_scoped_key_limited() async {
        let checker = makeChecker { request in
            request.url?.path == "/v1/speech-to-text"
                ? (200, [:], Data(#"{"text":""}"#.utf8)) : (403, [:], Data("{}".utf8))
        }
        let status = await check(checker, .elevenLabs, paidProbe: true)
        XCTAssertEqual(status, .limited)
    }

    func test_paid_probe_is_only_used_after_a_403() async {
        let checker = checker(status: 200)
        _ = await check(checker, .elevenLabs, paidProbe: true)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
    }

    /// ElevenLabs answers a scoped key that may not read `/v1/user` with 401
    /// `detail.status = missing_permissions`: a working key, not an invalid one
    /// (final review I4, ruling R18). Any other 401 stays invalid.
    func test_elevenlabs_401_missing_permissions_is_limited() async {
        let missing = #"{"detail":{"status":"missing_permissions","message":"The API key you used is missing the permission user_read"}}"#
        for paid in [false, true] {
            let status = await check(checker(status: 401, body: missing), .elevenLabs, paidProbe: paid)
            XCTAssertEqual(status, .limited, "paid probe allowed: \(paid)")
        }
        let invalid = #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#
        let rejected = await check(checker(status: 401, body: invalid), .elevenLabs, paidProbe: true)
        XCTAssertEqual(rejected, .rejected(.invalidKey))
        let unparsable = await check(checker(status: 401, body: "missing_permissions"), .elevenLabs)
        XCTAssertEqual(unparsable, .rejected(.invalidKey), "only the parsed detail.status counts")
    }

    /// No connection during the paid probe says nothing about the key
    /// (final review M4).
    func test_elevenlabs_paid_probe_offline_is_unreachable() async {
        let checker = makeChecker { request in
            if request.url?.path == "/v1/speech-to-text" { throw URLError(.notConnectedToInternet) }
            return (403, [:], Data("{}".utf8))
        }
        let status = await check(checker, .elevenLabs, paidProbe: true)
        XCTAssertEqual(status, .unreachable)
    }
}
