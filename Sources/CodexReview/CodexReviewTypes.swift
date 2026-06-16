import Foundation

package struct BackendSettingsSnapshot: Codable, Equatable, Sendable {
    package var model: String?
    package var fallbackModel: String?
    package var reasoningEffort: String?
    package var serviceTier: String?
    package var models: [CodexReviewModelCatalogItem]

    package init(
        model: String? = nil,
        fallbackModel: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        models: [CodexReviewModelCatalogItem] = []
    ) {
        self.model = model
        self.fallbackModel = fallbackModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.models = models
    }
}

package struct BackendSettingsChange: Codable, Equatable, Sendable {
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

package struct BackendAccountID: Codable, Hashable, Sendable {
    package var rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

package enum BackendAccountKind: String, Codable, Equatable, Sendable {
    case chatGPT = "chatgpt"
    case apiKey
    case amazonBedrock
}

package struct BackendAccountCapabilities: Codable, Equatable, Sendable {
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

package extension BackendAccountKind {
    var capabilities: BackendAccountCapabilities {
        switch self {
        case .chatGPT:
            .supportsCodexRateLimits
        case .apiKey, .amazonBedrock:
            .noCodexRateLimits
        }
    }
}

package struct BackendAccountSnapshot: Codable, Equatable, Sendable, Identifiable {
    package var id: BackendAccountID
    package var kind: BackendAccountKind
    package var label: String
    package var isActive: Bool
    package var planType: String?
    package var capabilities: BackendAccountCapabilities

    package init(
        id: BackendAccountID,
        kind: BackendAccountKind = .chatGPT,
        label: String,
        isActive: Bool = false,
        planType: String? = nil,
        capabilities: BackendAccountCapabilities? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.isActive = isActive
        self.planType = planType
        self.capabilities = capabilities ?? kind.capabilities
    }
}

package struct BackendAuthSnapshot: Codable, Equatable, Sendable {
    package var accounts: [BackendAccountSnapshot]
    package var activeAccountID: BackendAccountID?

    package init(
        accounts: [BackendAccountSnapshot] = [],
        activeAccountID: BackendAccountID? = nil
    ) {
        self.accounts = accounts
        self.activeAccountID = activeAccountID
    }
}

package enum BackendAuthPhase: Codable, Equatable, Sendable {
    case unknown
    case signedOut
    case authenticated
    case authenticating(challengeID: String)
    case failed(message: String)
}

package struct BackendLoginRequest: Codable, Equatable, Sendable {
    package var preferredAccountID: BackendAccountID?
    package var nativeWebAuthenticationCallbackScheme: String?

    package init(
        preferredAccountID: BackendAccountID? = nil,
        nativeWebAuthenticationCallbackScheme: String? = nil
    ) {
        self.preferredAccountID = preferredAccountID
        self.nativeWebAuthenticationCallbackScheme = nativeWebAuthenticationCallbackScheme
    }
}

package struct BackendLoginChallenge: Codable, Equatable, Sendable {
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

package struct BackendLoginResponse: Codable, Equatable, Sendable {
    package var challengeID: String
    package var callbackURL: String?

    package init(challengeID: String, callbackURL: String? = nil) {
        self.challengeID = challengeID
        self.callbackURL = callbackURL
    }
}

package struct BackendReviewStart: Equatable, Sendable {
    package var jobID: String
    package var sessionID: String
    package var request: ReviewStartRequest
    package var model: String?

    package init(jobID: String, sessionID: String, request: ReviewStartRequest) {
        self.init(jobID: jobID, sessionID: sessionID, request: request, model: nil)
    }

    package init(
        jobID: String,
        sessionID: String,
        request: ReviewStartRequest,
        model: String?
    ) {
        self.jobID = jobID
        self.sessionID = sessionID
        self.request = request
        self.model = model
    }
}

package struct BackendReviewRun: Codable, Equatable, Sendable {
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

package struct BackendReviewRecoveryToken: Equatable, Sendable {
    package var interruptedRun: BackendReviewRun
    package var rollbackThreadID: String

    package init(
        interruptedRun: BackendReviewRun,
        rollbackThreadID: String
    ) {
        self.interruptedRun = interruptedRun
        self.rollbackThreadID = rollbackThreadID
    }
}

package enum BackendReviewEvent: Equatable, Sendable {
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

package struct BackendCancellationReason: Codable, Equatable, Sendable {
    package var message: String

    package init(message: String = "Cancellation requested.") {
        self.message = message
    }
}
