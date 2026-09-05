import Foundation
import Testing
@testable import CodexReview

@Suite("model-capacity recovery")
struct ReviewModelCapacityRecoveryTests {
    @Test func retryDelayCapsAtSixtySecondsAndResetsAfterRecovery() {
        let policy = CodexReviewModelCapacityRecoveryPolicy()
        var state = ReviewModelCapacityRetryState()

        #expect([
            state.nextDelay(using: policy),
            state.nextDelay(using: policy),
            state.nextDelay(using: policy),
            state.nextDelay(using: policy),
        ] == [
            .seconds(15),
            .seconds(30),
            .seconds(60),
            .seconds(60),
        ])

        state.reset()

        #expect(state.nextDelay(using: policy) == .seconds(15))
    }

    @Test func replacementWaitsForCapacityDelayAndSettledNetwork() {
        var state = ReviewRecoveryLoopState()

        #expect(state.isReadyToStageRecovery == false)
        state.beginModelCapacityRecovery(networkStatus: .satisfied)
        #expect(state.isReadyToStageRecovery == false)

        #expect(state.networkSnapshotEffect(
            .init(status: .unsatisfied),
            recoveryGeneration: 1
        ) == .none)
        let didFinishBackoff = state.markModelCapacityBackoffElapsed()
        #expect(didFinishBackoff)
        #expect(state.isReadyToStageRecovery == false)

        #expect(state.networkSnapshotEffect(
            .satisfied(),
            recoveryGeneration: 2
        ) == .restartSettling)
        let staleRecoverySettled = state.markNetworkRecoverySettled(recoveryGeneration: 1)
        #expect(staleRecoverySettled == false)
        #expect(state.isReadyToStageRecovery == false)
        let currentRecoverySettled = state.markNetworkRecoverySettled(recoveryGeneration: 2)
        #expect(currentRecoverySettled)
        #expect(state.isReadyToStageRecovery)

        state.markRecovered()
        #expect(state.isReadyToStageRecovery == false)
    }

    @Test func capacityDelayCanFinishAfterNetworkSettles() {
        var state = ReviewRecoveryLoopState()
        state.beginModelCapacityRecovery(networkStatus: .unsatisfied)

        #expect(state.networkSnapshotEffect(
            .satisfied(),
            recoveryGeneration: 3
        ) == .restartSettling)
        let networkSettled = state.markNetworkRecoverySettled(recoveryGeneration: 3)
        #expect(networkSettled)
        #expect(state.isReadyToStageRecovery == false)
        let backoffElapsed = state.markModelCapacityBackoffElapsed()
        #expect(backoffElapsed)
        #expect(state.isReadyToStageRecovery)
    }

    @Test func capacityBackoffAttachesToNetworkOwnedRecovery() {
        var state = ReviewRecoveryLoopState()

        let hadPendingTerminal = state.beginNetworkRecovery()
        #expect(hadPendingTerminal == false)
        let attachedBackoff = state.attachModelCapacityBackoff()
        #expect(attachedBackoff)
        let attachedBackoffElapsed = state.markModelCapacityBackoffElapsed()
        #expect(attachedBackoffElapsed)
        #expect(state.isReadyToStageRecovery == false)

        #expect(state.networkSnapshotEffect(
            .satisfied(),
            recoveryGeneration: 4
        ) == .restartSettling)
        let attachedRecoverySettled = state.markNetworkRecoverySettled(recoveryGeneration: 4)
        #expect(attachedRecoverySettled)
        #expect(state.isReadyToStageRecovery)
        let duplicateBackoff = state.attachModelCapacityBackoff()
        #expect(duplicateBackoff == false)
    }
}
