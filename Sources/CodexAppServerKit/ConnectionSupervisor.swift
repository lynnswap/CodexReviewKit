import Foundation
import OSLog
import Synchronization

private let supervisorLogger = Logger(
    subsystem: "CodexAppServerKit",
    category: "connection-supervisor"
)

package final class ConnectionCloseAction: Sendable {
    private enum Request: Sendable {
        case close
        case fail(CodexTransportFailure)
    }

    private let action: Mutex<(@Sendable (Request) async -> Void)?>

    package init(action: (@Sendable () async -> Void)? = nil) {
        let wrappedAction: (@Sendable (Request) async -> Void)?
        if let action {
            wrappedAction = { _ in await action() }
        } else {
            wrappedAction = nil
        }
        self.action = Mutex(wrappedAction)
    }

    package func bind(to supervisor: ConnectionSupervisor) {
        action.withLock { action in
            precondition(action == nil, "Connection close action may be bound exactly once.")
            action = { [weak supervisor] request in
                guard let supervisor else {
                    preconditionFailure(
                        "Connection supervisor must outlive every client operation."
                    )
                }
                switch request {
                case .close:
                    await supervisor.closeConnection()
                case .fail(let failure):
                    await supervisor.failConnection(with: failure)
                }
            }
        }
    }

    package func closeConnection() async {
        guard let action = action.withLock({ $0 }) else {
            preconditionFailure("Connection close action is not bound.")
        }
        await action(.close)
    }

    package func failConnection(with failure: CodexTransportFailure) async {
        guard let action = action.withLock({ $0 }) else {
            preconditionFailure("Connection close action is not bound.")
        }
        await action(.fail(failure))
    }
}

package actor ConnectionSupervisor {
    private enum Phase: Equatable {
        case initialized
        case running
        case linearizingClose
        case closing
        case closed
    }

    private let connection: AppServerConnection
    private let connectionEventHub: ConnectionEventHub
    private var phase: Phase = .initialized
    private var routerTask: Task<Void, Never>?
    private var processExitTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var terminationArbiter = ConnectionTerminationArbiter()
    private var terminationWaiters:
        [CheckedContinuation<CodexConnectionTermination, Never>] = []

    package init(connection: AppServerConnection) {
        self.connection = connection
        self.connectionEventHub = connection.connectionEventHub
    }

    deinit {
        routerTask?.cancel()
        processExitTask?.cancel()
        closeTask?.cancel()
    }

    package func start() {
        guard phase == .initialized else {
            preconditionFailure("ConnectionSupervisor.start() may be called exactly once.")
        }
        phase = .running
        let connection = connection
        routerTask = Task { [weak self, connection] in
            await connection.runInboundEvents { [weak self] signal in
                await self?.recordExitSignal(signal)
            }
        }
        processExitTask = Task { [weak self, connection] in
            let observation = await connection.waitForProcessExit()
            guard Task.isCancelled == false else {
                return
            }
            switch observation {
            case .unavailable:
                return
            case .exited(let status, let observedBeforeTermination):
                await self?.recordExitSignal(.processExited(
                    status: status,
                    observedBeforeTermination: observedBeforeTermination
                ))
            case .failed(let failure):
                await self?.recordExitSignal(.transport(failure))
            }
        }
    }

    package func closeConnection() async {
        let completion = recordTermination(.init(.closedByCaller))
        if let context = ServerRequestTaskContext.value,
           await connection.signalCloseIfOwned(by: context) {
            return
        }
        await completion.value
    }

    package func failConnection(with failure: CodexTransportFailure) async {
        let completion = recordTermination(.init(.transportFailure(failure)))
        if let context = ServerRequestTaskContext.value,
           await connection.signalCloseIfOwned(by: context) {
            return
        }
        await completion.value
    }

    package func waitUntilClosed() async {
        guard let closeTask else {
            preconditionFailure("Connection close has not started.")
        }
        await closeTask.value
    }

    package func serverRequestChildCount() async -> Int {
        await connection.serverRequestChildCount()
    }

    package func terminationForTesting() -> CodexConnectionTermination? {
        terminationArbiter.winner
    }

    package func waitForTerminationForTesting() async -> CodexConnectionTermination {
        if let winner = terminationArbiter.winner {
            return winner
        }
        return await withCheckedContinuation { continuation in
            terminationWaiters.append(continuation)
        }
    }

    private func recordExitSignal(_ signal: ConnectionExitSignal) {
        _ = recordTermination(signal.terminationCandidate)
    }

    @discardableResult
    private func recordTermination(
        _ candidate: ConnectionTerminationArbiter.Candidate
    ) -> Task<Void, Never> {
        switch terminationArbiter.claim(candidate) {
        case .accepted:
            precondition(
                phase == .running,
                "Connection termination can start only from the running phase."
            )
            phase = .linearizingClose
            return startCloseTask()
        case .refined:
            guard let closeTask else {
                preconditionFailure("A provisional terminal must publish its close task atomically.")
            }
            return closeTask
        case .duplicate:
            guard let closeTask else {
                preconditionFailure("A provisional terminal must publish its close task atomically.")
            }
            return closeTask
        case .late(let winner, let candidate):
            if winner.termination != candidate.termination {
                connectionEventHub.yield(.warning(
                    ConnectionDiagnosticFactory.lateTermination(
                        winner: winner.termination,
                        candidate: candidate.termination
                    )
                ))
                supervisorLogger.debug(
                    "Ignoring late connection termination: \(String(describing: candidate.termination), privacy: .public); winner: \(String(describing: winner.termination), privacy: .public)"
                )
            }
            guard let closeTask else {
                preconditionFailure("A terminal reason must publish its close task atomically.")
            }
            return closeTask
        }
    }

    private func startCloseTask() -> Task<Void, Never> {
        if let closeTask {
            return closeTask
        }
        let connection = connection
        let task = Task { [weak self, connection] in
            let observedAtClose = await connection.beginClose()
            guard let self else {
                return
            }
            await self.commitAndRunFullClose(observedAtClose: observedAtClose)
        }
        closeTask = task
        return task
    }

    private func commitAndRunFullClose(
        observedAtClose: JSONRPC.ProcessExitObservation?
    ) async {
        let termination = terminationArbiter.commit(
            closeObservation: Self.closeObservation(observedAtClose)
        )
        let terminationWaiters = terminationWaiters
        self.terminationWaiters.removeAll(keepingCapacity: false)
        for waiter in terminationWaiters {
            waiter.resume(returning: termination)
        }
        phase = .closing
        await runFullClose(termination: termination)
    }

    private func runFullClose(termination: CodexConnectionTermination) async {
        await routerTask?.value
        await connection.finishPendingResponsesAfterInboundDrain(
            Self.pendingResponseFailure(for: termination)
        )
        await connection.cancelServerRequestsAndWait()
        let serverRequestChildCount = await connection.serverRequestChildCount()
        precondition(
            serverRequestChildCount == 0,
            "Server-request registry must be empty before domain termination."
        )
        await connection.finishDomains(with: termination)
        await connection.waitUntilTransportClosed()
        await processExitTask?.value
        await connection.reapProcess()
        phase = .closed
    }

    private nonisolated static func closeObservation(
        _ observation: JSONRPC.ProcessExitObservation?
    ) -> ConnectionTerminationArbiter.CloseObservation? {
        switch observation {
        case nil:
            nil
        case .unavailable:
            .unavailable
        case .exited(let status, let observedBeforeTermination):
            .exited(
                status: status,
                observedBeforeTermination: observedBeforeTermination
            )
        case .failed(let failure):
            .failed(failure)
        }
    }

    private nonisolated static func pendingResponseFailure(
        for termination: CodexConnectionTermination
    ) -> CodexTransportFailure {
        switch termination {
        case .closedByCaller:
            .closed
        case .transportFailure(let failure):
            failure
        case .processExited(let status):
            .io(
                errno: nil,
                message: status.map { "App-server process exited with status \($0)." }
                    ?? "App-server process exited."
            )
        }
    }
}

package final class AppServerConnectionLease: Sendable {
    private struct State {
        var supervisor: ConnectionSupervisor
        var processTerminationToken: ProcessTerminationToken
    }

    private let state: Mutex<State>

    package init(
        supervisor: ConnectionSupervisor,
        processTerminationToken: ProcessTerminationToken
    ) {
        self.state = Mutex(.init(
            supervisor: supervisor,
            processTerminationToken: processTerminationToken
        ))
    }

    deinit {
        state.withLock { state in
            state.processTerminationToken.terminateOnce()
        }
    }

    package func closeConnection() async {
        let supervisor = state.withLock { $0.supervisor }
        await supervisor.closeConnection()
    }

    package var supervisor: ConnectionSupervisor {
        state.withLock { $0.supervisor }
    }
}
