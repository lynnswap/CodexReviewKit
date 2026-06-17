import Foundation

package enum CodexReviewBackendModel {
    package enum Settings {}
    package enum Account {}
    package enum Auth {}
    package enum Login {}
    package enum Review {}
}

package extension CodexReviewBackendModel.Settings {
struct Snapshot: Codable, Equatable, Sendable {
    package var model: String?
    package var fallbackModel: String?
    package var reasoningEffort: String?
    package var serviceTier: String?
    package var models: [CodexReviewSettings.ModelCatalogItem]

    package init(
        model: String? = nil,
        fallbackModel: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        models: [CodexReviewSettings.ModelCatalogItem] = []
    ) {
        self.model = model
        self.fallbackModel = fallbackModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.models = models
    }
}
}


package extension CodexReviewBackendModel.Settings {
struct Change: Codable, Equatable, Sendable {
    package var model: String?
    package var reasoningEffort: String?
    package var serviceTier: String?
    package var updatesModel: Bool
    package var updatesReasoningEffort: Bool
    package var updatesServiceTier: Bool

    package init(
        model: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        updatesModel: Bool? = nil,
        updatesReasoningEffort: Bool? = nil,
        updatesServiceTier: Bool? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.updatesModel = updatesModel ?? (model != nil)
        self.updatesReasoningEffort = updatesReasoningEffort ?? (reasoningEffort != nil)
        self.updatesServiceTier = updatesServiceTier ?? (serviceTier != nil)
    }
}
}


package extension CodexReviewBackendModel.Account {
struct ID: Codable, Hashable, Sendable {
    package var rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}
}


package extension CodexReviewBackendModel.Account {
enum Kind: String, Codable, Equatable, Sendable {
    case chatGPT = "chatgpt"
    case apiKey
    case amazonBedrock
}
}


package extension CodexReviewBackendModel.Account {
struct Capabilities: Codable, Equatable, Sendable {
    package var supportsRateLimitRefresh: Bool

    package init(supportsRateLimitRefresh: Bool = true) {
        self.supportsRateLimitRefresh = supportsRateLimitRefresh
    }

    package static var supportsCodexRateLimits: Self {
        .init(supportsRateLimitRefresh: true)
    }

    package static var noCodexRateLimits: Self {
        .init(supportsRateLimitRefresh: false)
    }
}
}


package extension CodexReviewBackendModel.Account.Kind {
    var capabilities: CodexReviewBackendModel.Account.Capabilities {
        switch self {
        case .chatGPT:
            .supportsCodexRateLimits
        case .apiKey, .amazonBedrock:
            .noCodexRateLimits
        }
    }
}


package extension CodexReviewBackendModel.Account {
struct Snapshot: Codable, Equatable, Sendable, Identifiable {
    package var id: CodexReviewBackendModel.Account.ID
    package var kind: CodexReviewBackendModel.Account.Kind
    package var label: String
    package var isActive: Bool
    package var planType: String?
    package var capabilities: CodexReviewBackendModel.Account.Capabilities

    package init(
        id: CodexReviewBackendModel.Account.ID,
        kind: CodexReviewBackendModel.Account.Kind = .chatGPT,
        label: String,
        isActive: Bool = false,
        planType: String? = nil,
        capabilities: CodexReviewBackendModel.Account.Capabilities? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.isActive = isActive
        self.planType = planType
        self.capabilities = capabilities ?? kind.capabilities
    }
}
}


package extension CodexReviewBackendModel.Auth {
struct Snapshot: Codable, Equatable, Sendable {
    package var accounts: [CodexReviewBackendModel.Account.Snapshot]
    package var activeAccountID: CodexReviewBackendModel.Account.ID?

    package init(
        accounts: [CodexReviewBackendModel.Account.Snapshot] = [],
        activeAccountID: CodexReviewBackendModel.Account.ID? = nil
    ) {
        self.accounts = accounts
        self.activeAccountID = activeAccountID
    }
}
}


package extension CodexReviewBackendModel.Auth {
enum Phase: Codable, Equatable, Sendable {
    case unknown
    case signedOut
    case authenticated
    case authenticating(challengeID: String)
    case failed(message: String)
}
}


package extension CodexReviewBackendModel.Login {
struct Request: Codable, Equatable, Sendable {
    package var preferredAccountID: CodexReviewBackendModel.Account.ID?
    package var nativeWebAuthenticationCallbackScheme: String?

    package init(
        preferredAccountID: CodexReviewBackendModel.Account.ID? = nil,
        nativeWebAuthenticationCallbackScheme: String? = nil
    ) {
        self.preferredAccountID = preferredAccountID
        self.nativeWebAuthenticationCallbackScheme = nativeWebAuthenticationCallbackScheme
    }
}
}


package extension CodexReviewBackendModel.Login {
struct Challenge: Codable, Equatable, Sendable {
    package var id: String
    package var verificationURL: URL?
    package var userCode: String?
    package var nativeWebAuthenticationCallbackScheme: String?

    package init(
        id: String,
        verificationURL: URL? = nil,
        userCode: String? = nil,
        nativeWebAuthenticationCallbackScheme: String? = nil
    ) {
        self.id = id
        self.verificationURL = verificationURL
        self.userCode = userCode
        self.nativeWebAuthenticationCallbackScheme = nativeWebAuthenticationCallbackScheme
    }
}
}


package extension CodexReviewBackendModel.Login {
struct Response: Codable, Equatable, Sendable {
    package var challengeID: String
    package var callbackURL: String?

    package init(challengeID: String, callbackURL: String? = nil) {
        self.challengeID = challengeID
        self.callbackURL = callbackURL
    }
}
}


package extension CodexReviewBackendModel.Review {
struct Start: Equatable, Sendable {
    package var jobID: String
    package var sessionID: String
    package var request: CodexReviewAPI.Start.Request
    package var model: String?

    package init(jobID: String, sessionID: String, request: CodexReviewAPI.Start.Request) {
        self.init(jobID: jobID, sessionID: sessionID, request: request, model: nil)
    }

    package init(
        jobID: String,
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        model: String?
    ) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.request = request
        self.model = model
    }
}
}


package extension CodexReviewBackendModel.Review {
struct Run: Codable, Equatable, Sendable {
    package var attemptID: String
    package var threadID: String
    package var turnID: String?
    package var reviewThreadID: String?
    package var model: String?

    enum CodingKeys: String, CodingKey {
        case attemptID
        case threadID
        case turnID
        case reviewThreadID
        case model
    }

    package init(
        attemptID: String = "attempt-1",
        threadID: String,
        turnID: String? = nil,
        reviewThreadID: String? = nil,
        model: String? = nil
    ) {
        self.attemptID = attemptID
        self.threadID = threadID
        self.turnID = turnID
        self.reviewThreadID = reviewThreadID
        self.model = model
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.attemptID = try container.decodeIfPresent(String.self, forKey: .attemptID) ?? "attempt-1"
        self.threadID = try container.decode(String.self, forKey: .threadID)
        self.turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        self.reviewThreadID = try container.decodeIfPresent(String.self, forKey: .reviewThreadID)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
    }
}
}


package extension CodexReviewBackendModel.Review {
struct RecoveryToken: Equatable, Sendable {
    package var interruptedRun: CodexReviewBackendModel.Review.Run
    package var rollbackThreadID: String

    package init(
        interruptedRun: CodexReviewBackendModel.Review.Run,
        rollbackThreadID: String
    ) {
        self.interruptedRun = interruptedRun
        self.rollbackThreadID = rollbackThreadID
    }
}
}


package extension CodexReviewBackendModel.Review {
enum Event: Equatable, Sendable {
    case started(turnID: String, reviewThreadID: String?, model: String?)
    case message(String)
    case messageDelta(String, itemID: String)
    case log(String)
    case logEntry(
        kind: ReviewLogEntry.Kind,
        text: String,
        groupID: String?,
        replacesGroup: Bool,
        metadata: ReviewLogEntry.Metadata? = nil
    )
    case completed(summary: String, result: String?)
    case failed(String)
    case cancelled(String)
}
}


package extension CodexReviewBackendModel {
struct CancellationReason: Codable, Equatable, Sendable {
    package var message: String

    package init(message: String = "Cancellation requested.") {
        self.message = message
    }
}
}
