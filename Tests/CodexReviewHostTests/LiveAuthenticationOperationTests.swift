import Foundation
import Testing
import CodexReview
import CodexReviewAppServer
@testable import CodexReviewHost

@Suite("authentication operation")
@MainActor
struct LiveAuthenticationOperationTests {
    @Test func cancellationRevokesSharedStateCommitsWithoutDiscardingResourceOwnership() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        let scope = try #require(operation.installResources(.init()))

        #expect(operation.authorizesSharedStateCommit(from: scope))

        operation.beginCancellation()

        #expect(operation.isCurrent(scope))
        #expect(scope.isOpen)
        #expect(operation.authorizesSharedStateCommit(from: scope) == false)
    }

    @Test func normalCompletionKeepsCommitAuthorityAfterTakingCleanupResources() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        let scope = try #require(operation.installResources(.init()))
        let unrelatedScope = LiveAuthenticationOperation.ResourceScope(.init())

        _ = try #require(scope.takeForCleanup())

        #expect(scope.isOpen == false)
        #expect(operation.authorizesSharedStateCommit(from: scope))
        #expect(operation.authorizesSharedStateCommit(from: unrelatedScope) == false)
    }

    @Test func admittedAPIKeyReconciliationKeepsCommitAuthorityDuringCancellation() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .apiKey(try CodexReviewAPIKey(validating: "sk-test"))
        )
        let scope = try #require(operation.installResources(.init()))
        operation.install(setupTask: Task { @MainActor in })

        #expect(operation.admitAPIKeyRequest())

        operation.beginCancellation()

        #expect(operation.authorizesSharedStateCommit(from: scope))
    }

    @Test func cancellationBeforePrimaryLoginRequestDoesNotRequireRuntimeInvalidation() {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        operation.installPrimaryNotificationRoute(
            generation: 1,
            completedReceipt: .beforeFirst
        )

        operation.beginCancellation()

        #expect(operation.primaryRuntimeInvalidationReason == nil)
    }

    @Test func cancellationWhilePrimaryLoginChallengeIsUnknownRequiresRuntimeInvalidation() {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        operation.installPrimaryNotificationRoute(
            generation: 1,
            completedReceipt: .beforeFirst
        )
        operation.beginPrimaryChatGPTLoginStart()

        operation.beginCancellation()

        #expect(operation.primaryRuntimeInvalidationReason == .loginStartOutcomeUnknown)
    }

    @Test func definitivePrimaryLoginRejectionClearsCancellationInvalidation() {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        operation.installPrimaryNotificationRoute(
            generation: 1,
            completedReceipt: .beforeFirst
        )
        operation.beginPrimaryChatGPTLoginStart()
        operation.beginCancellation()

        operation.rejectPrimaryChatGPTLoginStart()

        #expect(operation.primaryRuntimeInvalidationReason == nil)
        #expect(operation.retiresPrimaryNotificationRoute)
    }

    @Test func primaryLoginNotificationsReceivedBeforeChallengeReplayByLoginID() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        operation.installPrimaryNotificationRoute(
            generation: 1,
            completedReceipt: .beforeFirst
        )
        operation.installPrimaryNotificationRoute(after: .init(sequence: 1))
        operation.beginPrimaryChatGPTLoginStart()
        let completion = JSONRPC.Notification(
            method: "account/login/completed",
            params: Data("{}".utf8)
        )

        #expect(operation.stagePrimaryLoginCompletion(
            completion,
            loginID: "login-1",
            success: true,
            error: nil,
            receipt: .init(sequence: 2)
        ))
        #expect(operation.stagePrimaryAccountUpdate(receipt: .init(sequence: 3)))

        let replay = try #require(
            operation.receivePrimaryChatGPTLoginChallenge(loginID: "login-1")
        )
        #expect(replay.completion == completion)
        #expect(replay.includesAccountUpdate)
    }

    @Test func matchingPrimaryLoginFailureClearsPreChallengeCancellationInvalidation() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        operation.installPrimaryNotificationRoute(
            generation: 1,
            completedReceipt: .beforeFirst
        )
        operation.installPrimaryNotificationRoute(after: .init(sequence: 1))
        operation.beginPrimaryChatGPTLoginStart()
        #expect(operation.stagePrimaryLoginCompletion(
            .init(method: "account/login/completed", params: Data("{}".utf8)),
            loginID: "login-1",
            success: false,
            error: "Login failed.",
            receipt: .init(sequence: 2)
        ))
        operation.beginCancellation()

        let replay = try #require(
            operation.receivePrimaryChatGPTLoginChallenge(loginID: "login-1")
        )
        #expect(operation.beginTerminalFailure(
            publicationOwner: replay.terminalPublicationOwner
        ))

        #expect(operation.primaryRuntimeInvalidationReason == nil)
        #expect(operation.phase == .terminalFailureObserved)
        #expect(operation.terminalPublicationOwner == .notification)
    }

    @Test func committedAuthenticationSuccessWinsLaterCancellation() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        let scope = try #require(operation.installResources(.init()))
        operation.phase = .waitingForAccountUpdate

        #expect(operation.commitAuthenticationSuccess(
            from: .notification,
            from: scope
        ))
        operation.beginCancellation()

        #expect(operation.phase == .terminalSuccessCommitted)
        #expect(operation.terminalPublicationOwner == .notification)
        #expect(operation.authorizesSharedStateCommit(from: scope))
        #expect(operation.primaryRuntimeInvalidationReason == nil)
        #expect(operation.retiresPrimaryNotificationRoute == false)
    }

    @Test func callbackSuccessCanPreemptNotificationPreparationExactlyOnce() throws {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        let scope = try #require(operation.installResources(.init()))

        #expect(operation.beginAuthenticationCommitPreparation(from: scope))
        #expect(operation.commitAuthenticationSuccess(
            from: .callback,
            from: scope
        ))
        #expect(operation.commitAuthenticationSuccess(
            from: .notification,
            from: scope
        ) == false)
        #expect(operation.phase == .terminalSuccessCommitted)
    }

    @Test func notificationSuccessRequiresPreparationWhileCallbackDoesNot() throws {
        let notificationOperation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        let notificationScope = try #require(notificationOperation.installResources(.init()))
        #expect(notificationOperation.commitAuthenticationSuccess(
            from: .notification,
            from: notificationScope
        ) == false)

        let callbackOperation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        let callbackScope = try #require(callbackOperation.installResources(.init()))
        #expect(callbackOperation.commitAuthenticationSuccess(
            from: .callback,
            from: callbackScope
        ))
        callbackOperation.beginCancellation()
        #expect(callbackOperation.phase == .terminalSuccessCommitted)
        #expect(callbackOperation.authorizesSharedStateCommit(from: callbackScope))
    }

    @Test func cancellationAfterPrimaryLoginChallengeUsesScopedRetirement() {
        let operation = LiveAuthenticationOperation(
            activation: .activateAuthenticatedAccount,
            method: .chatGPT
        )
        operation.installPrimaryNotificationRoute(
            generation: 1,
            completedReceipt: .beforeFirst
        )
        operation.beginPrimaryChatGPTLoginStart()
        _ = operation.receivePrimaryChatGPTLoginChallenge(loginID: "login-1")

        operation.beginCancellation()

        #expect(operation.primaryRuntimeInvalidationReason == nil)
        #expect(operation.retiresPrimaryNotificationRoute)
        #expect(operation.quarantinesLatePrimaryLoginCompletion)
    }
}
