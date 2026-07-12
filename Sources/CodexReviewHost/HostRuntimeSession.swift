import Foundation
import OSLog
import CodexAppServerKit
import CodexDataKit
import CodexReviewKit
import CodexReviewAppServer

private let logger = Logger(subsystem: "CodexReviewKit", category: "live-store-backend")

struct HostRuntimeConsumerFailure: Error, LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
struct AppServerRuntime: Sendable {
    var appServer: CodexAppServer
    var modelContainer: CodexModelContainer
    var backend: AppServerCodexReviewBackend
}

struct HostRuntimeStopResult: Sendable {
    var didReleaseResources: Bool
    var didRetireRuns: Bool
    var primaryAuthenticationHandoff: PrimaryAuthenticationReconciliationHandoff?
}

enum RuntimeAccountObservation: Equatable, Sendable {
    case signedOut
    case account(
        accountKey: String,
        provider: ExpectedRuntimeAccount.Provider
    )
    case invalid

    var exactExpectation: ExpectedRuntimeAccount? {
        switch self {
        case .signedOut:
            .signedOut
        case .account(let accountKey, let provider):
            .observedAccount(accountKey: accountKey, provider: provider)
        case .invalid:
            nil
        }
    }
}

struct RuntimeAccountObservationAuthorization: Equatable, Sendable {
    let generation: UInt64
    let revision: UInt64
    let observation: RuntimeAccountObservation
}

@MainActor
final class HostRuntimeSession {
    enum Phase {
        case staging
        case active
        case stopping
        case stopIncomplete
        case stopped
    }

    let generation: UInt64

    private(set) var phase: Phase = .staging
    private(set) var runtime: AppServerRuntime?
    private(set) var mcpHTTPServer: (any CodexReviewMCPHTTPServing)?
    private(set) var accountEvents: CodexAccountEvents?
    private(set) var accountConsumerTask: Task<Void, Never>?
    private(set) var connectionEvents: CodexConnectionEvents?
    private(set) var connectionConsumerTask: Task<Void, Never>?
    private(set) var stopTask: Task<HostRuntimeStopResult, Never>?
    private(set) var shouldRetireRuns = false
    private(set) var accountObservation: RuntimeAccountObservation?
    private(set) var accountObservationRevision: UInt64?
    private(set) var accountInvalidationRevision: UInt64 = 0

    private let lifecycleHandler: CodexReviewAppServerLifecycleHandler?
    private let finalRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim?
    private var didPublishLifecycle = false
    private var admissionOpen = false
    private var stagingFailure: HostRuntimeConsumerFailure?
    private var didConsumePrimaryAuthenticationHandoff = false
    private var pendingPrimaryAuthenticationHandoff: PrimaryAuthenticationReconciliationHandoff?
    private var finalRetirementClaimTask: Task<Void, Never>?

    init(
        generation: UInt64,
        lifecycleHandler: CodexReviewAppServerLifecycleHandler?,
        finalRetirementDidClaim: CodexReviewFinalRuntimeRetirementDidClaim?
    ) {
        self.generation = generation
        self.lifecycleHandler = lifecycleHandler
        self.finalRetirementDidClaim = finalRetirementDidClaim
    }

    var activeRuntime: AppServerRuntime? {
        guard case .active = phase, admissionOpen else {
            return nil
        }
        return runtime
    }

    var activeMCPHTTPServer: (any CodexReviewMCPHTTPServing)? {
        guard case .active = phase, admissionOpen else {
            return nil
        }
        return mcpHTTPServer
    }

    var isActive: Bool {
        if case .active = phase, admissionOpen {
            return true
        }
        return false
    }

    var hasCurrentAccountObservation: Bool {
        isActive
            && accountObservation != nil
            && accountObservationRevision == accountInvalidationRevision
    }

    func installRuntime(_ runtime: AppServerRuntime) {
        precondition(self.runtime == nil, "A Host runtime session can install its app-server runtime only once.")
        precondition(isStaging, "An app-server runtime can be installed only while staging.")
        self.runtime = runtime
    }

    func installMCPHTTPServer(_ server: any CodexReviewMCPHTTPServing) {
        precondition(mcpHTTPServer == nil, "A Host runtime session can install its MCP server only once.")
        precondition(isStaging, "An MCP server can be installed only while staging.")
        mcpHTTPServer = server
    }

    func recordAccountObservation(
        _ observation: RuntimeAccountObservation,
        revision: UInt64
    ) {
        precondition(accountObservation == nil, "A Host runtime generation validates its account snapshot only once.")
        precondition(isStaging, "A runtime account observation belongs to staging validation.")
        precondition(
            revision == accountInvalidationRevision,
            "A staging runtime can publish only its latest account observation."
        )
        accountObservation = observation
        accountObservationRevision = revision
    }

    func updateAccountObservation(
        _ observation: RuntimeAccountObservation,
        revision: UInt64
    ) {
        precondition(isActive, "Only an active runtime can update its account observation.")
        precondition(
            revision == accountInvalidationRevision,
            "An active runtime can publish only its latest account observation."
        )
        accountObservation = observation
        accountObservationRevision = revision
    }

    func recordAccountInvalidation() {
        precondition(
            accountInvalidationRevision < .max,
            "A Host runtime account invalidation revision must not wrap."
        )
        accountInvalidationRevision += 1
    }

    func authorizeRateLimitObservation(
        for account: CodexReviewAccount
    ) -> RuntimeAccountObservationAuthorization? {
        guard isActive,
              let accountObservationRevision,
              accountObservationRevision == accountInvalidationRevision else {
            return nil
        }
        let expectedObservation = RuntimeAccountObservation.account(
            accountKey: account.accountKey,
            provider: .init(account.kind)
        )
        guard accountObservation == expectedObservation else {
            return nil
        }
        return .init(
            generation: generation,
            revision: accountObservationRevision,
            observation: expectedObservation
        )
    }

    func validatesRateLimitObservation(
        _ authorization: RuntimeAccountObservationAuthorization
    ) -> Bool {
        isActive
            && authorization.generation == generation
            && authorization.revision == accountInvalidationRevision
            && authorization.revision == accountObservationRevision
            && authorization.observation == accountObservation
    }

    func installConsumers(
        accountEvents: CodexAccountEvents,
        connectionEvents: CodexConnectionEvents,
        accountEventSink: @escaping @MainActor @Sendable (CodexAccountEvent) async -> Void,
        exitSink: @escaping @MainActor @Sendable (HostRuntimeConsumerFailure) async -> Void
    ) {
        precondition(
            self.accountEvents == nil && accountConsumerTask == nil
                && self.connectionEvents == nil && connectionConsumerTask == nil,
            "A Host runtime session can install its event consumers only once."
        )
        precondition(isStaging, "Runtime consumers can be installed only while staging.")
        self.accountEvents = accountEvents
        accountConsumerTask = Task { @MainActor in
            do {
                for try await event in accountEvents {
                    await accountEventSink(event)
                }
                if Task.isCancelled == false {
                    await exitSink(.init(message: "The Codex account event stream ended unexpectedly."))
                }
            } catch is CancellationError {
            } catch {
                logger.error("Auth notification stream ended: \(error.localizedDescription, privacy: .public)")
                await exitSink(.init(message: error.localizedDescription))
            }
        }
        self.connectionEvents = connectionEvents
        connectionConsumerTask = Task { @MainActor in
            for await event in connectionEvents {
                switch event {
                case .warning(let diagnostic):
                    logger.warning("App-server warning: \(diagnostic.message, privacy: .public)")
                case .retrying(let diagnostic):
                    logger.warning("App-server retrying \(diagnostic.method, privacy: .public) attempt \(diagnostic.attempt, privacy: .public)")
                case .deprecation(let notice):
                    logger.warning("App-server deprecation: \(notice.summary, privacy: .public)")
                case .unknown:
                    logger.debug("Unknown app-server notification")
                case .terminated(let termination):
                    await exitSink(.init(message: Self.failureMessage(for: termination)))
                    return
                }
            }
            if Task.isCancelled == false {
                await exitSink(.init(message: "The Codex connection event stream ended unexpectedly."))
            }
        }
    }

    func commit() {
        precondition(isStaging, "Only a staged Host runtime session can become active.")
        guard let modelContainer = runtime?.modelContainer else {
            preconditionFailure("A Host runtime session requires a model container before publication.")
        }
        phase = .active
        admissionOpen = true
        didPublishLifecycle = true
        lifecycleHandler?(modelContainer)
    }

    func recordStagingFailure(_ failure: HostRuntimeConsumerFailure) {
        guard isStaging, stagingFailure == nil else {
            return
        }
        stagingFailure = failure
    }

    func requireHealthyStaging() throws {
        guard isStaging else {
            throw HostRuntimeConsumerFailure(message: "The Host runtime staging generation was superseded.")
        }
        if let stagingFailure {
            throw stagingFailure
        }
    }

    func beginStopping() {
        switch phase {
        case .staging, .active, .stopIncomplete:
            phase = .stopping
        case .stopping, .stopped:
            return
        }
        closeAdmission()
    }

    func closeAdmission() {
        admissionOpen = false
        if didPublishLifecycle {
            didPublishLifecycle = false
            lifecycleHandler?(nil)
        }
    }

    func cancelConsumersAndWait() async {
        await connectionEvents?.cancel()
        await accountEvents?.cancel()
        connectionConsumerTask?.cancel()
        accountConsumerTask?.cancel()
        await connectionConsumerTask?.value
        await accountConsumerTask?.value
        connectionEvents = nil
        connectionConsumerTask = nil
        accountEvents = nil
        accountConsumerTask = nil
    }

    func waitForStopCompletion() async -> HostRuntimeStopResult? {
        guard let stopTask else {
            return nil
        }
        return await stopTask.value
    }

    func waitForFinalRetirementClaim() async {
        await finalRetirementClaimTask?.value
    }

    func takePrimaryAuthenticationHandoff(
        from result: HostRuntimeStopResult
    ) -> PrimaryAuthenticationReconciliationHandoff? {
        guard didConsumePrimaryAuthenticationHandoff == false else {
            return nil
        }
        let handoff = pendingPrimaryAuthenticationHandoff ?? result.primaryAuthenticationHandoff
        guard let handoff else { return nil }
        didConsumePrimaryAuthenticationHandoff = true
        pendingPrimaryAuthenticationHandoff = nil
        return handoff
    }

    func retainPrimaryAuthenticationHandoffForStop(
        _ handoff: PrimaryAuthenticationReconciliationHandoff?
    ) {
        guard let handoff else { return }
        guard pendingPrimaryAuthenticationHandoff == nil else {
            preconditionFailure("A Host runtime session can retain only one primary authentication handoff.")
        }
        pendingPrimaryAuthenticationHandoff = handoff
    }

    func finishStopping(didReleaseResources: Bool) {
        precondition(stopTask == nil, "The shared stop task must clear itself before stop completion is published.")
        if didReleaseResources {
            runtime = nil
            mcpHTTPServer = nil
            accountEvents = nil
            accountConsumerTask = nil
            connectionEvents = nil
            connectionConsumerTask = nil
            accountObservation = nil
            accountObservationRevision = nil
            phase = .stopped
        } else {
            phase = .stopIncomplete
        }
    }

    func requestStop(
        purpose: CodexReviewRuntimeStopPurpose,
        _ operation: @escaping @MainActor @Sendable (HostRuntimeSession) async -> HostRuntimeStopResult
    ) -> Task<HostRuntimeStopResult, Never>? {
        if purpose.retiresRuns, shouldRetireRuns == false {
            shouldRetireRuns = true
            let finalRetirementDidClaim = finalRetirementDidClaim
            finalRetirementClaimTask = Task { @MainActor in
                await finalRetirementDidClaim?()
            }
        }
        if let stopTask {
            return stopTask
        }
        switch phase {
        case .stopped:
            return nil
        case .stopping:
            preconditionFailure("A stopping Host runtime session must retain its shared stop completion.")
        case .staging, .active, .stopIncomplete:
            break
        }
        beginStopping()
        let task: Task<HostRuntimeStopResult, Never> = Task { @MainActor [weak self] in
            guard let self else {
                return .init(
                    didReleaseResources: true,
                    didRetireRuns: false,
                    primaryAuthenticationHandoff: nil
                )
            }
            await self.finalRetirementClaimTask?.value
            let result = await operation(self)
            self.stopTask = nil
            self.finishStopping(didReleaseResources: result.didReleaseResources)
            return result
        }
        stopTask = task
        return task
    }

    var isStaging: Bool {
        if case .staging = phase {
            return true
        }
        return false
    }

    private nonisolated static func failureMessage(
        for termination: CodexConnectionTermination
    ) -> String {
        switch termination {
        case .closedByCaller:
            "The Codex app-server connection was closed by the caller."
        case .transportFailure(let failure):
            failure.localizedDescription
        case .processExited(let status):
            if let status {
                "The Codex app-server process exited with status \(status)."
            } else {
                "The Codex app-server process exited."
            }
        }
    }
}
