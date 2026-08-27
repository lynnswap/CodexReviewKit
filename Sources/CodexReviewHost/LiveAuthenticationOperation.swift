import Foundation
import CodexReview
import CodexReviewAppServer

@MainActor
final class LiveAuthenticationOperation {
    struct AdmissionTransition {
        var scope: ResourceScope
        var displacedResources: ResourceCleanup?
        var displacedNotificationTask: Task<Void, Never>?
    }

    struct ResourceCleanup {
        var challenge: CodexReviewBackendModel.Login.Challenge?
        var backend: AppServerCodexReviewBackend?
        var client: AppServerClient?
        var codexHomeURL: URL?
        var authenticationSession: (any CodexReviewNativeAuthentication.WebSession)?
        var monitorTask: Task<Void, Never>?

        var isEmpty: Bool { challenge == nil && backend == nil && client == nil && codexHomeURL == nil && authenticationSession == nil && monitorTask == nil }
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

    var activation = Activation.activateAuthenticatedAccount
    private(set) var resourceScope: ResourceScope?
    var phase = Phase.waitingForCompletion
    var notificationTask: Task<Void, Never>?

    func replaceResources(
        _ resources: ResourceCleanup,
        activation: Activation
    ) -> AdmissionTransition {
        let displacedResources = resourceScope?.takeForCleanup()
        let displacedNotificationTask = notificationTask
        let scope = ResourceScope(resources)
        resourceScope = scope
        notificationTask = nil
        self.activation = activation
        phase = .waitingForCompletion
        return .init(
            scope: scope,
            displacedResources: displacedResources,
            displacedNotificationTask: displacedNotificationTask
        )
    }

    func isCurrent(_ scope: ResourceScope?) -> Bool { resourceScope === scope }
}
