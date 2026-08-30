import Foundation
import CodexReview
import CodexReviewAppServer

@MainActor
final class LiveAuthenticationOperation {
    struct PrimaryLoginNotificationReplay {
        let completion: JSONRPC.Notification
        let includesAccountUpdate: Bool
        let success: Bool
        let error: String?
        let terminalPublicationOwner: TerminalPublicationOwner
    }

    private struct PrimaryNotificationRoute {
        struct StagedLoginCompletion {
            let notification: JSONRPC.Notification
            let receipt: JSONRPC.NotificationReceipt
            let success: Bool
            let error: String?
            let terminalPublicationOwner: TerminalPublicationOwner
        }

        enum RequestStage: Equatable {
            case preparingChatGPT
            case awaitingChatGPTChallenge
            case chatGPTStartRejected
            case chatGPTChallengeReceived
            case apiKey
        }

        let generation: UInt64
        let completedReceiptAtAdmission: JSONRPC.NotificationReceipt
        var startReceipt: JSONRPC.NotificationReceipt?
        var requestStage: RequestStage
        var stagedLoginCompletions: [String: StagedLoginCompletion]
        var stagedAccountUpdateHighWatermark: JSONRPC.NotificationReceipt?
    }

    struct ResourceCleanup {
        var challenge: CodexReviewBackendModel.Login.Challenge?
        var backend: AppServerCodexReviewBackend?
        var client: AppServerClient?
        var codexHomeURL: URL?
        var authenticationSession: (any CodexReviewNativeAuthentication.WebSession)?
        var monitorTask: Task<Void, Never>?
        var notificationTask: Task<Void, Never>?

        var isEmpty: Bool { challenge == nil && backend == nil && client == nil && codexHomeURL == nil && authenticationSession == nil && monitorTask == nil && notificationTask == nil }
    }

    final class ResourceScope {
        private let originatingBackendIdentity: ObjectIdentifier?
        private let originatingChallengeID: String?
        private var resources: ResourceCleanup?
        var isOpen: Bool { resources != nil }
        var challenge: CodexReviewBackendModel.Login.Challenge? { resources?.challenge }
        var backend: AppServerCodexReviewBackend? { resources?.backend }
        var codexHomeURL: URL? { resources?.codexHomeURL }

        init(_ resources: ResourceCleanup) {
            self.originatingBackendIdentity = resources.backend.map(ObjectIdentifier.init)
            self.originatingChallengeID = resources.challenge?.id
            self.resources = resources
        }

        func matchesOriginatingBackend(_ backend: AppServerCodexReviewBackend) -> Bool {
            originatingBackendIdentity == ObjectIdentifier(backend)
        }

        func matchesOriginatingChallenge(_ loginID: String) -> Bool {
            originatingChallengeID == loginID
        }

        var stableChallengeID: String? { originatingChallengeID }

        func install(session: any CodexReviewNativeAuthentication.WebSession, monitorTask: Task<Void, Never>) {
            resources?.authenticationSession = session
            resources?.monitorTask = monitorTask
        }

        func install(session: any CodexReviewNativeAuthentication.WebSession) { resources?.authenticationSession = session }

        func install(notificationTask: Task<Void, Never>) { resources?.notificationTask = notificationTask }

        func takePresentation() -> (
            session: (any CodexReviewNativeAuthentication.WebSession)?,
            monitorTask: Task<Void, Never>?
        ) {
            defer {
                resources?.challenge = nil
                resources?.authenticationSession = nil
                resources?.monitorTask = nil
            }
            return (resources?.authenticationSession, resources?.monitorTask)
        }

        func takeForCleanup() -> ResourceCleanup? { defer { resources = nil }; return resources }
    }

    enum Activation: Equatable, Sendable {
        case activateAuthenticatedAccount
        case preserveActiveAccount(String?)

        func resolvedActiveAccountKey(
            authenticatedAccountKey: String,
            persistedAccounts: [CodexAccount]
        ) -> String? {
            switch self {
            case .activateAuthenticatedAccount:
                return authenticatedAccountKey
            case .preserveActiveAccount(let activeAccountKey):
                return activeAccountKey.flatMap { activeAccountKey in
                    persistedAccounts.contains(where: { $0.accountKey == activeAccountKey })
                        ? activeAccountKey
                        : nil
                }
            }
        }
    }

    enum Phase: Equatable {
        case waitingForCompletion
        case waitingForAccountUpdate
        case terminalFailureObserved
        case terminalSuccessCommitted
    }

    enum TerminalPublicationOwner: Equatable {
        case notification
        case userCancellation
        case hostFailure
    }

    enum PrimaryRuntimeInvalidationReason: Equatable {
        case cancelledAfterLoginSuccess
        case loginStartOutcomeUnknown
    }

    let activation: Activation
    let method: CodexReviewAuthenticationMethod
    let rollbackAccountKey: String?
    var usesAPIKey: Bool { if case .apiKey = method { true } else { false } }
    private(set) var resourceScope: ResourceScope?
    private(set) var setupTask: Task<Void, Never>?
    private var primaryNotificationRoute: PrimaryNotificationRoute?
    var primaryNotificationRouteGeneration: UInt64? { primaryNotificationRoute?.generation }
    var primaryNotificationCompletedReceiptAtAdmission: JSONRPC.NotificationReceipt? {
        primaryNotificationRoute?.completedReceiptAtAdmission
    }
    var primaryNotificationRouteStartReceipt: JSONRPC.NotificationReceipt? {
        primaryNotificationRoute?.startReceipt
    }
    private var apiKeyRequestWasAdmitted = false
    private var allowsSharedStateCommits = true
    private(set) var retiresPrimaryNotificationRoute = false
    private(set) var quarantinesLatePrimaryLoginCompletion = false
    private(set) var primaryRuntimeInvalidationReason: PrimaryRuntimeInvalidationReason?
    private(set) var terminalPublicationOwner = TerminalPublicationOwner.notification
    var hasAdmittedAPIKeyRequest: Bool { apiKeyRequestWasAdmitted }
    var phase = Phase.waitingForCompletion

    init(
        activation: Activation,
        method: CodexReviewAuthenticationMethod,
        rollbackAccountKey: String? = nil
    ) {
        self.activation = activation
        self.method = method
        self.rollbackAccountKey = rollbackAccountKey
    }

    func install(setupTask: Task<Void, Never>) {
        self.setupTask = setupTask
    }

    func beginCancellation() {
        guard phase != .terminalSuccessCommitted else { return }
        // An admitted API-key request must reconcile its outcome exactly once; cancellation
        // waits for that owner or removes the operation after the bounded setup join.
        if apiKeyRequestWasAdmitted == false {
            allowsSharedStateCommits = false
        }
        if phase != .terminalFailureObserved {
            terminalPublicationOwner = .userCancellation
        }
        prepareChatGPTRetirement()
        setupTask?.cancel()
    }

    func beginUserCancellation() {
        guard phase != .terminalSuccessCommitted else { return }
        allowsSharedStateCommits = false
        if phase != .terminalFailureObserved {
            terminalPublicationOwner = .userCancellation
        }
        prepareChatGPTRetirement()
    }

    func beginTerminalAbort() {
        guard phase != .terminalSuccessCommitted else { return }
        allowsSharedStateCommits = false
        if phase != .terminalFailureObserved {
            terminalPublicationOwner = .hostFailure
        }
        prepareChatGPTRetirement()
    }

    func beginTerminalFailure(
        publicationOwner: TerminalPublicationOwner? = nil
    ) {
        if let publicationOwner {
            terminalPublicationOwner = publicationOwner
        }
        allowsSharedStateCommits = false
        retiresPrimaryNotificationRoute = true
        quarantinesLatePrimaryLoginCompletion = false
        primaryRuntimeInvalidationReason = nil
        phase = .terminalFailureObserved
    }

    func revokeSharedStateCommits() {
        allowsSharedStateCommits = false
    }

    func commitAuthenticationSuccess(from scope: ResourceScope) -> Bool {
        guard phase == .waitingForAccountUpdate,
              authorizesSharedStateCommit(from: scope)
        else {
            return false
        }
        phase = .terminalSuccessCommitted
        terminalPublicationOwner = .notification
        quarantinesLatePrimaryLoginCompletion = false
        primaryRuntimeInvalidationReason = nil
        return true
    }

    func beginPrimaryChatGPTLoginStart() {
        guard primaryNotificationRoute?.requestStage == .preparingChatGPT else { return }
        primaryNotificationRoute?.requestStage = .awaitingChatGPTChallenge
    }

    func stagePrimaryLoginCompletion(
        _ notification: JSONRPC.Notification,
        loginID: String,
        success: Bool,
        error: String?,
        receipt: JSONRPC.NotificationReceipt
    ) -> Bool {
        guard var route = primaryNotificationRoute,
              route.requestStage == .awaitingChatGPTChallenge,
              let startReceipt = route.startReceipt,
              receipt > startReceipt
        else {
            return false
        }
        if route.stagedLoginCompletions[loginID] == nil {
            route.stagedLoginCompletions[loginID] = .init(
                notification: notification,
                receipt: receipt,
                success: success,
                error: error,
                terminalPublicationOwner: terminalPublicationOwner
            )
        }
        primaryNotificationRoute = route
        return true
    }

    func stagePrimaryAccountUpdate(receipt: JSONRPC.NotificationReceipt) -> Bool {
        guard var route = primaryNotificationRoute,
              route.requestStage == .awaitingChatGPTChallenge,
              let startReceipt = route.startReceipt,
              receipt > startReceipt
        else {
            return false
        }
        route.stagedAccountUpdateHighWatermark = max(
            route.stagedAccountUpdateHighWatermark ?? .beforeFirst,
            receipt
        )
        primaryNotificationRoute = route
        return true
    }

    func receivePrimaryChatGPTLoginChallenge(
        loginID: String
    ) -> PrimaryLoginNotificationReplay? {
        guard var route = primaryNotificationRoute,
              route.requestStage == .awaitingChatGPTChallenge
        else {
            return nil
        }
        route.requestStage = .chatGPTChallengeReceived
        let stagedCompletion = route.stagedLoginCompletions[loginID]
        let includesAccountUpdate = stagedCompletion.map { completion in
            route.stagedAccountUpdateHighWatermark.map { $0 > completion.receipt } == true
        } ?? false
        route.stagedLoginCompletions.removeAll(keepingCapacity: false)
        route.stagedAccountUpdateHighWatermark = nil
        primaryNotificationRoute = route
        if let stagedCompletion, stagedCompletion.success == false {
            beginTerminalFailure(
                publicationOwner: stagedCompletion.terminalPublicationOwner
            )
        }
        return stagedCompletion.map {
            PrimaryLoginNotificationReplay(
                completion: $0.notification,
                includesAccountUpdate: includesAccountUpdate,
                success: $0.success,
                error: $0.error,
                terminalPublicationOwner: $0.terminalPublicationOwner
            )
        }
    }

    func rejectPrimaryChatGPTLoginStart() {
        guard primaryNotificationRoute?.requestStage == .awaitingChatGPTChallenge else { return }
        primaryNotificationRoute?.requestStage = .chatGPTStartRejected
        if primaryRuntimeInvalidationReason == .loginStartOutcomeUnknown {
            primaryRuntimeInvalidationReason = nil
        }
    }

    func markPrimaryChatGPTLoginStartOutcomeUnknown() {
        guard primaryNotificationRoute?.requestStage == .awaitingChatGPTChallenge else { return }
        retiresPrimaryNotificationRoute = true
        quarantinesLatePrimaryLoginCompletion = false
        primaryRuntimeInvalidationReason = .loginStartOutcomeUnknown
    }

    private func prepareChatGPTRetirement() {
        guard case .chatGPT = method else { return }
        retiresPrimaryNotificationRoute = true
        if primaryNotificationRoute?.requestStage == .awaitingChatGPTChallenge {
            primaryRuntimeInvalidationReason = .loginStartOutcomeUnknown
        }
        switch phase {
        case .waitingForCompletion:
            quarantinesLatePrimaryLoginCompletion = true
        case .waitingForAccountUpdate:
            quarantinesLatePrimaryLoginCompletion = false
            primaryRuntimeInvalidationReason = .cancelledAfterLoginSuccess
        case .terminalFailureObserved:
            quarantinesLatePrimaryLoginCompletion = false
        case .terminalSuccessCommitted:
            quarantinesLatePrimaryLoginCompletion = false
        }
    }

    func waitForSetup() async {
        await setupTask?.value
    }

    func admitAPIKeyRequest() -> Bool {
        guard setupTask?.isCancelled == false else { return false }
        apiKeyRequestWasAdmitted = true
        return true
    }

    func installResources(_ resources: ResourceCleanup) -> ResourceScope? {
        guard resourceScope == nil else { return nil }
        let scope = ResourceScope(resources)
        resourceScope = scope
        if phase != .terminalFailureObserved,
           phase != .terminalSuccessCommitted
        {
            phase = .waitingForCompletion
        }
        return scope
    }

    func installPrimaryNotificationRoute(
        generation: UInt64,
        completedReceipt: JSONRPC.NotificationReceipt
    ) {
        guard primaryNotificationRoute == nil else { return }
        let requestStage: PrimaryNotificationRoute.RequestStage = switch method {
        case .chatGPT:
            .preparingChatGPT
        case .apiKey:
            .apiKey
        }
        primaryNotificationRoute = .init(
            generation: generation,
            completedReceiptAtAdmission: completedReceipt,
            startReceipt: nil,
            requestStage: requestStage,
            stagedLoginCompletions: [:],
            stagedAccountUpdateHighWatermark: nil
        )
    }

    func installPrimaryNotificationRoute(after receipt: JSONRPC.NotificationReceipt) {
        guard primaryNotificationRoute?.startReceipt == nil else { return }
        primaryNotificationRoute?.startReceipt = receipt
    }

    func isCurrent(_ scope: ResourceScope?) -> Bool { resourceScope === scope }

    func authorizesSharedStateCommit(from scope: ResourceScope) -> Bool {
        allowsSharedStateCommits && isCurrent(scope)
    }
}
