import Foundation

extension CodexReviewStore {
    @_spi(ApplicationHostSupport) public enum CodexUpdateTiming: Sendable {
        case afterCurrentReviews
        case immediately
    }

    @_spi(ApplicationHostSupport) public enum CodexUpdateState: Equatable, Sendable {
        case idle
        case waitingForReviews
        case stoppingRuntime
        case installing
        case restarting
        case failed(String)
    }

    /// Keeps MCP sessions and accepted jobs alive while replacing the Codex runtime.
    /// Concurrent callers join the existing operation; only its installation closure runs.
    /// An installation failure is thrown even when the runtime recovers and jobs resume.
    @_spi(ApplicationHostSupport) public func updateCodex(
        when timing: CodexUpdateTiming,
        install: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        if let task = codexUpdateTask {
            try await task.value
            return
        }
        guard applicationShutdownRequested == false else { throw CancellationError() }
        let previousAccountOperations = Array(runtimeAccountOperations.values)
        let previousRuntimeTask: Task<Void, Never>? = switch runtimeState {
        case .acquiring(_, _, let task), .replacing(_, let task), .tearingDown(_, _, _, _, let task): task
        case .running, .stopped, .failed: nil
        }
        suspendReviewStarts()
        codexUpdate = .waitingForReviews
        let task = Task { @MainActor [self] in
            defer {
                codexUpdateTask = nil
                if Task.isCancelled == false { resumeReviewsAfterCodexUpdateIfPossible() }
            }
            do {
                for operation in previousAccountOperations { _ = try? await operation.value }
                await previousRuntimeTask?.value
                try await performCodexUpdate(when: timing, install: install)
                codexUpdate = .idle
            } catch {
                if error is CancellationError {
                    codexUpdate = .idle
                } else {
                    codexUpdate = .failed(error.localizedDescription)
                }
                throw error
            }
        }
        codexUpdateTask = task
        try await task.value
    }

    private func performCodexUpdate(
        when timing: CodexUpdateTiming,
        install: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        // A dispatcher already saving an execution start belongs to the current batch.
        await queuedReviewDispatchTask?.value
        try Task.checkCancellation()
        if timing == .afterCurrentReviews {
            let executingIDs = jobs.filter {
                $0.isTerminal == false && queuedReviewStarts[$0.id] == nil
            }.map(\.id)
            for id in executingIDs {
                _ = try await awaitReview(sessionID: nil, jobID: id)
                try Task.checkCancellation()
            }
            _ = await drainReviewWorkersForRuntimeStop(timeout: backend.shutdownCleanupTimeout)
            try Task.checkCancellation()
        }
        guard applicationShutdownRequested == false else { throw CancellationError() }
        codexUpdate = .stoppingRuntime
        var installationFailure: String?
        let installation: @MainActor @Sendable () async -> Void = { [self] in
            codexUpdate = .installing
            do { try await install() } catch { installationFailure = error.localizedDescription }
            codexUpdate = .restarting
        }
        let operation: RuntimeStartOperation
        switch runtimeState {
        case .running(let generation, let runtime, let mcp):
            operation = admitRuntimeReplacement(
                sourceGeneration: generation, retiringRuntime: runtime, retainedMCP: mcp,
                preservingQueuedReviews: true,
                install: installation
            )
        case .failed(let generation, let mcp?, _):
            operation = admitRuntimeReplacement(
                sourceGeneration: generation, retiringRuntime: unclosedCodexUpdateRuntime, retainedMCP: mcp,
                preservingQueuedReviews: true,
                install: installation
            )
        case .stopped, .failed:
            try await closeUnclosedCodexUpdateRuntimeIfNeeded()
            await installation()
            guard let start = admitRuntimeStart(forceRestartIfNeeded: false) else { throw CancellationError() }
            operation = start
        case .acquiring, .replacing, .tearingDown:
            throw CodexReviewAPI.Error.io("The Codex runtime changed while waiting to update.")
        }
        await operation.task.value
        let failures = [installationFailure, serverState.failureMessage].compactMap { $0 }
        if failures.isEmpty == false {
            throw CodexReviewAPI.Error.io(failures.joined(separator: "; "))
        }
        guard case .running = runtimeState else {
            throw CodexReviewAPI.Error.io("Codex update finished without an available runtime.")
        }
    }

    package func resumeReviewsAfterCodexUpdateIfPossible() {
        guard runtimeAccountOperations.isEmpty, applicationShutdownRequested == false,
              case .running = runtimeState else { return }
        resumeReviewStarts()
    }

    package func performRuntimeAuthentication(
        _ operation: @escaping @MainActor @Sendable (CodexReviewStore) async -> Void
    ) async {
        do { try await performRuntimeAccountChange { store in await operation(store) } }
        catch is CancellationError { }
        catch { auth.updatePhase(.failed(message: error.localizedDescription)) }
    }

    package func performRuntimeAccountChange(
        _ operation: @escaping @MainActor @Sendable (CodexReviewStore) async throws -> Void
    ) async throws {
        let update = codexUpdateTask
        let id = UUID()
        let task = Task { @MainActor [self] in
            _ = try? await update?.value
            defer {
                runtimeAccountOperations.removeValue(forKey: id)
                if codexUpdateTask == nil { resumeReviewsAfterCodexUpdateIfPossible() }
            }
            try Task.checkCancellation()
            guard applicationShutdownRequested == false else { throw CancellationError() }
            try await operation(self)
        }
        runtimeAccountOperations[id] = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    package var hasQueuedCodexUpdateRecovery: Bool {
        if case .failed = codexUpdateState { return reviewStartsAreSuspended }
        return false
    }
}
