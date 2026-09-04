import Foundation

enum UIBlockKind: String, Codable, Equatable {
    case textAnswer = "text.answer"
    case entityCard = "entity.card"
    case entityList = "entity.list"
    case metricCard = "metric.card"
    case searchResults = "search.results"
    case stateEmpty = "state.empty"
    case stateError = "state.error"
    case statePermission = "state.permission"
    case usefulLinks = "useful.links"
    case usefulActions = "useful.actions"
}

enum BlockDecodingError: Error, Equatable, CustomStringConvertible {
    case unknownKind(raw: String)
    case schemaVersionMismatch(expected: Int, actual: Int?)

    var description: String {
        switch self {
        case .unknownKind(let raw):
            return "Unknown UIBlock kind: \(raw)"
        case .schemaVersionMismatch(let expected, let actual):
            return "Unsupported UIBlock schemaVersion: \(actual.map(String.init) ?? "nil"), expected \(expected)"
        }
    }
}

indirect enum AnyCodable: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodable].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyCodable].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

struct UIAction: Codable, Equatable {
    enum ActionType: String, Codable, Equatable {
        case open
        case copy
        case retry
        case connect
    }

    enum ActionVariant: String, Codable, Equatable {
        case primary
        case secondary
    }

    let type: ActionType
    let label: String
    let url: URL?
    let payload: AnyCodable?
    let variant: ActionVariant?

    init(
        type: ActionType,
        label: String,
        url: URL? = nil,
        payload: AnyCodable? = nil,
        variant: ActionVariant? = nil
    ) {
        self.type = type
        self.label = label
        self.url = url
        self.payload = payload
        self.variant = variant
    }
}

struct Source: Codable, Equatable {
    let id: String
    let title: String
    let url: URL?
    let provider: String?

    init(id: String, title: String, url: URL? = nil, provider: String? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.provider = provider
    }
}

enum UIBlock: Codable, Equatable {
    static let supportedSchemaVersion = 1
    static let maxBlocksPerResponse = 3

    case textAnswer(TextAnswerBlock)
    case entityCard(EntityCardBlock)
    case entityList(EntityListBlock)
    case metricCard(MetricCardBlock)
    case searchResults(SearchResultsBlock)
    case stateEmpty(StateEmptyBlock)
    case stateError(StateErrorBlock)
    case statePermission(StatePermissionBlock)
    case usefulLinks(UsefulLinksBlock)
    case usefulActions(UsefulActionsBlock)

    var kind: UIBlockKind {
        switch self {
        case .textAnswer:
            return .textAnswer
        case .entityCard:
            return .entityCard
        case .entityList:
            return .entityList
        case .metricCard:
            return .metricCard
        case .searchResults:
            return .searchResults
        case .stateEmpty:
            return .stateEmpty
        case .stateError:
            return .stateError
        case .statePermission:
            return .statePermission
        case .usefulLinks:
            return .usefulLinks
        case .usefulActions:
            return .usefulActions
        }
    }

    var schemaVersion: Int {
        switch self {
        case .textAnswer(let block):
            return block.schemaVersion
        case .entityCard(let block):
            return block.schemaVersion
        case .entityList(let block):
            return block.schemaVersion
        case .metricCard(let block):
            return block.schemaVersion
        case .searchResults(let block):
            return block.schemaVersion
        case .stateEmpty(let block):
            return block.schemaVersion
        case .stateError(let block):
            return block.schemaVersion
        case .statePermission(let block):
            return block.schemaVersion
        case .usefulLinks(let block):
            return block.schemaVersion
        case .usefulActions(let block):
            return block.schemaVersion
        }
    }

    var title: String? {
        switch self {
        case .textAnswer(let block):
            return block.title
        case .entityCard(let block):
            return block.title
        case .entityList(let block):
            return block.title
        case .metricCard(let block):
            return block.title
        case .searchResults(let block):
            return block.title
        case .stateEmpty(let block):
            return block.title
        case .stateError(let block):
            return block.title
        case .statePermission(let block):
            return block.title
        case .usefulLinks:
            // Useful Links block has no title field in the frozen SSE
            // contract — the chip row is the entire visible payload.
            return nil
        case .usefulActions:
            // Useful Actions mirrors Useful Links: no title field, the
            // typed action chips are the entire visible payload.
            return nil
        }
    }

    init(from decoder: Decoder) throws {
        let header = try UIBlockHeader(from: decoder)
        guard let kind = UIBlockKind(rawValue: header.kind) else {
            throw BlockDecodingError.unknownKind(raw: header.kind)
        }
        guard header.schemaVersion == Self.supportedSchemaVersion else {
            throw BlockDecodingError.schemaVersionMismatch(
                expected: Self.supportedSchemaVersion,
                actual: header.schemaVersion
            )
        }

        switch kind {
        case .textAnswer:
            self = .textAnswer(try TextAnswerBlock(from: decoder))
        case .entityCard:
            self = .entityCard(try EntityCardBlock(from: decoder))
        case .entityList:
            self = .entityList(try EntityListBlock(from: decoder))
        case .metricCard:
            self = .metricCard(try MetricCardBlock(from: decoder))
        case .searchResults:
            self = .searchResults(try SearchResultsBlock(from: decoder))
        case .stateEmpty:
            self = .stateEmpty(try StateEmptyBlock(from: decoder))
        case .stateError:
            self = .stateError(try StateErrorBlock(from: decoder))
        case .statePermission:
            self = .statePermission(try StatePermissionBlock(from: decoder))
        case .usefulLinks:
            self = .usefulLinks(try UsefulLinksBlock(from: decoder))
        case .usefulActions:
            self = .usefulActions(try UsefulActionsBlock(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .textAnswer(let block):
            try block.encode(to: encoder)
        case .entityCard(let block):
            try block.encode(to: encoder)
        case .entityList(let block):
            try block.encode(to: encoder)
        case .metricCard(let block):
            try block.encode(to: encoder)
        case .searchResults(let block):
            try block.encode(to: encoder)
        case .stateEmpty(let block):
            try block.encode(to: encoder)
        case .stateError(let block):
            try block.encode(to: encoder)
        case .statePermission(let block):
            try block.encode(to: encoder)
        case .usefulLinks(let block):
            try block.encode(to: encoder)
        case .usefulActions(let block):
            try block.encode(to: encoder)
        }
    }

    static func decodeWithGracefulFallback(
        _ data: Data,
        env: BuildFlavor = BuildConfig.flavor,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> UIBlock {
        do {
            return try decoder.decode(UIBlock.self, from: data)
        } catch {
            guard env == .prod else { throw error }
            return .stateError(StateErrorBlock.malformedResponse())
        }
    }

    static func decodeWithGracefulFallback(
        _ json: String,
        env: BuildFlavor = BuildConfig.flavor,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> UIBlock {
        try decodeWithGracefulFallback(Data(json.utf8), env: env, decoder: decoder)
    }
}

private struct UIBlockHeader: Decodable {
    let kind: String
    let schemaVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion
    }
}

struct TextAnswerBlock: Codable, Equatable {
    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let body: String

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        body: String
    ) {
        self.kind = .textAnswer
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.body = body
    }
}

struct EntityCardBlock: Codable, Equatable {
    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let entityType: UIBlockEntityType
    let id: String?
    let name: String
    let description: String?
    let url: URL?
    let attributes: [String: AnyCodable]?

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        entityType: UIBlockEntityType,
        id: String? = nil,
        name: String,
        description: String? = nil,
        url: URL? = nil,
        attributes: [String: AnyCodable]? = nil
    ) {
        self.kind = .entityCard
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.entityType = entityType
        self.id = id
        self.name = name
        self.description = description
        self.url = url
        self.attributes = attributes
    }
}

struct EntityListBlock: Codable, Equatable {
    struct Item: Codable, Equatable {
        let id: String?
        let title: String
        let subtitle: String?
        let entityType: UIBlockEntityType?
        let url: URL?
        let attributes: [String: AnyCodable]?

        init(
            id: String? = nil,
            title: String,
            subtitle: String? = nil,
            entityType: UIBlockEntityType? = nil,
            url: URL? = nil,
            attributes: [String: AnyCodable]? = nil
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.entityType = entityType
            self.url = url
            self.attributes = attributes
        }
    }

    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let entityType: UIBlockEntityType?
    let items: [Item]

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        entityType: UIBlockEntityType? = nil,
        items: [Item]
    ) {
        self.kind = .entityList
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.entityType = entityType
        self.items = items
    }
}

struct MetricCardBlock: Codable, Equatable {
    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let label: String
    let value: String
    let unit: String?
    let trend: String?

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        label: String,
        value: String,
        unit: String? = nil,
        trend: String? = nil
    ) {
        self.kind = .metricCard
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.label = label
        self.value = value
        self.unit = unit
        self.trend = trend
    }
}

struct SearchResultsBlock: Codable, Equatable {
    struct Result: Codable, Equatable {
        let title: String
        let snippet: String?
        let url: URL?
        let sourceId: String?

        init(title: String, snippet: String? = nil, url: URL? = nil, sourceId: String? = nil) {
            self.title = title
            self.snippet = snippet
            self.url = url
            self.sourceId = sourceId
        }
    }

    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let results: [Result]

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        results: [Result]
    ) {
        self.kind = .searchResults
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.results = results
    }
}

struct StateEmptyBlock: Codable, Equatable {
    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let message: String

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        message: String
    ) {
        self.kind = .stateEmpty
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.message = message
    }
}

typealias BlockMalformedError = StateErrorBlock

struct StateErrorBlock: Codable, Equatable {
    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let message: String
    let code: String?
    let retryable: Bool

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        message: String,
        code: String? = nil,
        retryable: Bool
    ) {
        self.kind = .stateError
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.message = message
        self.code = code
        self.retryable = retryable
    }

    static func malformedResponse() -> BlockMalformedError {
        StateErrorBlock(
            title: "Response error",
            actions: [
                UIAction(
                    type: .retry,
                    label: "Retry",
                    variant: .primary
                )
            ],
            message: "Malformed server response.",
            code: "block_malformed",
            retryable: true
        )
    }
}

struct StatePermissionBlock: Codable, Equatable {
    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let provider: String
    let message: String?

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        provider: String,
        message: String? = nil
    ) {
        self.kind = .statePermission
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.provider = provider
        self.message = message
    }
}

/// A single link entry inside a `UsefulLinksBlock`. The frozen SSE contract
/// guarantees `url` and `description`; `provider` is optional and, when
/// present, is a lowercase canonical provider id (`notion`, `linear`, ...).
/// An absent or unknown `provider` causes the chip to fall back to a host-
/// derived favicon or the globe glyph.
struct UsefulLink: Codable, Equatable, Sendable {
    /// Max chars for `description`. The block schema already caps it at 1-120
    /// but the decoder defends against drift: anything longer is rejected so a
    /// runaway string doesn't blow out the chip layout.
    static let maxDescriptionLength = 120

    let url: URL
    let description: String
    let provider: String?

    init(url: URL, description: String, provider: String? = nil) {
        self.url = url
        self.description = description
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case description
        case provider
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let url = try container.decode(URL.self, forKey: .url)
        let description = try container.decode(String.self, forKey: .description)
        let provider = try container.decodeIfPresent(String.self, forKey: .provider)

        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw DecodingError.dataCorruptedError(
                forKey: .url,
                in: container,
                debugDescription: "UsefulLink.url must be an http(s) URL."
            )
        }
        guard !description.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .description,
                in: container,
                debugDescription: "UsefulLink.description must be non-empty."
            )
        }
        guard description.count <= Self.maxDescriptionLength else {
            throw DecodingError.dataCorruptedError(
                forKey: .description,
                in: container,
                debugDescription: "UsefulLink.description exceeds \(Self.maxDescriptionLength) chars."
            )
        }

        self.url = url
        self.description = description
        // Normalise to lowercase canonical form. The schema asks for
        // lowercase already; this is belt-and-braces so the lookup
        // map in the chip view doesn't have to handle case variants.
        self.provider = provider?.lowercased()
    }
}

/// Block payload for the "useful.links" SSE message. Carries up to
/// `maxLinks` links that the response panel renders below Pill 2 (or
/// alongside, depending on context) as compact chips with brand icons.
/// Decoder silently truncates a 21+ link payload to the first `maxLinks`
/// entries. The block schema caps at 3, but the decoder accepts up to 20
/// so a slightly chattier model still renders, while keeping a runaway guard.
struct UsefulLinksBlock: Codable, Equatable, Sendable {
    static let maxLinks = 20

    let kind: UIBlockKind
    let schemaVersion: Int
    let title: String?
    let subtitle: String?
    let actions: [UIAction]?
    let sourceIds: [String]?
    let links: [UsefulLink]

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        title: String? = nil,
        subtitle: String? = nil,
        actions: [UIAction]? = nil,
        sourceIds: [String]? = nil,
        links: [UsefulLink]
    ) {
        self.kind = .usefulLinks
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        // Cap at maxLinks even for in-process constructors — keeps the
        // post-decode invariant consistent with the wire-format invariant.
        self.links = Array(links.prefix(Self.maxLinks))
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion
        case title
        case subtitle
        case actions
        case sourceIds
        case links
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let title = try container.decodeIfPresent(String.self, forKey: .title)
        let subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        let actions = try container.decodeIfPresent([UIAction].self, forKey: .actions)
        let sourceIds = try container.decodeIfPresent([String].self, forKey: .sourceIds)
        let rawLinks = try container.decode([UsefulLink].self, forKey: .links)

        self.kind = .usefulLinks
        self.schemaVersion = schemaVersion
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
        self.sourceIds = sourceIds
        self.links = Array(rawLinks.prefix(Self.maxLinks))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(actions, forKey: .actions)
        try container.encodeIfPresent(sourceIds, forKey: .sourceIds)
        try container.encode(links, forKey: .links)
    }
}

/// The set of one-keystroke operations an `ActionItem` exposes. `insert`
/// pastes the item's `insertText` into the focused field (the left-arrow
/// affordance, identical to how Useful Links insert today); `open` hands the
/// item to the system (browser for links, default app for file paths). Copy
/// items only carry text to insert, so they never offer `open`.
enum ActionKind: Equatable, Sendable {
    case insert
    case open
}

/// A single typed, actionable entry inside a `UsefulActionsBlock`. Generalises
/// the link-only `UsefulLink` into three shapes the agent can surface as
/// chips: an external `link`, a filesystem `path`, or arbitrary `copy` text.
/// Each item knows which actions it supports and what string an insert pastes.
///
/// Wire shape per item: `{"type": "link"|"path"|"copy", "description": ...,
/// url|path|text: ...}`. The decoder reads `type` first, then the
/// type-specific payload field; a missing or invalid required field throws.
/// Element decoding is all-or-nothing (same as `UsefulLinksBlock.links`): a
/// single bad item makes the whole block fail to decode, and the extractor's
/// `try?` then falls back rather than emitting a partial list.
enum ActionItem: Codable, Equatable, Sendable {
    /// External link. `url` must be http(s) (same rule as `UsefulLink`), the
    /// description is required and capped at `UsefulLink.maxDescriptionLength`,
    /// and `provider`, when present, is a lowercase canonical provider id.
    case link(url: URL, description: String, provider: String?)
    /// Filesystem path. `path` must be non-empty; `description` is optional.
    case path(path: String, description: String?)
    /// Arbitrary text to paste. `text` must be non-empty; `description` is
    /// optional.
    case copy(text: String, description: String?)

    /// Discriminator value carried by the `type` field on the wire.
    private enum ItemType: String, Codable {
        case link
        case path
        case copy
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case provider
        case url
        case path
        case text
    }

    /// Actions this item exposes, in display order. Links and paths can be
    /// inserted or opened; copy text can only be inserted.
    var availableActions: [ActionKind] {
        switch self {
        case .link, .path:
            return [.insert, .open]
        case .copy:
            return [.insert]
        }
    }

    /// String an `insert` action pastes into the focused field: the absolute
    /// URL for a link, the raw path for a path, the text for a copy item.
    var insertText: String {
        switch self {
        case .link(let url, _, _):
            return url.absoluteString
        case .path(let path, _):
            return path
        case .copy(let text, _):
            return text
        }
    }

    /// The destination an `open` action hands to `NSWorkspace.shared.open`,
    /// or `nil` for items that do not expose `open`:
    /// - link: the http(s) URL itself, opened in the default browser.
    /// - path: a `file://` URL built via `URL(fileURLWithPath:)`, so the system
    ///   opens the file in its default app — a Finder-style double-click, never
    ///   an auto-run of the path's contents.
    /// - copy: `nil` — copy items only carry text to insert.
    ///
    /// Kept as a pure computed property so the open behaviour is unit-testable
    /// without touching `NSWorkspace`, and so `availableActions` and this stay
    /// in lockstep (copy → no `.open`, no `openTarget`).
    var openTarget: URL? {
        switch self {
        case .link(let url, _, _):
            return url
        case .path(let path, _):
            return URL(fileURLWithPath: path)
        case .copy:
            return nil
        }
    }

    /// The per-item description shown on the chip. Required for links, optional
    /// for paths and copy items.
    var description: String? {
        switch self {
        case .link(_, let description, _):
            return description
        case .path(_, let description):
            return description
        case .copy(_, let description):
            return description
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ItemType.self, forKey: .type)
        switch type {
        case .link:
            let url = try container.decode(URL.self, forKey: .url)
            let description = try container.decode(String.self, forKey: .description)
            let provider = try container.decodeIfPresent(String.self, forKey: .provider)

            guard let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw DecodingError.dataCorruptedError(
                    forKey: .url,
                    in: container,
                    debugDescription: "ActionItem.link.url must be an http(s) URL."
                )
            }
            guard !description.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .description,
                    in: container,
                    debugDescription: "ActionItem.link.description must be non-empty."
                )
            }
            guard description.count <= UsefulLink.maxDescriptionLength else {
                throw DecodingError.dataCorruptedError(
                    forKey: .description,
                    in: container,
                    debugDescription: "ActionItem.link.description exceeds \(UsefulLink.maxDescriptionLength) chars."
                )
            }
            // Normalise the provider to lowercase, matching UsefulLink.
            self = .link(url: url, description: description, provider: provider?.lowercased())
        case .path:
            let path = try container.decode(String.self, forKey: .path)
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            guard !path.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "ActionItem.path.path must be non-empty."
                )
            }
            self = .path(path: path, description: description)
        case .copy:
            let text = try container.decode(String.self, forKey: .text)
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            guard !text.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .text,
                    in: container,
                    debugDescription: "ActionItem.copy.text must be non-empty."
                )
            }
            self = .copy(text: text, description: description)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .link(let url, let description, let provider):
            try container.encode(ItemType.link, forKey: .type)
            try container.encode(url, forKey: .url)
            try container.encode(description, forKey: .description)
            try container.encodeIfPresent(provider, forKey: .provider)
        case .path(let path, let description):
            try container.encode(ItemType.path, forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(description, forKey: .description)
        case .copy(let text, let description):
            try container.encode(ItemType.copy, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(description, forKey: .description)
        }
    }
}

/// Block payload for the "useful.actions" message: a single ordered list of
/// typed `ActionItem`s (link / path / copy) the response panel renders as
/// actionable chips. Generalises `UsefulLinksBlock` from link-only to mixed
/// action types. Kept intentionally minimal — `schemaVersion` + `items`, no
/// title/subtitle — because the chip row is the entire visible payload (same
/// as Useful Links). The item list is capped at `maxItems`; the decoder
/// silently truncates a longer payload. Item decoding is all-or-nothing (a
/// single malformed item fails the whole block, matching `UsefulLinksBlock`).
struct UsefulActionsBlock: Codable, Equatable, Sendable {
    static let maxItems = 20

    let kind: UIBlockKind
    let schemaVersion: Int
    let items: [ActionItem]

    init(
        schemaVersion: Int = UIBlock.supportedSchemaVersion,
        items: [ActionItem]
    ) {
        self.kind = .usefulActions
        self.schemaVersion = schemaVersion
        // Cap at maxItems even for in-process constructors so the post-decode
        // invariant matches the wire-format invariant.
        self.items = Array(items.prefix(Self.maxItems))
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case schemaVersion
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let rawItems = try container.decode([ActionItem].self, forKey: .items)

        self.kind = .usefulActions
        self.schemaVersion = schemaVersion
        self.items = Array(rawItems.prefix(Self.maxItems))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(items, forKey: .items)
    }
}
