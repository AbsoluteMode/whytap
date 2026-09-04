import Foundation
import XCTest
@testable import Sidekey

final class UsefulLinksTests: XCTestCase {
    // MARK: - SSE / JSON decoding

    func testDecodesUsefulLinksBlockWithThreeLinks() throws {
        let json = """
        {
          "kind": "useful.links",
          "schemaVersion": 1,
          "links": [
            {"url": "https://www.notion.so/page", "description": "Spec doc", "provider": "notion"},
            {"url": "https://linear.app/team/issue/T-1", "description": "Ticket T-1", "provider": "linear"},
            {"url": "https://github.com/example/sidekey", "description": "Repo"}
          ]
        }
        """

        let block = try UIBlock.decodeWithGracefulFallback(json)

        guard case .usefulLinks(let payload) = block else {
            XCTFail("Expected usefulLinks, got \(block)")
            return
        }
        XCTAssertEqual(payload.links.count, 3)
        XCTAssertEqual(payload.links[0].provider, "notion")
        XCTAssertEqual(payload.links[1].provider, "linear")
        XCTAssertNil(payload.links[2].provider)
        XCTAssertEqual(payload.links[0].description, "Spec doc")
        XCTAssertEqual(payload.schemaVersion, 1)
    }

    func testDecoderTrimsToMaxLinksWhenBackendOversends() throws {
        // Backend contract still caps at 3 today, but the client accepts
        // up to 20 so it is ready for the backend rollout while still
        // defending against runaway payloads.
        let json = usefulLinksJSON(count: UsefulLinksBlock.maxLinks + 1)

        let block = try UIBlock.decodeWithGracefulFallback(json)

        guard case .usefulLinks(let payload) = block else {
            XCTFail("Expected usefulLinks, got \(block)")
            return
        }
        XCTAssertEqual(payload.links.count, UsefulLinksBlock.maxLinks)
        XCTAssertEqual(payload.links.last?.description, "\(UsefulLinksBlock.maxLinks)")
    }

    func testDecoderKeepsPayloadsUpToClientCap() throws {
        for count in [5, 10, UsefulLinksBlock.maxLinks] {
            let block = try UIBlock.decodeWithGracefulFallback(usefulLinksJSON(count: count))

            guard case .usefulLinks(let payload) = block else {
                XCTFail("Expected usefulLinks, got \(block)")
                return
            }
            XCTAssertEqual(payload.links.count, count)
            XCTAssertEqual(payload.links.last?.description, "\(count)")
        }
    }

    func testDecoderRejectsNonHttpURL() {
        // Frozen contract restricts to http(s). A `file://` or `javascript:`
        // URL must reject the whole link entry so the chip can't be talked
        // into opening a hostile scheme via NSWorkspace.
        let json = """
        {
          "kind": "useful.links",
          "schemaVersion": 1,
          "links": [
            {"url": "javascript:alert(1)", "description": "exploit"}
          ]
        }
        """

        XCTAssertThrowsError(try decode(json))
    }

    func testDecoderRejectsEmptyDescription() {
        let json = """
        {
          "kind": "useful.links",
          "schemaVersion": 1,
          "links": [
            {"url": "https://a.com", "description": ""}
          ]
        }
        """

        XCTAssertThrowsError(try decode(json))
    }

    func testDecoderRejectsDescriptionOver120Chars() {
        let long = String(repeating: "x", count: 121)
        let json = """
        {
          "kind": "useful.links",
          "schemaVersion": 1,
          "links": [
            {"url": "https://a.com", "description": "\(long)"}
          ]
        }
        """

        XCTAssertThrowsError(try decode(json))
    }

    func testDecoderAcceptsExactly120CharDescription() throws {
        let edge = String(repeating: "x", count: 120)
        let json = """
        {
          "kind": "useful.links",
          "schemaVersion": 1,
          "links": [
            {"url": "https://a.com", "description": "\(edge)"}
          ]
        }
        """

        let block = try UIBlock.decodeWithGracefulFallback(json)
        guard case .usefulLinks(let payload) = block else {
            XCTFail("Expected usefulLinks")
            return
        }
        XCTAssertEqual(payload.links.first?.description.count, 120)
    }

    func testDecoderNormalisesProviderToLowercase() throws {
        // Belt-and-braces: backend is supposed to emit lowercase but we
        // tolerate a "Notion" / "GITHUB" drift so the icon lookup table
        // stays the single source of truth for canonical form.
        let json = """
        {
          "kind": "useful.links",
          "schemaVersion": 1,
          "links": [
            {"url": "https://www.notion.so/p", "description": "x", "provider": "Notion"},
            {"url": "https://github.com/x/y", "description": "y", "provider": "GITHUB"}
          ]
        }
        """

        let block = try UIBlock.decodeWithGracefulFallback(json)
        guard case .usefulLinks(let payload) = block else {
            XCTFail("Expected usefulLinks")
            return
        }
        XCTAssertEqual(payload.links[0].provider, "notion")
        XCTAssertEqual(payload.links[1].provider, "github")
    }

    func testDecoderRejectsSchemaVersionMismatch() {
        // Future-proof: a v2 backend response must NOT silently render
        // as v1 — the decoder rejects so the prod fallback path emits
        // a stateError "Malformed server response" instead.
        let json = """
        {
          "kind": "useful.links",
          "schemaVersion": 99,
          "links": [
            {"url": "https://a.com", "description": "x"}
          ]
        }
        """

        XCTAssertThrowsError(try UIBlock.decodeWithGracefulFallback(json, env: .beta)) { error in
            XCTAssertEqual(
                error as? BlockDecodingError,
                .schemaVersionMismatch(expected: 1, actual: 99)
            )
        }
    }

    func testDecoderRejectsUnknownKindWithUnderscoreVariant() {
        // "useful_links" (snake case) is NOT the registered raw value —
        // only the dotted "useful.links" matches the UIBlockKind table.
        // A backend drift to snake_case must fail loudly so the issue
        // surfaces at decode time rather than silently rendering as
        // unknown.
        let json = """
        {
          "kind": "useful_links",
          "schemaVersion": 1,
          "links": [
            {"url": "https://a.com", "description": "x"}
          ]
        }
        """

        XCTAssertThrowsError(try UIBlock.decodeWithGracefulFallback(json, env: .beta)) { error in
            XCTAssertEqual(
                error as? BlockDecodingError,
                .unknownKind(raw: "useful_links")
            )
        }
    }

    // MARK: - Provider → asset mapping

    func testIconAssetForKnownProviderReturnsCanonicalName() {
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "notion"), "notion")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "linear"), "linear")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "slack"), "slack")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "github"), "github")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "gmail"), "gmail")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "gcalendar"), "gcalendar")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "jira"), "jira")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "figma"), "figma")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "asana"), "asana")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "confluence"), "confluence")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "discord"), "discord")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "trello"), "trello")
    }

    func testIconAssetForUnknownProviderFallsBackToGlobe() {
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "monday"), "globe")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "unknown-saas"), "globe")
    }

    func testIconAssetForNilProviderFallsBackToGlobe() {
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: nil), "globe")
    }

    func testIconAssetIsCaseInsensitiveOnInput() {
        // Belt-and-braces: even if the decoder somehow doesn't normalise
        // (e.g. directly-constructed in-process value) the asset map
        // still resolves canonically.
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "Notion"), "notion")
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "GITHUB"), "github")
    }

    // MARK: - Provider inference from URL host

    func testProviderInferenceMatchesKnownHosts() {
        let cases: [(URL, String)] = [
            (URL(string: "https://www.notion.so/page")!, "notion"),
            (URL(string: "https://workspace.notion.site/p")!, "notion"),
            (URL(string: "https://linear.app/team/issue/T-1")!, "linear"),
            (URL(string: "https://app.slack.com/client/T1/C2")!, "slack"),
            (URL(string: "https://github.com/example/sidekey")!, "github"),
            (URL(string: "https://mail.google.com/mail/u/0/#inbox")!, "gmail"),
            (URL(string: "https://calendar.google.com/calendar/u/0/r")!, "gcalendar"),
            (URL(string: "https://team.atlassian.net/browse/TICKET-1")!, "jira"),
            (URL(string: "https://www.figma.com/file/abc")!, "figma"),
            (URL(string: "https://app.asana.com/0/123/456")!, "asana"),
            (URL(string: "https://team.atlassian.net/wiki/spaces/HOME")!, "confluence"),
            (URL(string: "https://discord.com/channels/1/2")!, "discord"),
            (URL(string: "https://discord.gg/abc123")!, "discord"),
            (URL(string: "https://trello.com/b/abc/board")!, "trello")
        ]
        for (url, expected) in cases {
            XCTAssertEqual(
                UsefulLinkProviderInference.provider(for: url),
                expected,
                "host inference failed for \(url)"
            )
        }
    }

    func testProviderInferenceReturnsNilForUnknownHost() {
        let url = URL(string: "https://example.com/random/path")!
        XCTAssertNil(UsefulLinkProviderInference.provider(for: url))
    }

    func testProviderInferenceMatchesWikipediaBareDomain() {
        // Wikipedia is one of the most common general-knowledge sources the
        // agent surfaces. Without a host matcher the inference returns nil
        // and the chip falls through to the favicon path — but the regression
        // we are fixing is that a wrong explicit provider from the backend
        // (e.g. "notion") would otherwise win blindly. Pin the host matcher
        // so wikipedia.org always resolves to the canonical "wikipedia"
        // provider regardless of what the backend sends.
        let url = URL(string: "https://wikipedia.org/wiki/Whatever")!
        XCTAssertEqual(UsefulLinkProviderInference.provider(for: url), "wikipedia")
    }

    func testProviderInferenceMatchesWikipediaLanguageSubdomain() {
        // Wikipedia ships with ~300 language subdomains (en, ru, de, ja, ...)
        // — the host matcher must accept all of them, not just bare
        // wikipedia.org. Substring matching on "wikipedia.org" delivers that
        // for every standard language code at zero per-code cost.
        let urls = [
            URL(string: "https://en.wikipedia.org/wiki/Swift_(programming_language)")!,
            URL(string: "https://ru.wikipedia.org/wiki/Swift")!,
            URL(string: "https://de.wikipedia.org/wiki/Swift")!
        ]
        for url in urls {
            XCTAssertEqual(
                UsefulLinkProviderInference.provider(for: url),
                "wikipedia",
                "language subdomain inference failed for \(url)"
            )
        }
    }

    func testIconAssetForWikipediaFallsBackToGlobeUntilDedicatedAssetShips() {
        // Wikipedia is a recognised provider for inference / accessibility
        // purposes but we don't ship a brand PDF for it. The asset lookup
        // must therefore fall back to the globe glyph — not silently pick
        // an unrelated brand (e.g. "notion") because the canonical id is
        // missing from `knownProviders`. Locks the contract so a future
        // typo in `knownProviders` ("wiki" instead of "wikipedia") doesn't
        // accidentally remap Wikipedia links to a brand icon.
        XCTAssertEqual(UsefulLinkIconAsset.assetName(for: "wikipedia"), "globe")
    }

    func testChipResolvedProviderIgnoresExplicitProviderThatMismatchesURLHost() {
        // Defence against the backend sending a wrong `provider` field —
        // the original Wikipedia/Notion regression observed in prod was a
        // wiki URL arriving with `provider: "notion"`. Until the backend
        // fixes its tagger, the client must not trust the field blindly
        // when the URL host clearly belongs to a different provider.
        // Resolution should fall through to the host matcher, which
        // returns "wikipedia" for wikipedia.org URLs.
        let link = UsefulLink(
            url: URL(string: "https://en.wikipedia.org/wiki/Swift_(programming_language)")!,
            description: "Swift on Wikipedia",
            provider: "notion"
        )
        XCTAssertEqual(UsefulLinkChipView.resolvedProvider(for: link), "wikipedia")
    }

    func testChipResolvedProviderKeepsExplicitProviderWhenHostMatches() {
        // Counterpart to the mismatch guard: an explicit `provider` that
        // agrees with the URL host MUST be preserved — that's the canonical
        // happy path (backend tags a Notion link as `provider: "notion"`).
        // The host matcher would arrive at the same answer, but the
        // explicit field is cheaper and signals the backend's intent.
        let link = UsefulLink(
            url: URL(string: "https://www.notion.so/page")!,
            description: "Spec doc",
            provider: "notion"
        )
        XCTAssertEqual(UsefulLinkChipView.resolvedProvider(for: link), "notion")
    }

    func testChipResolvedProviderUsesInferenceWhenExplicitProviderIsNil() {
        // The decoder leaves `provider` as nil when the backend omits the
        // field. The chip falls back to URL-host inference so canonical
        // brands still light up their bundled icon without an explicit tag.
        let link = UsefulLink(
            url: URL(string: "https://linear.app/team/issue/T-1")!,
            description: "Ticket"
        )
        XCTAssertEqual(UsefulLinkChipView.resolvedProvider(for: link), "linear")
    }

    func testChipFaviconOverlayRunsForNilProvider() {
        // Unknown URL with no explicit / inferable provider — bundled icon
        // is globe, favicon overlay is the only way to surface anything
        // host-specific. Pin the contract so a refactor doesn't accidentally
        // short-circuit and leave the chip showing globe forever.
        XCTAssertTrue(UsefulLinkChipView.shouldOverlayFavicon(forResolvedProvider: nil))
    }

    func testChipFaviconOverlayRunsForResolvedWikipedia() {
        // Wikipedia is the canonical case the regression fix targets: the
        // host matcher resolves to "wikipedia", but the asset table falls
        // back to globe because no wikipedia.pdf ships. The favicon overlay
        // path MUST run so the chip ends up showing the W glyph instead of
        // a generic globe.
        XCTAssertTrue(UsefulLinkChipView.shouldOverlayFavicon(forResolvedProvider: "wikipedia"))
    }

    func testChipFaviconOverlaySkippedForBundledBrands() {
        // Brand providers ship their own PDFs — the favicon overlay would
        // replace a canonical brand mark with a tinted PNG and lose visual
        // identity. Sweep every bundled provider to lock the contract.
        for provider in UsefulLinkIconAsset.knownProviders {
            XCTAssertFalse(
                UsefulLinkChipView.shouldOverlayFavicon(forResolvedProvider: provider),
                "favicon overlay must stay off for bundled brand \(provider)"
            )
        }
    }

    func testChipResolvedProviderReturnsNilForUnknownHostWithNoExplicitProvider() {
        // A truly unknown URL (no explicit provider, no host match) signals
        // to the chip view that the favicon-overlay path should run. That
        // path is the only way to surface a host-derived icon for the long
        // tail of sites the bundled brand catalogue doesn't cover.
        let link = UsefulLink(
            url: URL(string: "https://random-saas-example.com/page")!,
            description: "Random page"
        )
        XCTAssertNil(UsefulLinkChipView.resolvedProvider(for: link))
    }

    func testProviderInferenceConfluenceTakesPrecedenceOverJiraOnSharedDomain() {
        // Both Jira and Confluence live on `*.atlassian.net`. Confluence
        // pages live under `/wiki/`, Jira issues live under `/browse/`.
        // Ordering of the matcher table makes Jira win on a bare host so
        // a `/wiki/` URL must explicitly match Confluence first.
        let confluence = URL(string: "https://team.atlassian.net/wiki/spaces/HOME")!
        let jira = URL(string: "https://team.atlassian.net/browse/T-1")!
        XCTAssertEqual(UsefulLinkProviderInference.provider(for: confluence), "confluence")
        XCTAssertEqual(UsefulLinkProviderInference.provider(for: jira), "jira")
    }

    // MARK: - Favicon endpoint

    func testFaviconS2EndpointShapesQuery() {
        let url = URL(string: "https://docs.example.com/page")!
        let endpoint = FaviconService.s2Endpoint(for: url)

        XCTAssertNotNil(endpoint)
        XCTAssertEqual(endpoint?.host, "www.google.com")
        XCTAssertEqual(endpoint?.path, "/s2/favicons")
        let q = URLComponents(url: endpoint!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(q.first(where: { $0.name == "domain" })?.value, "docs.example.com")
        XCTAssertEqual(q.first(where: { $0.name == "sz" })?.value, "64")
    }

    func testFaviconS2EndpointNilForURLWithoutHost() {
        // `mailto:` URLs lack a host — the favicon proxy can't do
        // anything with them, return nil and let the chip stay on its
        // bundled fallback.
        let url = URL(string: "mailto:alice@example.com")!
        XCTAssertNil(FaviconService.s2Endpoint(for: url))
    }

    // MARK: - Registry dispatch

    func testRegistryDispatchesUsefulLinksToUsefulLinksBlockView() {
        let block = UIBlock.usefulLinks(UsefulLinksBlock(links: [
            UsefulLink(
                url: URL(string: "https://example.com")!,
                description: "Example"
            )
        ]))
        XCTAssertEqual(
            BlockRendererRegistry.rendererTypeName(for: block),
            "UsefulLinksBlockView"
        )
    }

    // MARK: - Chip vertical shrink (Subtask E)
    //
    // Maxim: "еще давай вот где он ссылки отдает тоже сделаем поуже …
    // по вертикали". The chip used to render a 24pt icon next to a
    // 2-line 12pt description with 6pt vertical padding — roughly a
    // 50pt-tall capsule. Single-line truncation + smaller icon + tighter
    // padding bring the chip down into the ~30pt neighbourhood so a
    // 3-chip useful-links block doesn't dominate the response panel.

    func testUsefulLinkChipIconSizeIsShrunkPerMaximDirective() {
        // Icon caps at 18pt (was 24pt) so the chip's vertical envelope
        // is bounded by the icon column, not the text column. Below
        // 14pt the favicons read as pixel mush; above 22pt the chip's
        // intrinsic height climbs back above ~32pt.
        XCTAssertGreaterThanOrEqual(UsefulLinkChipView.iconSize, 14)
        XCTAssertLessThanOrEqual(UsefulLinkChipView.iconSize, 22)
    }

    func testUsefulLinkChipIconSizeIsPostShrinkValue() {
        // Pin at the post-shrink 18pt so a future "restore brand
        // affordance" rebase doesn't silently undo the vertical shrink.
        XCTAssertEqual(UsefulLinkChipView.iconSize, 18)
    }

    // MARK: - Helpers

    private func decode(_ json: String) throws -> UIBlock {
        try UIBlock.decodeWithGracefulFallback(json, env: .beta)
    }

    private func usefulLinksJSON(count: Int) -> String {
        let links = (1...count)
            .map { index in
                "{\"url\": \"https://example\(index).com\", \"description\": \"\(index)\"}"
            }
            .joined(separator: ",\n")
        return """
        {
          "kind": "useful.links",
          "schemaVersion": 1,
          "links": [
        \(links)
          ]
        }
        """
    }
}
