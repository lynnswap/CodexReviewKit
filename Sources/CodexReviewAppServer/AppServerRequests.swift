import Foundation
import CodexReview

package enum AppServerAPI {
    package enum Initialize {}
    package enum Thread {
        package enum Start {}
        package enum Rollback {}
        package enum Delete {}
        package enum Unsubscribe {}
        package enum BackgroundTerminals {
            package enum Clean {}
        }
    }
    package enum Review {
        package enum Start {}
    }
    package enum Turn {
        package enum Interrupt {}
    }
    package enum Config {
        package enum Read {}
        package enum BatchWrite {}
    }
    package enum Model {
        package enum List {}
    }
    package enum Auth {
        package enum Read {}
    }
    package enum Account {
        package enum Read {}
        package enum RateLimits {
            package enum Read {}
        }
        package enum Login {
            package enum Complete {}
            package enum Cancel {}
        }
    }
}

package extension AppServerAPI {
enum RequestScope: Hashable, Sendable {
    case thread(String)
}
}


package extension AppServerAPI.Thread.Start {
enum PermissionStrategy: Equatable, Sendable {
    case modernPermissions
    case legacySandbox
}
}


package extension AppServerAPI {
protocol Request: Sendable {
    associatedtype Params: Encodable & Sendable
    associatedtype Response: Decodable & Sendable

    static var method: String { get }
    var params: Params { get }
    var scope: AppServerAPI.RequestScope? { get }
}
}


extension AppServerAPI.Request {
    package var scope: AppServerAPI.RequestScope? { nil }
}

package extension AppServerAPI.Initialize {
struct ClientInfo: Codable, Equatable, Sendable {
    package var name: String
    package var title: String?
    package var version: String

    package init(name: String, title: String? = nil, version: String) {
        self.name = name
        self.title = title
        self.version = version
    }
}
}


package extension AppServerAPI.Initialize {
struct Capabilities: Codable, Equatable, Sendable {
    package var experimentalAPI: Bool

    enum CodingKeys: String, CodingKey {
        case experimentalAPI = "experimentalApi"
    }

    package init(experimentalAPI: Bool = true) {
        self.experimentalAPI = experimentalAPI
    }
}
}


package extension AppServerAPI.Initialize {
struct Params: Codable, Equatable, Sendable {
    package var clientInfo: AppServerAPI.Initialize.ClientInfo
    package var capabilities: AppServerAPI.Initialize.Capabilities

    enum CodingKeys: String, CodingKey {
        case clientInfo
        case capabilities
    }

    package init(clientName: String, clientVersion: String) {
        self.clientInfo = .init(name: clientName, version: clientVersion)
        self.capabilities = .init()
    }
}
}


package extension AppServerAPI.Initialize {
struct Response: Codable, Equatable, Sendable {
    package var codexHome: String?
    package var userAgent: String?

    package init(codexHome: String? = nil, userAgent: String? = nil) {
        self.codexHome = codexHome
        self.userAgent = userAgent
    }
}
}


package extension AppServerAPI.Initialize {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Initialize.Response

    package static let method = "initialize"
    package var params: AppServerAPI.Initialize.Params

    package init(params: AppServerAPI.Initialize.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Thread.Start {
struct Params: Codable, Equatable, Sendable {
    package var cwd: String
    package var model: String?
    package var ephemeral: Bool?
    package var approvalPolicy: String?
    package var sandbox: String?
    package var permissions: AppServerAPI.Thread.Start.Permissions?
    // Session start source drives lifecycle hooks; thread source is analytics classification.
    package var sessionStartSource: AppServerAPI.Thread.Start.Source?
    package var threadSource: AppServerAPI.Thread.Source?

    package init(
        cwd: String,
        model: String? = nil,
        ephemeral: Bool? = nil,
        approvalPolicy: String? = nil,
        sandbox: String? = nil,
        permissions: AppServerAPI.Thread.Start.Permissions? = nil,
        sessionStartSource: AppServerAPI.Thread.Start.Source? = nil,
        threadSource: AppServerAPI.Thread.Source? = nil
    ) {
        self.cwd = cwd
        self.model = model
        self.ephemeral = ephemeral
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
        self.permissions = permissions
        self.sessionStartSource = sessionStartSource
        self.threadSource = threadSource
    }
}
}


package extension AppServerAPI.Thread.Start {
enum Source: String, Codable, Equatable, Sendable {
    case startup
    case clear
}
}


package extension AppServerAPI.Thread {
enum Source: String, Codable, Equatable, Sendable {
    case user
    case subagent
    case memoryConsolidation = "memory_consolidation"
}
}


package extension AppServerAPI.Thread.Start {
enum Permissions: Codable, Equatable, Sendable {
    case profileID(String)
    case profileSelection(AppServerAPI.Thread.Start.PermissionProfileSelection)

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let profileID = try? container.decode(String.self) {
            self = .profileID(profileID)
            return
        }
        if let profileSelection = try? container.decode(AppServerAPI.Thread.Start.PermissionProfileSelection.self) {
            self = .profileSelection(profileSelection)
            return
        }
        throw DecodingError.typeMismatch(
            AppServerAPI.Thread.Start.Permissions.self,
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a permissions profile ID or profile selection object."
            )
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .profileID(let profileID):
            try container.encode(profileID)
        case .profileSelection(let profileSelection):
            try container.encode(profileSelection)
        }
    }
}
}


package extension AppServerAPI.Thread.Start {
struct PermissionProfileSelection: Codable, Equatable, Sendable {
    package var type: String
    package var id: String

    package init(id: String, type: String = "profile") {
        self.type = type
        self.id = id
    }
}
}


package extension AppServerAPI.Thread.Start {
struct Response: Codable, Equatable, Sendable {
    package var threadID: String
    package var model: String?

    enum CodingKeys: String, CodingKey {
        case thread
        case model
    }

    private struct Thread: Codable, Equatable, Sendable {
        var id: String
    }

    package init(threadID: String, model: String? = nil) {
        self.threadID = threadID
        self.model = model
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.threadID = try container.decode(Thread.self, forKey: .thread).id
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Thread(id: threadID), forKey: .thread)
        try container.encodeIfPresent(model, forKey: .model)
    }
}
}


package extension AppServerAPI.Thread.Start {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Thread.Start.Response

    package static let method = "thread/start"
    package var params: AppServerAPI.Thread.Start.Params

    package init(params: AppServerAPI.Thread.Start.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Review.Start {
struct Params: Codable, Equatable, Sendable {
    package var threadID: String
    package var target: CodexReviewAPI.Target
    package var delivery: AppServerAPI.Review.Start.Delivery

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case target
        case delivery
    }

    package init(
        threadID: String,
        target: CodexReviewAPI.Target,
        delivery: AppServerAPI.Review.Start.Delivery = .inline
    ) {
        self.threadID = threadID
        self.target = target
        self.delivery = delivery
    }
}
}


package extension AppServerAPI.Review.Start {
enum Delivery: String, Codable, Equatable, Sendable {
    case inline
    case detached
}
}


package extension AppServerAPI.Turn {
struct Payload: Codable, Equatable, Sendable {
    package var id: String
    package var status: String?
    package var error: AppServerAPI.Turn.Error?

    package init(id: String, status: String? = nil, error: AppServerAPI.Turn.Error? = nil) {
        self.id = id
        self.status = status
        self.error = error
    }
}
}


package extension AppServerAPI.Turn {
struct Error: Codable, Equatable, Sendable {
    package var message: String

    package init(message: String) {
        self.message = message
    }
}
}


package extension AppServerAPI.Review.Start {
struct Response: Codable, Equatable, Sendable {
    package var turnID: String
    package var reviewThreadID: String?

    enum CodingKeys: String, CodingKey {
        case turn
        case reviewThreadID = "reviewThreadId"
    }

    package init(turnID: String, reviewThreadID: String? = nil) {
        self.turnID = turnID
        self.reviewThreadID = reviewThreadID
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.turnID = try container.decode(AppServerAPI.Turn.Payload.self, forKey: .turn).id
        self.reviewThreadID = try container.decodeIfPresent(String.self, forKey: .reviewThreadID)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(AppServerAPI.Turn.Payload(id: turnID), forKey: .turn)
        try container.encodeIfPresent(reviewThreadID, forKey: .reviewThreadID)
    }
}
}


package extension AppServerAPI.Review.Start {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Review.Start.Response

    package static let method = "review/start"
    package var params: AppServerAPI.Review.Start.Params
    package var scope: AppServerAPI.RequestScope? {
        .thread(params.threadID)
    }

    package init(params: AppServerAPI.Review.Start.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Turn.Interrupt {
struct Params: Codable, Equatable, Sendable {
    package var threadID: String
    package var turnID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
    }

    package init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turnID = turnID
    }
}
}


package extension AppServerAPI.Turn.Interrupt {
struct Request: AppServerAPI.Request {
    package typealias Response = EmptyResponse

    package static let method = "turn/interrupt"
    package var params: AppServerAPI.Turn.Interrupt.Params

    package init(params: AppServerAPI.Turn.Interrupt.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Thread.Rollback {
struct Params: Codable, Equatable, Sendable {
    package var threadID: String
    package var numTurns: Int

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case numTurns
    }

    package init(threadID: String, numTurns: Int) {
        self.threadID = threadID
        self.numTurns = numTurns
    }
}
}


package extension AppServerAPI.Thread.Rollback {
struct Request: AppServerAPI.Request {
    package typealias Response = EmptyResponse

    package static let method = "thread/rollback"
    package var params: AppServerAPI.Thread.Rollback.Params
    package var scope: AppServerAPI.RequestScope? {
        .thread(params.threadID)
    }

    package init(params: AppServerAPI.Thread.Rollback.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Thread.Delete {
struct Params: Codable, Equatable, Sendable {
    package var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }

    package init(threadID: String) {
        self.threadID = threadID
    }
}
}


package extension AppServerAPI.Thread.Delete {
struct Request: AppServerAPI.Request {
    package typealias Response = EmptyResponse

    package static let method = "thread/delete"
    package var params: AppServerAPI.Thread.Delete.Params
    package var scope: AppServerAPI.RequestScope? {
        .thread(params.threadID)
    }

    package init(params: AppServerAPI.Thread.Delete.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Thread.Unsubscribe {
struct Params: Codable, Equatable, Sendable {
    package var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }

    package init(threadID: String) {
        self.threadID = threadID
    }
}
}


package extension AppServerAPI.Thread.Unsubscribe {
enum Status: String, Codable, Equatable, Sendable {
    case notLoaded
    case notSubscribed
    case unsubscribed
}
}


package extension AppServerAPI.Thread.Unsubscribe {
struct Response: Codable, Equatable, Sendable {
    package var status: AppServerAPI.Thread.Unsubscribe.Status

    package init(status: AppServerAPI.Thread.Unsubscribe.Status) {
        self.status = status
    }
}
}


package extension AppServerAPI.Thread.Unsubscribe {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Thread.Unsubscribe.Response

    package static let method = "thread/unsubscribe"
    package var params: AppServerAPI.Thread.Unsubscribe.Params
    package var scope: AppServerAPI.RequestScope? {
        .thread(params.threadID)
    }

    package init(params: AppServerAPI.Thread.Unsubscribe.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Thread.BackgroundTerminals.Clean {
struct Params: Codable, Equatable, Sendable {
    package var threadID: String

    enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }

    package init(threadID: String) {
        self.threadID = threadID
    }
}
}


package extension AppServerAPI.Thread.BackgroundTerminals.Clean {
struct Request: AppServerAPI.Request {
    package typealias Response = EmptyResponse

    package static let method = "thread/backgroundTerminals/clean"
    package var params: AppServerAPI.Thread.BackgroundTerminals.Clean.Params
    package var scope: AppServerAPI.RequestScope? {
        .thread(params.threadID)
    }

    package init(params: AppServerAPI.Thread.BackgroundTerminals.Clean.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Config.Read {
struct Response: Codable, Equatable, Sendable {
    package var config: AppServerAPI.Config.Snapshot

    package init(config: AppServerAPI.Config.Snapshot) {
        self.config = config
    }
}
}


package extension AppServerAPI.Config {
struct Snapshot: Codable, Equatable, Sendable {
    package var model: String?
    package var reviewModel: String?
    package var modelReasoningEffort: String?
    package var serviceTier: String?

    enum CodingKeys: String, CodingKey {
        case model
        case reviewModel = "review_model"
        case modelReasoningEffort = "model_reasoning_effort"
        case serviceTier = "service_tier"
    }

    package init(
        model: String? = nil,
        reviewModel: String? = nil,
        modelReasoningEffort: String? = nil,
        serviceTier: String? = nil
    ) {
        self.model = model
        self.reviewModel = reviewModel
        self.modelReasoningEffort = modelReasoningEffort
        self.serviceTier = serviceTier
    }
}
}


package extension AppServerAPI.Config.Read {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Config.Read.Response

    package static let method = "config/read"
    package var params: EmptyResponse

    package init() {
        self.params = .init()
    }
}
}


package extension AppServerAPI.Config {
enum Value: Encodable, Equatable, Sendable {
    case string(String)
    case null

    package func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        }
    }
}
}


package extension AppServerAPI.Config {
enum MergeStrategy: String, Codable, Equatable, Sendable {
    case replace
    case upsert
}
}


package extension AppServerAPI.Config {
struct Edit: Encodable, Equatable, Sendable {
    package var keyPath: String
    package var value: AppServerAPI.Config.Value
    package var mergeStrategy: AppServerAPI.Config.MergeStrategy

    package init(
        keyPath: String,
        value: AppServerAPI.Config.Value,
        mergeStrategy: AppServerAPI.Config.MergeStrategy = .replace
    ) {
        self.keyPath = keyPath
        self.value = value
        self.mergeStrategy = mergeStrategy
    }
}
}


package extension AppServerAPI.Config.BatchWrite {
struct Params: Encodable, Equatable, Sendable {
    package var edits: [AppServerAPI.Config.Edit]
    package var filePath: String?
    package var expectedVersion: String?
    package var reloadUserConfig: Bool

    package init(
        edits: [AppServerAPI.Config.Edit],
        filePath: String? = nil,
        expectedVersion: String? = nil,
        reloadUserConfig: Bool = true
    ) {
        self.edits = edits
        self.filePath = filePath
        self.expectedVersion = expectedVersion
        self.reloadUserConfig = reloadUserConfig
    }
}
}


package extension AppServerAPI.Config.BatchWrite {
struct Response: Decodable, Equatable, Sendable {
    package var status: String
    package var version: String?
    package var filePath: String?
}
}


package extension AppServerAPI.Config.BatchWrite {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Config.BatchWrite.Response

    package static let method = "config/batchWrite"
    package var params: AppServerAPI.Config.BatchWrite.Params

    package init(params: AppServerAPI.Config.BatchWrite.Params) {
        self.params = params
    }
}
}


package extension AppServerAPI.Model.List {
struct Params: Codable, Equatable, Sendable {
    package var cursor: String?
    package var limit: Int?
    package var includeHidden: Bool?

    package init(
        cursor: String? = nil,
        limit: Int? = nil,
        includeHidden: Bool? = nil
    ) {
        self.cursor = cursor
        self.limit = limit
        self.includeHidden = includeHidden
    }
}
}


package extension AppServerAPI.Model.List {
struct Response: Codable, Equatable, Sendable {
    package var data: [CodexReviewSettings.ModelCatalogItem]
    package var nextCursor: String?

    package init(
        data: [CodexReviewSettings.ModelCatalogItem],
        nextCursor: String? = nil
    ) {
        self.data = data
        self.nextCursor = nextCursor
    }
}
}


package extension AppServerAPI.Model.List {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Model.List.Response

    package static let method = "model/list"
    package var params: AppServerAPI.Model.List.Params

    package init(params: AppServerAPI.Model.List.Params = .init(includeHidden: true)) {
        self.params = params
    }
}
}


package extension AppServerAPI.Auth.Read {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Account.Read.Response

    package static let method = "account/read"
    package var params: AppServerAPI.Account.Read.Params

    package init() {
        self.params = .init(refreshToken: false)
    }
}
}


package extension AppServerAPI.Account.Read {
struct Params: Codable, Equatable, Sendable {
    package var refreshToken: Bool

    package init(refreshToken: Bool) {
        self.refreshToken = refreshToken
    }
}
}


package extension AppServerAPI.Account.Read {
struct Response: Codable, Equatable, Sendable {
    package var account: AppServerAPI.Account.Snapshot?
    package var requiresOpenAIAuth: Bool

    enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenAIAuth = "requiresOpenaiAuth"
    }

    package init(account: AppServerAPI.Account.Snapshot? = nil, requiresOpenAIAuth: Bool = false) {
        self.account = account
        self.requiresOpenAIAuth = requiresOpenAIAuth
    }
}
}


package extension AppServerAPI.Account.RateLimits.Read {
struct Request: AppServerAPI.Request {
    package typealias Response = AppServerAPI.Account.RateLimits.Response

    package static let method = "account/rateLimits/read"
    package var params: EmptyResponse

    package init() {
        self.params = .init()
    }
}
}


package extension AppServerAPI.Account.RateLimits {
struct Response: Codable, Equatable, Sendable {
    package var rateLimits: AppServerAPI.Account.RateLimits.Snapshot
    package var rateLimitsByLimitID: [String: AppServerAPI.Account.RateLimits.Snapshot]?

    enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
    }

    package init(
        rateLimits: AppServerAPI.Account.RateLimits.Snapshot,
        rateLimitsByLimitID: [String: AppServerAPI.Account.RateLimits.Snapshot]? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitID = rateLimitsByLimitID
    }
}
}


package extension AppServerAPI.Account.RateLimits {
struct Snapshot: Codable, Equatable, Sendable {
    package var limitID: String?
    package var primary: AppServerAPI.Account.RateLimits.Window?
    package var secondary: AppServerAPI.Account.RateLimits.Window?
    package var planType: String?

    enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case primary
        case secondary
        case planType
    }

    package init(
        limitID: String? = nil,
        primary: AppServerAPI.Account.RateLimits.Window? = nil,
        secondary: AppServerAPI.Account.RateLimits.Window? = nil,
        planType: String? = nil
    ) {
        self.limitID = limitID
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}
}


package extension AppServerAPI.Account.RateLimits {
struct Window: Codable, Equatable, Sendable {
    package var usedPercent: Int
    package var windowDurationMins: Int?
    package var resetsAt: Int64?

    package init(
        usedPercent: Int,
        windowDurationMins: Int? = nil,
        resetsAt: Int64? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }
}
}


package extension AppServerAPI.Account.RateLimits.Response {
    var codexRateLimitWindows: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] {
        Self.rateLimitWindows(from: codexSnapshot)
    }

    var codexPlanType: String? {
        codexSnapshot?.planType
    }

    private var codexSnapshot: AppServerAPI.Account.RateLimits.Snapshot? {
        if let codexSnapshot = rateLimitsByLimitID?["codex"] {
            return codexSnapshot
        }
        if let codexSnapshot = rateLimitsByLimitID?.first(where: { limitID, snapshot in
            Self.isCodexRateLimit(limitID) || Self.isCodexRateLimit(snapshot.limitID)
        })?.value {
            return codexSnapshot
        }
        if Self.isCodexRateLimit(rateLimits.limitID) {
            return rateLimits
        }
        return nil
    }

    private static func rateLimitWindows(
        from snapshot: AppServerAPI.Account.RateLimits.Snapshot?
    ) -> [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] {
        [snapshot?.primary, snapshot?.secondary].compactMap { window in
            guard let window,
                  let duration = window.windowDurationMins
            else {
                return nil
            }
            return (
                windowDurationMinutes: duration,
                usedPercent: window.usedPercent,
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    static func isCodexRateLimit(_ limitID: String?) -> Bool {
        let normalizedLimitID = limitID?.nilIfEmpty ?? "codex"
        return normalizedLimitID == "codex" || normalizedLimitID.hasPrefix("codex_")
    }
}


package extension AppServerAPI.Account {
struct Snapshot: Codable, Equatable, Sendable {
    package var id: CodexReviewBackendModel.Account.ID
    package var kind: CodexReviewBackendModel.Account.Kind
    package var label: String
    package var planType: String?
    package var capabilities: CodexReviewBackendModel.Account.Capabilities

    package init(email: String, planType: String) {
        self.init(
            kind: .chatGPT,
            id: .init(CodexAccount.normalizedEmail(email)),
            label: email,
            planType: planType,
            capabilities: .supportsCodexRateLimits
        )
    }

    fileprivate init(
        kind: CodexReviewBackendModel.Account.Kind,
        id: CodexReviewBackendModel.Account.ID,
        label: String,
        planType: String?,
        capabilities: CodexReviewBackendModel.Account.Capabilities
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.planType = planType
        self.capabilities = capabilities
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AppServerAccountCodingKeys.self)
        let kind = try container.decode(CodexReviewBackendModel.Account.Kind.self, forKey: .type)
        let descriptor = AppServerAccountKindDescriptor.descriptor(for: kind)
        self = try descriptor.decode(container)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AppServerAccountCodingKeys.self)
        try container.encode(kind, forKey: .type)
        let descriptor = AppServerAccountKindDescriptor.descriptor(for: kind)
        try descriptor.encodeFields(self, &container)
    }
}
}


private enum AppServerAccountCodingKeys: String, CodingKey {
    case type
    case email
    case planType
}

private struct AppServerAccountKindDescriptor {
    var decode: (KeyedDecodingContainer<AppServerAccountCodingKeys>) throws -> AppServerAPI.Account.Snapshot
    var encodeFields: (AppServerAPI.Account.Snapshot, inout KeyedEncodingContainer<AppServerAccountCodingKeys>) throws -> Void

    static func descriptor(for kind: CodexReviewBackendModel.Account.Kind) -> Self {
        switch kind {
        case .apiKey:
            fixed(
                kind: .apiKey,
                id: "api-key",
                label: "API Key",
                capabilities: .noCodexRateLimits
            )
        case .chatGPT:
            .init(
                decode: { container in
                    let email = try container.decode(String.self, forKey: .email)
                    let normalizedEmail = CodexAccount.normalizedEmail(email)
                    guard normalizedEmail.isEmpty == false else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .email,
                            in: container,
                            debugDescription: "ChatGPT account email must not be empty."
                        )
                    }
                    return AppServerAPI.Account.Snapshot(
                        kind: .chatGPT,
                        id: .init(normalizedEmail),
                        label: email,
                        planType: try container.decode(String.self, forKey: .planType),
                        capabilities: .supportsCodexRateLimits
                    )
                },
                encodeFields: { account, container in
                    guard let planType = account.planType else {
                        throw EncodingError.invalidValue(
                            account,
                            .init(
                                codingPath: container.codingPath + [AppServerAccountCodingKeys.planType],
                                debugDescription: "ChatGPT account planType must not be nil."
                            )
                        )
                    }
                    try container.encode(account.label, forKey: .email)
                    try container.encode(planType, forKey: .planType)
                }
            )
        case .amazonBedrock:
            fixed(
                kind: .amazonBedrock,
                id: "amazon-bedrock",
                label: "Amazon Bedrock",
                capabilities: .noCodexRateLimits
            )
        }
    }

    private static func fixed(
        kind: CodexReviewBackendModel.Account.Kind,
        id: String,
        label: String,
        capabilities: CodexReviewBackendModel.Account.Capabilities
    ) -> Self {
        .init(
            decode: { _ in
                AppServerAPI.Account.Snapshot(
                    kind: kind,
                    id: .init(id),
                    label: label,
                    planType: nil,
                    capabilities: capabilities
                )
            },
            encodeFields: { _, _ in }
        )
    }
}

package extension AppServerAPI.Account.Login {
struct Params: Codable, Equatable, Sendable {
    package var type: String
    package var codexStreamlinedLogin: Bool
    package var nativeWebAuthentication: AppServerAPI.Account.Login.NativeWebAuthentication?

    package init(
        type: String = "chatgpt",
        codexStreamlinedLogin: Bool = true,
        nativeWebAuthentication: AppServerAPI.Account.Login.NativeWebAuthentication? = nil
    ) {
        self.type = type
        self.codexStreamlinedLogin = codexStreamlinedLogin
        self.nativeWebAuthentication = nativeWebAuthentication
    }
}
}


package extension AppServerAPI.Account.Login {
struct NativeWebAuthentication: Codable, Equatable, Sendable {
    package var callbackURLScheme: String

    enum CodingKeys: String, CodingKey {
        case callbackURLScheme = "callbackUrlScheme"
    }

    package init(callbackURLScheme: String) {
        self.callbackURLScheme = callbackURLScheme
    }
}
}


package extension AppServerAPI.Account.Login {
enum Response: Codable, Equatable, Sendable {
    case apiKey
    case chatgpt(
        loginID: String,
        authURL: String,
        nativeWebAuthentication: AppServerAPI.Account.Login.NativeWebAuthentication?
    )
    case chatgptDeviceCode(loginID: String, verificationURL: String, userCode: String)
    case chatgptAuthTokens

    private enum CodingKeys: String, CodingKey {
        case type
        case loginID = "loginId"
        case authURL = "authUrl"
        case nativeWebAuthentication
        case verificationURL = "verificationUrl"
        case userCode
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "apiKey":
            self = .apiKey
        case "chatgpt":
            self = .chatgpt(
                loginID: try container.decode(String.self, forKey: .loginID),
                authURL: try container.decode(String.self, forKey: .authURL),
                nativeWebAuthentication: try container.decodeIfPresent(
                    AppServerAPI.Account.Login.NativeWebAuthentication.self,
                    forKey: .nativeWebAuthentication
                )
            )
        case "chatgptDeviceCode":
            self = .chatgptDeviceCode(
                loginID: try container.decode(String.self, forKey: .loginID),
                verificationURL: try container.decode(String.self, forKey: .verificationURL),
                userCode: try container.decode(String.self, forKey: .userCode)
            )
        case "chatgptAuthTokens":
            self = .chatgptAuthTokens
        case let type:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported login response type: \(type)"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .apiKey:
            try container.encode("apiKey", forKey: .type)
        case .chatgpt(let loginID, let authURL, let nativeWebAuthentication):
            try container.encode("chatgpt", forKey: .type)
            try container.encode(loginID, forKey: .loginID)
            try container.encode(authURL, forKey: .authURL)
            try container.encodeIfPresent(nativeWebAuthentication, forKey: .nativeWebAuthentication)
        case .chatgptDeviceCode(let loginID, let verificationURL, let userCode):
            try container.encode("chatgptDeviceCode", forKey: .type)
            try container.encode(loginID, forKey: .loginID)
            try container.encode(verificationURL, forKey: .verificationURL)
            try container.encode(userCode, forKey: .userCode)
        case .chatgptAuthTokens:
            try container.encode("chatgptAuthTokens", forKey: .type)
        }
    }
}
}


package extension AppServerAPI.Account.Login.Complete {
struct Params: Codable, Equatable, Sendable {
    package var loginID: String
    package var callbackURL: String

    enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case callbackURL = "callbackUrl"
    }

    package init(loginID: String, callbackURL: String) {
        self.loginID = loginID
        self.callbackURL = callbackURL
    }
}
}


package extension AppServerAPI.Account.Login.Complete {
struct Response: Codable, Equatable, Sendable {
    package init() {}
}
}


package extension AppServerAPI.Account.Login.Cancel {
struct Params: Codable, Equatable, Sendable {
    package var loginID: String

    enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
    }

    package init(loginID: String) {
        self.loginID = loginID
    }
}
}


package extension AppServerAPI.Account.Login.Cancel {
struct Response: Codable, Equatable, Sendable {
    package var status: String

    package init(status: String = "canceled") {
        self.status = status
    }
}
}
