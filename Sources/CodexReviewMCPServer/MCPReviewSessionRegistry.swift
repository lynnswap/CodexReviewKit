import Foundation
import CodexReviewKit

package enum MCPReviewSessionCloseReason: String, Equatable, Sendable {
    case delete
    case timeout
    case serverStop
    case initializationFailure
}

package struct MCPReviewStartReservation: Hashable, Sendable {
    package let sessionID: String
    fileprivate let id: UUID
}

package struct MCPSessionOperationToken: Hashable, Sendable {
    package let sessionID: String
    fileprivate let id: UUID
}

package struct MCPReviewSessionCloseReport: Equatable, Sendable {
    package let sessionID: String
    package let reason: MCPReviewSessionCloseReason
    package let members: Set<ReviewRunID>
    package let cancellationScheduled: Set<ReviewRunID>
    package let cancellationFinished: Set<ReviewRunID>
    package let cancellationFailed: Set<ReviewRunID>
}

package struct MCPReviewSessionStoreCloseResult: Equatable, Sendable {
    package let terminalAndDrainedRunIDs: Set<ReviewRunID>
    package let failedRunIDs: Set<ReviewRunID>

    package init(
        terminalAndDrainedRunIDs: Set<ReviewRunID>,
        failedRunIDs: Set<ReviewRunID> = []
    ) {
        self.terminalAndDrainedRunIDs = terminalAndDrainedRunIDs
        self.failedRunIDs = failedRunIDs
    }
}

package enum MCPReviewSessionRegistryError: LocalizedError, Equatable, Sendable {
    case sessionNotOpen(String)
    case invalidStartReservation
    case invalidOperationToken
    case runNotFound(ReviewRunID)

    package var errorDescription: String? {
        switch self {
        case .sessionNotOpen(let sessionID):
            "MCP session \(sessionID) is closed."
        case .invalidStartReservation:
            "The MCP review start reservation is not owned by this session."
        case .invalidOperationToken:
            "The MCP operation token is not owned by this session."
        case .runNotFound(let runID):
            "Run \(runID.rawValue) was not found."
        }
    }
}

package actor MCPReviewSessionRegistry {
    package enum Phase: Sendable {
        case open
        case closing(
            reason: MCPReviewSessionCloseReason,
            completion: Task<MCPReviewSessionCloseReport, Never>
        )
        case closed(MCPReviewSessionCloseReport)
    }

    package struct SessionState: Sendable {
        package var phase: Phase
        package var members: Set<ReviewRunID>
        package var pendingStarts: Set<MCPReviewStartReservation>
        package var operations: Set<MCPSessionOperationToken>
        package var cancellationScheduled: Set<ReviewRunID>
        package var cancellationFinished: Set<ReviewRunID>
    }

    package enum BindDisposition: Equatable, Sendable {
        case bound
        case sessionClosing(MCPReviewSessionCloseReason)
    }

    private let closeStoreSession:
        @MainActor @Sendable (String) async -> MCPReviewSessionStoreCloseResult
    private let releaseStoreSession:
        @MainActor @Sendable (String) -> Void
    private var sessions: [String: SessionState] = [:]
    private var drainWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    package init(
        closeStoreSession: @escaping @MainActor @Sendable (String) async -> MCPReviewSessionStoreCloseResult,
        releaseStoreSession: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.closeStoreSession = closeStoreSession
        self.releaseStoreSession = releaseStoreSession
    }

    package func openSession(_ sessionID: String) {
        precondition(sessions[sessionID] == nil, "An MCP session identity can only be opened once.")
        sessions[sessionID] = SessionState(
            phase: .open,
            members: [],
            pendingStarts: [],
            operations: [],
            cancellationScheduled: [],
            cancellationFinished: []
        )
    }

    package func reserveStart(in sessionID: String) throws -> MCPReviewStartReservation {
        var state = try requireOpenSession(sessionID)
        let reservation = MCPReviewStartReservation(sessionID: sessionID, id: UUID())
        state.pendingStarts.insert(reservation)
        sessions[sessionID] = state
        return reservation
    }

    package func bind(
        runID: ReviewRunID,
        reservation: MCPReviewStartReservation
    ) throws -> BindDisposition {
        guard var state = sessions[reservation.sessionID],
              state.pendingStarts.remove(reservation) != nil else {
            throw MCPReviewSessionRegistryError.invalidStartReservation
        }

        state.members.insert(runID)
        let disposition: BindDisposition
        switch state.phase {
        case .open:
            disposition = .bound
        case .closing(let reason, _):
            state.cancellationScheduled.insert(runID)
            disposition = .sessionClosing(reason)
        case .closed(let report):
            disposition = .sessionClosing(report.reason)
        }
        sessions[reservation.sessionID] = state
        signalDrainIfNeeded(sessionID: reservation.sessionID)
        return disposition
    }

    package func finishStart(_ reservation: MCPReviewStartReservation) throws {
        guard var state = sessions[reservation.sessionID],
              state.pendingStarts.remove(reservation) != nil else {
            throw MCPReviewSessionRegistryError.invalidStartReservation
        }
        sessions[reservation.sessionID] = state
        signalDrainIfNeeded(sessionID: reservation.sessionID)
    }

    package func beginOperation(
        in sessionID: String,
        requiringMember runID: ReviewRunID? = nil
    ) throws -> MCPSessionOperationToken {
        var state = try requireOpenSession(sessionID)
        if let runID, state.members.contains(runID) == false {
            throw MCPReviewSessionRegistryError.runNotFound(runID)
        }
        let token = MCPSessionOperationToken(sessionID: sessionID, id: UUID())
        state.operations.insert(token)
        sessions[sessionID] = state
        return token
    }

    package func finishOperation(_ token: MCPSessionOperationToken) throws {
        guard var state = sessions[token.sessionID],
              state.operations.remove(token) != nil else {
            throw MCPReviewSessionRegistryError.invalidOperationToken
        }
        sessions[token.sessionID] = state
        signalDrainIfNeeded(sessionID: token.sessionID)
    }

    package func validateMember(
        _ runID: ReviewRunID,
        for operation: MCPSessionOperationToken
    ) throws {
        let state = try requireActiveOperation(operation)
        guard state.members.contains(runID) else {
            throw MCPReviewSessionRegistryError.runNotFound(runID)
        }
    }

    package func members(
        for operation: MCPSessionOperationToken
    ) throws -> Set<ReviewRunID> {
        try requireActiveOperation(operation).members
    }

    package func hasPendingWork(in sessionID: String) -> Bool {
        guard let state = sessions[sessionID] else {
            return false
        }
        return state.pendingStarts.isEmpty == false || state.operations.isEmpty == false
    }

    package func beginClose(
        _ sessionID: String,
        reason: MCPReviewSessionCloseReason
    ) -> Task<MCPReviewSessionCloseReport, Never> {
        guard var state = sessions[sessionID] else {
            let report = MCPReviewSessionCloseReport(
                sessionID: sessionID,
                reason: reason,
                members: [],
                cancellationScheduled: [],
                cancellationFinished: [],
                cancellationFailed: []
            )
            return Task { report }
        }

        switch state.phase {
        case .open:
            state.cancellationScheduled.formUnion(state.members)
            let completion = Task { [self] in
                await driveClose(sessionID: sessionID, reason: reason)
            }
            state.phase = .closing(reason: reason, completion: completion)
            sessions[sessionID] = state
            return completion
        case .closing(_, let completion):
            return completion
        case .closed(let report):
            return Task { report }
        }
    }

    package func removeClosedSession(_ sessionID: String) {
        guard let state = sessions[sessionID] else {
            return
        }
        guard case .closed = state.phase else {
            preconditionFailure("An MCP session can only be removed after close completes.")
        }
        precondition(drainWaiters[sessionID]?.isEmpty ?? true)
        drainWaiters.removeValue(forKey: sessionID)
        sessions.removeValue(forKey: sessionID)
    }

    package func stateForTesting(sessionID: String) -> SessionState? {
        sessions[sessionID]
    }

    package func sessionCountForTesting() -> Int {
        sessions.count
    }

    func registerMemberForTesting(_ runID: ReviewRunID, in sessionID: String) throws {
        var state = try requireOpenSession(sessionID)
        state.members.insert(runID)
        sessions[sessionID] = state
    }

    private func requireOpenSession(_ sessionID: String) throws -> SessionState {
        guard let state = sessions[sessionID], case .open = state.phase else {
            throw MCPReviewSessionRegistryError.sessionNotOpen(sessionID)
        }
        return state
    }

    private func requireActiveOperation(
        _ operation: MCPSessionOperationToken
    ) throws -> SessionState {
        guard let state = sessions[operation.sessionID],
              state.operations.contains(operation) else {
            throw MCPReviewSessionRegistryError.invalidOperationToken
        }
        return state
    }

    private func driveClose(
        sessionID: String,
        reason: MCPReviewSessionCloseReason
    ) async -> MCPReviewSessionCloseReport {
        let initialClose = await closeStoreSession(sessionID)
        await waitUntilDrained(sessionID: sessionID)
        // A reserved start can create and bind its run while the first close
        // call is suspended. Re-enter the store close boundary after every
        // reservation and operation has released so that late membership is
        // cancelled by the store owner before being reported as finished.
        let finalClose = await closeStoreSession(sessionID)

        guard var state = sessions[sessionID] else {
            preconditionFailure("The registry must retain a closing session until its driver completes.")
        }
        await releaseStoreSession(sessionID)
        state.cancellationScheduled.formUnion(state.members)
        let provenFinished = initialClose.terminalAndDrainedRunIDs
            .union(finalClose.terminalAndDrainedRunIDs)
            .intersection(state.cancellationScheduled)
        let reportedFailures = initialClose.failedRunIDs
            .union(finalClose.failedRunIDs)
            .union(state.cancellationScheduled.subtracting(provenFinished))
            .subtracting(provenFinished)
            .intersection(state.cancellationScheduled)
        state.cancellationFinished = provenFinished
        let report = MCPReviewSessionCloseReport(
            sessionID: sessionID,
            reason: reason,
            members: state.members,
            cancellationScheduled: state.cancellationScheduled,
            cancellationFinished: state.cancellationFinished,
            cancellationFailed: reportedFailures
        )
        state.phase = .closed(report)
        sessions[sessionID] = state
        return report
    }

    private func waitUntilDrained(sessionID: String) async {
        guard let state = sessions[sessionID],
              state.pendingStarts.isEmpty == false || state.operations.isEmpty == false else {
            return
        }
        await withCheckedContinuation { continuation in
            drainWaiters[sessionID, default: []].append(continuation)
        }
    }

    private func signalDrainIfNeeded(sessionID: String) {
        guard let state = sessions[sessionID],
              state.pendingStarts.isEmpty,
              state.operations.isEmpty else {
            return
        }
        let waiters = drainWaiters.removeValue(forKey: sessionID) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
