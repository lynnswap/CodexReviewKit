import Foundation
import CodexReview

package enum AppServerRequestScope: Hashable, Sendable {
    case thread(String)
}

package protocol AppServerRequest: Sendable {
    associatedtype Params: Encodable & Sendable
    associatedtype Response: Decodable & Sendable

    static var method: String { get }
    var params: Params { get }
    var scope: AppServerRequestScope? { get }
}

extension AppServerRequest {
    package var scope: AppServerRequestScope? { nil }
}

package struct InitializeClientInfo: Codable, Equatable, Sendable {
    package var name: String
    package var title: String?
    package var version: String

    package init(name: String, title: String? = nil, version: String) {
        self.name = name
        self.title = title
        self.version = version
    }
}

package struct InitializeCapabilities: Codable, Equatable, Sendable {
    package var experimentalAPI: Bool

    package enum CodingKeys: String, CodingKey {
        case experimentalAPI = "experimentalApi"
    }

    package init(experimentalAPI: Bool = true) {
        self.experimentalAPI = experimentalAPI
    }
}

package struct InitializeParams: Codable, Equatable, Sendable {
    package var clientInfo: InitializeClientInfo
    package var capabilities: InitializeCapabilities

    package enum CodingKeys: String, CodingKey {
        case clientInfo
        case capabilities
    }

    package init(clientName: String, clientVersion: String) {
        self.clientInfo = .init(name: clientName, version: clientVersion)
        self.capabilities = .init()
    }
}

package struct InitializeResponse: Codable, Equatable, Sendable {
    package var codexHome: String?
    package var userAgent: String?

    package init(codexHome: String? = nil, userAgent: String? = nil) {
        self.codexHome = codexHome
        self.userAgent = userAgent
    }
}

package struct InitializeRequest: AppServerRequest {
    package typealias Response = InitializeResponse

    package static let method = "initialize"
    package var params: InitializeParams

    package init(params: InitializeParams) {
        self.params = params
    }
}

package struct ThreadStartParams: Codable, Equatable, Sendable {
    package var cwd: String
    package var model: String?
    package var ephemeral: Bool?
    package var approvalPolicy: String?
    package var sandbox: String?

    package init(
        cwd: String,
        model: String? = nil,
        ephemeral: Bool? = nil,
        approvalPolicy: String? = nil,
        sandbox: String? = nil
    ) {
        self.cwd = cwd
        self.model = model
        self.ephemeral = ephemeral
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
    }
}

package struct ThreadStartResponse: Codable, Equatable, Sendable {
    package var threadID: String
    package var model: String?

    package enum CodingKeys: String, CodingKey {
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

package struct ThreadStartRequest: AppServerRequest {
    package typealias Response = ThreadStartResponse

    package static let method = "thread/start"
    package var params: ThreadStartParams

    package init(params: ThreadStartParams) {
        self.params = params
    }
}

package struct ReviewStartParams: Codable, Equatable, Sendable {
    package var threadID: String
    package var target: ReviewTarget
    package var delivery: ReviewDelivery

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case target
        case delivery
    }

    package init(
        threadID: String,
        target: ReviewTarget,
        delivery: ReviewDelivery = .inline
    ) {
        self.threadID = threadID
        self.target = target
        self.delivery = delivery
    }
}

package enum ReviewDelivery: String, Codable, Equatable, Sendable {
    case inline
    case detached
}

package struct AppServerTurn: Codable, Equatable, Sendable {
    package var id: String
    package var status: String?
    package var error: AppServerTurnError?

    package init(id: String, status: String? = nil, error: AppServerTurnError? = nil) {
        self.id = id
        self.status = status
        self.error = error
    }
}

package struct AppServerTurnError: Codable, Equatable, Sendable {
    package var message: String

    package init(message: String) {
        self.message = message
    }
}

package struct ReviewStartResponse: Codable, Equatable, Sendable {
    package var turnID: String
    package var reviewThreadID: String?

    package enum CodingKeys: String, CodingKey {
        case turn
        case reviewThreadID = "reviewThreadId"
    }

    package init(turnID: String, reviewThreadID: String? = nil) {
        self.turnID = turnID
        self.reviewThreadID = reviewThreadID
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.turnID = try container.decode(AppServerTurn.self, forKey: .turn).id
        self.reviewThreadID = try container.decodeIfPresent(String.self, forKey: .reviewThreadID)
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(AppServerTurn(id: turnID), forKey: .turn)
        try container.encodeIfPresent(reviewThreadID, forKey: .reviewThreadID)
    }
}

package struct ReviewStartRequest: AppServerRequest {
    package typealias Response = ReviewStartResponse

    package static let method = "review/start"
    package var params: ReviewStartParams
    package var scope: AppServerRequestScope? {
        .thread(params.threadID)
    }

    package init(params: ReviewStartParams) {
        self.params = params
    }
}

package struct TurnInterruptParams: Codable, Equatable, Sendable {
    package var threadID: String
    package var turnID: String

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
        case turnID = "turnId"
    }

    package init(threadID: String, turnID: String) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

package struct TurnInterruptRequest: AppServerRequest {
    package typealias Response = EmptyResponse

    package static let method = "turn/interrupt"
    package var params: TurnInterruptParams

    package init(params: TurnInterruptParams) {
        self.params = params
    }
}

package struct ThreadUnsubscribeParams: Codable, Equatable, Sendable {
    package var threadID: String

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }

    package init(threadID: String) {
        self.threadID = threadID
    }
}

package struct ThreadUnsubscribeRequest: AppServerRequest {
    package typealias Response = EmptyResponse

    package static let method = "thread/unsubscribe"
    package var params: ThreadUnsubscribeParams
    package var scope: AppServerRequestScope? {
        .thread(params.threadID)
    }

    package init(params: ThreadUnsubscribeParams) {
        self.params = params
    }
}

package struct BackgroundTerminalsCleanParams: Codable, Equatable, Sendable {
    package var threadID: String

    package enum CodingKeys: String, CodingKey {
        case threadID = "threadId"
    }

    package init(threadID: String) {
        self.threadID = threadID
    }
}

package struct BackgroundTerminalsCleanRequest: AppServerRequest {
    package typealias Response = EmptyResponse

    package static let method = "thread/backgroundTerminals/clean"
    package var params: BackgroundTerminalsCleanParams
    package var scope: AppServerRequestScope? {
        .thread(params.threadID)
    }

    package init(params: BackgroundTerminalsCleanParams) {
        self.params = params
    }
}

package struct ConfigReadResponse: Codable, Equatable, Sendable {
    package var config: AppServerConfig

    package init(config: AppServerConfig) {
        self.config = config
    }
}

package struct AppServerConfig: Codable, Equatable, Sendable {
    package var model: String?
    package var reviewModel: String?
    package var modelReasoningEffort: String?
    package var serviceTier: String?

    package enum CodingKeys: String, CodingKey {
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

package struct ConfigReadRequest: AppServerRequest {
    package typealias Response = ConfigReadResponse

    package static let method = "config/read"
    package var params: EmptyResponse

    package init() {
        self.params = .init()
    }
}

package enum AppServerJSONValue: Encodable, Equatable, Sendable {
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

package enum AppServerConfigMergeStrategy: String, Codable, Equatable, Sendable {
    case replace
    case upsert
}

package struct AppServerConfigEdit: Encodable, Equatable, Sendable {
    package var keyPath: String
    package var value: AppServerJSONValue
    package var mergeStrategy: AppServerConfigMergeStrategy

    package init(
        keyPath: String,
        value: AppServerJSONValue,
        mergeStrategy: AppServerConfigMergeStrategy = .replace
    ) {
        self.keyPath = keyPath
        self.value = value
        self.mergeStrategy = mergeStrategy
    }
}

package struct ConfigBatchWriteParams: Encodable, Equatable, Sendable {
    package var edits: [AppServerConfigEdit]
    package var filePath: String?
    package var expectedVersion: String?
    package var reloadUserConfig: Bool

    package init(
        edits: [AppServerConfigEdit],
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

package struct ConfigWriteResponse: Decodable, Equatable, Sendable {
    package var status: String
    package var version: String?
    package var filePath: String?
}

package struct ConfigBatchWriteRequest: AppServerRequest {
    package typealias Response = ConfigWriteResponse

    package static let method = "config/batchWrite"
    package var params: ConfigBatchWriteParams

    package init(params: ConfigBatchWriteParams) {
        self.params = params
    }
}

package struct ModelListParams: Codable, Equatable, Sendable {
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

package struct ModelListResponse: Codable, Equatable, Sendable {
    package var data: [CodexReviewModelCatalogItem]
    package var nextCursor: String?

    package init(
        data: [CodexReviewModelCatalogItem],
        nextCursor: String? = nil
    ) {
        self.data = data
        self.nextCursor = nextCursor
    }
}

package struct ModelListRequest: AppServerRequest {
    package typealias Response = ModelListResponse

    package static let method = "model/list"
    package var params: ModelListParams

    package init(params: ModelListParams = .init(includeHidden: true)) {
        self.params = params
    }
}

package struct AuthReadRequest: AppServerRequest {
    package typealias Response = AccountReadResponse

    package static let method = "account/read"
    package var params: AccountReadParams

    package init() {
        self.params = .init(refreshToken: false)
    }
}

package struct AccountReadParams: Codable, Equatable, Sendable {
    package var refreshToken: Bool

    package init(refreshToken: Bool) {
        self.refreshToken = refreshToken
    }
}

package struct AccountReadResponse: Codable, Equatable, Sendable {
    package var account: AppServerAccount?
    package var requiresOpenAIAuth: Bool

    package enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenAIAuth = "requiresOpenaiAuth"
    }

    package init(account: AppServerAccount? = nil, requiresOpenAIAuth: Bool = false) {
        self.account = account
        self.requiresOpenAIAuth = requiresOpenAIAuth
    }
}

package struct AccountRateLimitsReadRequest: AppServerRequest {
    package typealias Response = AppServerAccountRateLimitsResponse

    package static let method = "account/rateLimits/read"
    package var params: EmptyResponse

    package init() {
        self.params = .init()
    }
}

package struct AppServerAccountRateLimitsResponse: Codable, Equatable, Sendable {
    package var rateLimits: AppServerRateLimitSnapshotPayload
    package var rateLimitsByLimitID: [String: AppServerRateLimitSnapshotPayload]?

    package enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
    }

    package init(
        rateLimits: AppServerRateLimitSnapshotPayload,
        rateLimitsByLimitID: [String: AppServerRateLimitSnapshotPayload]? = nil
    ) {
        self.rateLimits = rateLimits
        self.rateLimitsByLimitID = rateLimitsByLimitID
    }
}

package struct AppServerRateLimitSnapshotPayload: Codable, Equatable, Sendable {
    package var limitID: String?
    package var primary: AppServerRateLimitWindowPayload?
    package var secondary: AppServerRateLimitWindowPayload?
    package var planType: String?

    package enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case primary
        case secondary
        case planType
    }

    package init(
        limitID: String? = nil,
        primary: AppServerRateLimitWindowPayload? = nil,
        secondary: AppServerRateLimitWindowPayload? = nil,
        planType: String? = nil
    ) {
        self.limitID = limitID
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}

package struct AppServerRateLimitWindowPayload: Codable, Equatable, Sendable {
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

package extension AppServerAccountRateLimitsResponse {
    var codexRateLimitWindows: [(windowDurationMinutes: Int, usedPercent: Int, resetsAt: Date?)] {
        Self.rateLimitWindows(from: codexSnapshot)
    }

    var codexPlanType: String? {
        codexSnapshot?.planType
    }

    private var codexSnapshot: AppServerRateLimitSnapshotPayload? {
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
        from snapshot: AppServerRateLimitSnapshotPayload?
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

package struct AppServerAccount: Codable, Equatable, Sendable {
    package var id: BackendAccountID
    package var kind: BackendAccountKind
    package var label: String
    package var planType: String?
    package var capabilities: BackendAccountCapabilities

    package init(email: String, planType: String) {
        self.init(
            kind: .chatGPT,
            id: .init(normalizedReviewAccountEmail(email: email)),
            label: email,
            planType: planType,
            capabilities: .supportsCodexRateLimits
        )
    }

    fileprivate init(
        kind: BackendAccountKind,
        id: BackendAccountID,
        label: String,
        planType: String?,
        capabilities: BackendAccountCapabilities
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.planType = planType
        self.capabilities = capabilities
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AppServerAccountCodingKeys.self)
        let kind = try container.decode(BackendAccountKind.self, forKey: .type)
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

private enum AppServerAccountCodingKeys: String, CodingKey {
    case type
    case email
    case planType
}

private struct AppServerAccountKindDescriptor {
    var decode: (KeyedDecodingContainer<AppServerAccountCodingKeys>) throws -> AppServerAccount
    var encodeFields: (AppServerAccount, inout KeyedEncodingContainer<AppServerAccountCodingKeys>) throws -> Void

    static func descriptor(for kind: BackendAccountKind) -> Self {
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
                    let normalizedEmail = normalizedReviewAccountEmail(email: email)
                    guard normalizedEmail.isEmpty == false else {
                        throw DecodingError.dataCorruptedError(
                            forKey: .email,
                            in: container,
                            debugDescription: "ChatGPT account email must not be empty."
                        )
                    }
                    return AppServerAccount(
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
        kind: BackendAccountKind,
        id: String,
        label: String,
        capabilities: BackendAccountCapabilities
    ) -> Self {
        .init(
            decode: { _ in
                AppServerAccount(
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

package struct LoginAccountParams: Codable, Equatable, Sendable {
    package var type: String
    package var codexStreamlinedLogin: Bool
    package var nativeWebAuthentication: AppServerNativeWebAuthenticationRequest?

    package init(
        type: String = "chatgpt",
        codexStreamlinedLogin: Bool = true,
        nativeWebAuthentication: AppServerNativeWebAuthenticationRequest? = nil
    ) {
        self.type = type
        self.codexStreamlinedLogin = codexStreamlinedLogin
        self.nativeWebAuthentication = nativeWebAuthentication
    }
}

package struct AppServerNativeWebAuthenticationRequest: Codable, Equatable, Sendable {
    package var callbackURLScheme: String

    package enum CodingKeys: String, CodingKey {
        case callbackURLScheme = "callbackUrlScheme"
    }

    package init(callbackURLScheme: String) {
        self.callbackURLScheme = callbackURLScheme
    }
}

package enum LoginAccountResponse: Codable, Equatable, Sendable {
    case apiKey
    case chatgpt(
        loginID: String,
        authURL: String,
        nativeWebAuthentication: AppServerNativeWebAuthenticationRequest?
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
                    AppServerNativeWebAuthenticationRequest.self,
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

package struct CompleteLoginAccountParams: Codable, Equatable, Sendable {
    package var loginID: String
    package var callbackURL: String

    package enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case callbackURL = "callbackUrl"
    }

    package init(loginID: String, callbackURL: String) {
        self.loginID = loginID
        self.callbackURL = callbackURL
    }
}

package struct CompleteLoginAccountResponse: Codable, Equatable, Sendable {
    package init() {}
}

package struct CancelLoginAccountParams: Codable, Equatable, Sendable {
    package var loginID: String

    package enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
    }

    package init(loginID: String) {
        self.loginID = loginID
    }
}

package struct CancelLoginAccountResponse: Codable, Equatable, Sendable {
    package var status: String

    package init(status: String = "canceled") {
        self.status = status
    }
}
