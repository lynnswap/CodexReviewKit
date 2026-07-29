import Foundation
import Testing

@testable import CodexReviewKit
@testable import CodexReviewMCPServer

@Suite("MCP review session registry")
@MainActor
struct MCPReviewSessionRegistryTests {
    @Test("Close joins pending start, late bind cancellation, and concurrent callers")
    func closeJoinsLateStartAndConcurrentCallers() async throws {
        let closeProbe = MCPRegistryCloseProbe()
        let releaseProbe = MCPRegistryReleaseProbe()
        let registry = MCPReviewSessionRegistry(
            closeStoreSession: { sessionID in
                await closeProbe.close(sessionID: sessionID)
            },
            releaseStoreSession: { sessionID in
                releaseProbe.release(sessionID: sessionID)
            }
        )
        let sessionID = "session-1"
        let runID = try ReviewRunID(validating: "run-1")
        await registry.openSession(sessionID)
        let operation = try await registry.beginOperation(in: sessionID)
        let reservation = try await registry.reserveStart(in: sessionID)

        let firstClose = await registry.beginClose(sessionID, reason: .delete)
        let secondClose = await registry.beginClose(sessionID, reason: .serverStop)
        await closeProbe.waitForFirstClose()

        await #expect(throws: MCPReviewSessionRegistryError.sessionNotOpen(sessionID)) {
            _ = try await registry.beginOperation(in: sessionID)
        }
        #expect(
            try await registry.bind(runID: runID, reservation: reservation)
                == .sessionClosing(.delete)
        )
        try await registry.finishOperation(operation)
        await #expect(throws: MCPReviewSessionRegistryError.invalidOperationToken) {
            try await registry.finishOperation(operation)
        }
        await closeProbe.setTerminalRunIDs([runID])
        await closeProbe.finishFirstClose()

        let firstReport = await firstClose.value
        let secondReport = await secondClose.value
        #expect(firstReport == secondReport)
        #expect(firstReport.reason == .delete)
        #expect(firstReport.members == [runID])
        #expect(firstReport.cancellationScheduled == [runID])
        #expect(firstReport.cancellationFinished == [runID])
        #expect(firstReport.cancellationFailed.isEmpty)
        #expect(await closeProbe.closeCount == 2)
        #expect(releaseProbe.releaseCount == 1)

        await registry.removeClosedSession(sessionID)
        #expect(await registry.stateForTesting(sessionID: sessionID) == nil)
    }

    @Test("Open session retains terminal membership until explicit removal")
    func membershipLivesUntilSessionRemoval() async throws {
        let sessionID = "session-1"
        let runID = try ReviewRunID(validating: "run-1")
        let registry = MCPReviewSessionRegistry(
            closeStoreSession: { _ in
                MCPReviewSessionStoreCloseResult(terminalAndDrainedRunIDs: [runID])
            },
            releaseStoreSession: { _ in }
        )
        await registry.openSession(sessionID)
        let reservation = try await registry.reserveStart(in: sessionID)
        #expect(try await registry.bind(runID: runID, reservation: reservation) == .bound)
        await #expect(throws: MCPReviewSessionRegistryError.invalidStartReservation) {
            try await registry.finishStart(reservation)
        }

        let memberOperation = try await registry.beginOperation(
            in: sessionID,
            requiringMember: runID
        )
        try await registry.validateMember(runID, for: memberOperation)
        #expect(try await registry.members(for: memberOperation) == [runID])
        try await registry.finishOperation(memberOperation)
        let otherRunID = try ReviewRunID(validating: "other-run")
        await #expect(throws: MCPReviewSessionRegistryError.runNotFound(otherRunID)) {
            _ = try await registry.beginOperation(
                in: sessionID,
                requiringMember: otherRunID
            )
        }

        let report = await registry.beginClose(sessionID, reason: .timeout).value
        #expect(report.members == [runID])
        if let state = await registry.stateForTesting(sessionID: sessionID) {
            guard case .closed(let storedReport) = state.phase else {
                Issue.record("Expected a closed registry tombstone.")
                return
            }
            #expect(storedReport == report)
        } else {
            Issue.record("Expected a closed registry tombstone.")
        }
    }

    @Test("Close report never fabricates cancellation completion")
    func closeReportRequiresStoreDrainEvidence() async throws {
        let sessionID = "session-1"
        let runID = try ReviewRunID(validating: "run-1")
        let registry = MCPReviewSessionRegistry(
            closeStoreSession: { _ in
                MCPReviewSessionStoreCloseResult(
                    terminalAndDrainedRunIDs: [],
                    failedRunIDs: [runID]
                )
            },
            releaseStoreSession: { _ in }
        )
        await registry.openSession(sessionID)
        let reservation = try await registry.reserveStart(in: sessionID)
        #expect(try await registry.bind(runID: runID, reservation: reservation) == .bound)

        let report = await registry.beginClose(sessionID, reason: .serverStop).value

        #expect(report.cancellationScheduled == [runID])
        #expect(report.cancellationFinished.isEmpty)
        #expect(report.cancellationFailed == [runID])
    }

    @Test("Close driver suspends until operation and start leases drain")
    func closeDriverWaitsForRegistryLeases() async throws {
        let sessionID = "session-1"
        let runID = try ReviewRunID(validating: "run-1")
        let closeProbe = MCPImmediateCloseProbe(terminalRunIDs: [runID])
        let releaseProbe = MCPRegistryReleaseProbe()
        let registry = MCPReviewSessionRegistry(
            closeStoreSession: { sessionID in
                await closeProbe.close(sessionID: sessionID)
            },
            releaseStoreSession: { sessionID in
                releaseProbe.release(sessionID: sessionID)
            }
        )
        await registry.openSession(sessionID)
        let operation = try await registry.beginOperation(in: sessionID)
        let reservation = try await registry.reserveStart(in: sessionID)

        let close = await registry.beginClose(sessionID, reason: .delete)
        await closeProbe.waitForCloseCount(1)
        #expect(releaseProbe.releaseCount == 0)

        #expect(
            try await registry.bind(runID: runID, reservation: reservation)
                == .sessionClosing(.delete)
        )
        try await registry.finishOperation(operation)

        let report = await close.value
        #expect(report.cancellationFinished == [runID])
        #expect(await closeProbe.closeCount == 2)
        #expect(releaseProbe.releaseCount == 1)
    }
}

private actor MCPRegistryCloseProbe {
    private(set) var closeCount = 0
    private var firstCloseStarted = false
    private var firstCloseStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCloseCanFinish = false
    private var firstCloseFinishWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalRunIDs: Set<ReviewRunID> = []

    func close(sessionID _: String) async -> MCPReviewSessionStoreCloseResult {
        closeCount += 1
        let terminalRunIDsAtStart = terminalRunIDs
        guard closeCount == 1 else {
            return MCPReviewSessionStoreCloseResult(
                terminalAndDrainedRunIDs: terminalRunIDsAtStart
            )
        }
        firstCloseStarted = true
        let startWaiters = firstCloseStartWaiters
        firstCloseStartWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }
        guard firstCloseCanFinish == false else {
            return MCPReviewSessionStoreCloseResult(
                terminalAndDrainedRunIDs: terminalRunIDsAtStart
            )
        }
        await withCheckedContinuation { continuation in
            firstCloseFinishWaiters.append(continuation)
        }
        return MCPReviewSessionStoreCloseResult(
            terminalAndDrainedRunIDs: terminalRunIDsAtStart
        )
    }

    func waitForFirstClose() async {
        guard firstCloseStarted == false else {
            return
        }
        await withCheckedContinuation { continuation in
            firstCloseStartWaiters.append(continuation)
        }
    }

    func finishFirstClose() {
        firstCloseCanFinish = true
        let finishWaiters = firstCloseFinishWaiters
        firstCloseFinishWaiters.removeAll()
        for waiter in finishWaiters {
            waiter.resume()
        }
    }

    func setTerminalRunIDs(_ runIDs: Set<ReviewRunID>) {
        terminalRunIDs = runIDs
    }
}

private actor MCPImmediateCloseProbe {
    private(set) var closeCount = 0
    private let terminalRunIDs: Set<ReviewRunID>
    private var closeCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(terminalRunIDs: Set<ReviewRunID>) {
        self.terminalRunIDs = terminalRunIDs
    }

    func close(sessionID _: String) -> MCPReviewSessionStoreCloseResult {
        closeCount += 1
        let readyWaiters = closeCountWaiters.filter { $0.0 <= closeCount }
        closeCountWaiters.removeAll { $0.0 <= closeCount }
        for (_, waiter) in readyWaiters {
            waiter.resume()
        }
        return MCPReviewSessionStoreCloseResult(
            terminalAndDrainedRunIDs: terminalRunIDs
        )
    }

    func waitForCloseCount(_ expectedCount: Int) async {
        guard closeCount < expectedCount else {
            return
        }
        await withCheckedContinuation { continuation in
            closeCountWaiters.append((expectedCount, continuation))
        }
    }
}

@MainActor
private final class MCPRegistryReleaseProbe {
    private(set) var releaseCount = 0

    func release(sessionID _: String) {
        releaseCount += 1
    }
}
