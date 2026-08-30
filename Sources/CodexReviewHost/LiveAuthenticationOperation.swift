import Foundation
import CodexReview
import CodexReviewAppServer

@MainActor
final class LiveAuthenticationOperation {
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
    }

    enum TerminalPublicationOwner: Equatable {
        case notification
        case userCancellation
        case hostFailure
    }

    let activation: Activation
    let method: CodexReviewAuthenticationMethod
    let rollbackAccountKey: String?
    var usesAPIKey: Bool { if case .apiKey = method { true } else { false } }
    private(set) var resourceScope: ResourceScope?
    private(set) var setupTask: Task<Void, Never>?
    private(set) var primaryNotificationRouteGeneration: UInt64?
    private(set) var primaryNotificationCompletedReceiptAtAdmission: JSONRPC.NotificationReceipt?
    private(set) var primaryNotificationRouteStartReceipt: JSONRPC.NotificationReceipt?
    private var apiKeyRequestWasAdmitted = false
    private var allowsSharedStateCommits = true
    private(set) var retiresPrimaryNotificationRoute = false
    private(set) var quarantinesLatePrimaryLoginCompletion = false
    private(set) var requiresPrimaryRuntimeInvalidation = false
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
        // An admitted API-key request must reconcile its outcome exactly once; cancellation
        // waits for that owner or removes the operation after the bounded setup join.
        if apiKeyRequestWasAdmitted == false {
            allowsSharedStateCommits = false
        }
        terminalPublicationOwner = .userCancellation
        prepareChatGPTRetirement()
        setupTask?.cancel()
    }

    func beginUserCancellation() {
        allowsSharedStateCommits = false
        terminalPublicationOwner = .userCancellation
        prepareChatGPTRetirement()
    }

    func beginTerminalAbort() {
        allowsSharedStateCommits = false
        terminalPublicationOwner = .hostFailure
        prepareChatGPTRetirement()
    }

    func beginTerminalFailure() {
        allowsSharedStateCommits = false
        retiresPrimaryNotificationRoute = true
        quarantinesLatePrimaryLoginCompletion = false
        requiresPrimaryRuntimeInvalidation = false
        phase = .terminalFailureObserved
    }

    func revokeSharedStateCommits() {
        allowsSharedStateCommits = false
    }

    private func prepareChatGPTRetirement() {
        guard case .chatGPT = method else { return }
        retiresPrimaryNotificationRoute = true
        switch phase {
        case .waitingForCompletion:
            quarantinesLatePrimaryLoginCompletion = true
        case .waitingForAccountUpdate:
            quarantinesLatePrimaryLoginCompletion = false
            requiresPrimaryRuntimeInvalidation = true
        case .terminalFailureObserved:
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
        phase = .waitingForCompletion
        return scope
    }

    func installPrimaryNotificationRoute(
        generation: UInt64,
        completedReceipt: JSONRPC.NotificationReceipt
    ) {
        guard primaryNotificationRouteGeneration == nil else { return }
        primaryNotificationRouteGeneration = generation
        primaryNotificationCompletedReceiptAtAdmission = completedReceipt
    }

    func installPrimaryNotificationRoute(after receipt: JSONRPC.NotificationReceipt) {
        guard primaryNotificationRouteStartReceipt == nil else { return }
        primaryNotificationRouteStartReceipt = receipt
    }

    func isCurrent(_ scope: ResourceScope?) -> Bool { resourceScope === scope }

    func authorizesSharedStateCommit(from scope: ResourceScope) -> Bool {
        allowsSharedStateCommits && isCurrent(scope)
    }
}
