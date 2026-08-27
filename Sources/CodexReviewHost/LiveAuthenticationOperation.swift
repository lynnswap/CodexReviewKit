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
        private var resources: ResourceCleanup?
        var isOpen: Bool { resources != nil }
        var challenge: CodexReviewBackendModel.Login.Challenge? { resources?.challenge }
        var backend: AppServerCodexReviewBackend? { resources?.backend }
        var codexHomeURL: URL? { resources?.codexHomeURL }

        init(_ resources: ResourceCleanup) { self.resources = resources }

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
    }

    let activation: Activation
    let method: CodexReviewAuthenticationMethod
    var usesAPIKey: Bool { if case .apiKey = method { true } else { false } }
    private(set) var resourceScope: ResourceScope?
    private(set) var setupTask: Task<Void, Never>?
    private var apiKeyRequestWasAdmitted = false
    var hasAdmittedAPIKeyRequest: Bool { apiKeyRequestWasAdmitted }
    var phase = Phase.waitingForCompletion

    init(activation: Activation, method: CodexReviewAuthenticationMethod) {
        self.activation = activation
        self.method = method
    }

    func install(setupTask: Task<Void, Never>) {
        self.setupTask = setupTask
    }

    func cancelSetup() {
        setupTask?.cancel()
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

    func isCurrent(_ scope: ResourceScope?) -> Bool { resourceScope === scope }
}
