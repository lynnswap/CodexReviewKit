import Foundation

package enum CodexReviewBackendModel {
    package enum Settings {}
    package enum Account {}
    package enum Auth {}
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

package extension CodexReviewBackendModel.Review {
    struct Start: Equatable, Sendable {
        package var runID: ReviewRunID
        package var sessionID: String
        package var request: CodexReviewAPI.Start.Request
        package var model: String?

        package init(runID: ReviewRunID, sessionID: String, request: CodexReviewAPI.Start.Request) {
            self.init(runID: runID, sessionID: sessionID, request: request, model: nil)
        }

        package init(
            runID: ReviewRunID,
            sessionID: String,
            request: CodexReviewAPI.Start.Request,
            model: String?
        ) {
            self.runID = runID
            self.sessionID = sessionID
            self.request = request
            self.model = model
        }
    }
}

package extension CodexReviewBackendModel.Review {
    struct RestartToken: Equatable, Sendable {
        package var id: String
        package var interruptedAttempt: ReviewAttempt

        package init(
            id: String,
            interruptedAttempt: ReviewAttempt
        ) {
            self.id = id
            self.interruptedAttempt = interruptedAttempt
        }
    }
}

package struct ReviewTurnFailure: Codable, Hashable, Sendable {
    package enum Code: Codable, Hashable, Sendable {
        case contextWindowExceeded
        case sessionBudgetExceeded
        case usageLimitExceeded
        case serverOverloaded
        case cyberPolicy
        case httpConnectionFailed(status: UInt16?)
        case responseStreamConnectionFailed(status: UInt16?)
        case internalServerError
        case unauthorized
        case badRequest
        case threadRollbackFailed
        case sandboxError
        case responseStreamDisconnected(status: UInt16?)
        case responseTooManyFailedAttempts(status: UInt16?)
        case activeTurnNotSteerable(kind: String)
        case other
        case unknown(rawValue: String)
    }

    package var message: String
    package var code: Code?
    package var additionalDetails: String?

    package init(
        message: String,
        code: Code? = nil,
        additionalDetails: String? = nil
    ) {
        self.message = message
        self.code = code
        self.additionalDetails = additionalDetails
    }
}

package enum ReviewBackendConnectionTermination: Codable, Hashable, Sendable {
    case closed
    case transport(message: String)
    case processExited(status: Int32?)
}

package struct ReviewBackendOperationFailure: Codable, Hashable, Sendable {
    package enum Operation: String, Codable, Hashable, Sendable {
        case startReview
        case interruptReview
        case prepareRestart
        case restartReview
    }

    package enum LaunchKind: String, Codable, Hashable, Sendable {
        case executableNotFound
        case scaffold
        case spawn
    }

    package enum RequestKind: Codable, Hashable, Sendable {
        case encode
        case write
        case transport
        case server(code: Int, turnFailure: ReviewTurnFailure?)
        case invalidResponse(expectedType: String)
        case deadlineExceeded
        case overloadRetryExhausted(
            lastCode: Int,
            lastTurnFailure: ReviewTurnFailure?,
            attempts: Int
        )
    }

    package enum Reason: Codable, Hashable, Sendable {
        case launch(LaunchKind)
        case request(requestID: Int, method: String, kind: RequestKind)
        case connectionTerminated(ReviewBackendConnectionTermination)
        case turnDeadlineExceeded(turnID: ReviewTurnID, duration: Duration)
        case malformedNotification(method: String)
        case reviewRestartUnavailable
    }

    package let operation: Operation
    package let reason: Reason
    package let message: String

    package init(operation: Operation, reason: Reason, message: String) {
        self.operation = operation
        self.reason = reason
        self.message = message
    }
}

package enum ReviewBackendFailure: Error, Codable, Hashable, Sendable {
    case operation(ReviewBackendOperationFailure)
    case missingReviewOutput(turnID: ReviewTurnID)
    case outputPublication(ReviewOutputPublicationFailure)
    case invalidTerminalStatus(
        rawStatus: String,
        turnID: ReviewTurnID,
        turnFailure: ReviewTurnFailure?
    )
    case turnFailed(ReviewTurnFailure)
    case interruptedByBackend(message: String?)
    case connectionTerminated(ReviewBackendConnectionTermination)
    case retentionJournal(message: String)
    case connectivityObservationEnded
    case prepareRestartCancelledUnexpectedly
    case restartCancelledUnexpectedly
    case protocolViolation(message: String)

    package var message: String {
        switch self {
        case .operation(let failure):
            failure.message
        case .missingReviewOutput:
            "Review completed without review output."
        case .outputPublication(let failure):
            failure.message
        case .invalidTerminalStatus(let rawStatus, _, _):
            "Review ended with invalid terminal status \(rawStatus)."
        case .turnFailed(let failure):
            failure.message
        case .interruptedByBackend(let message):
            message?.nilIfEmpty ?? "Review was interrupted by the backend."
        case .connectionTerminated(let termination):
            switch termination {
            case .closed:
                "The review backend connection closed."
            case .transport(let message):
                message
            case .processExited(let status):
                status.map { "The review backend process exited with status \($0)." }
                    ?? "The review backend process exited."
            }
        case .retentionJournal(let message):
            message
        case .connectivityObservationEnded:
            "Network connectivity observation ended unexpectedly."
        case .prepareRestartCancelledUnexpectedly:
            "Review restart preparation was cancelled unexpectedly."
        case .restartCancelledUnexpectedly:
            "Review restart was cancelled unexpectedly."
        case .protocolViolation(let message):
            message
        }
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
