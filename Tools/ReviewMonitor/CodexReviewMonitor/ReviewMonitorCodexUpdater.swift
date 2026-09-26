import Foundation
import Observation
@_spi(ApplicationHostSupport) import CodexReview

@MainActor
@Observable
final class ReviewMonitorCodexUpdater {
    enum CheckState: Equatable {
        case notChecked
        case checking
        case available(CodexCommandUpdatePlan)
        case upToDate
        case unavailable(String)
        case failed(String)
    }

    typealias Check = @MainActor @Sendable () async throws -> CodexCommandUpdateCheckResult
    typealias RunUpdate = @MainActor @Sendable (CodexCommandUpdatePlan) async throws -> Void
    typealias ChooseTiming = @MainActor () async -> CodexReviewStore.CodexUpdateTiming?

    private(set) var checkState = CheckState.notChecked
    private(set) var lastCheckedAt: Date?
    let store: CodexReviewStore
    @ObservationIgnored private let check: Check
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let date: @MainActor () -> Date
    @ObservationIgnored private let sleepUntil: @MainActor (ContinuousClock.Instant) async throws -> Void
    @ObservationIgnored private let publishAvailability: @MainActor (Bool) -> Void
    @ObservationIgnored private let chooseTiming: ChooseTiming
    @ObservationIgnored private let runUpdate: RunUpdate
    @ObservationIgnored private let presentFailure: @MainActor (String, String) -> Void
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var checkTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var stopping = false

    init(
        store: CodexReviewStore,
        check: @escaping Check,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        date: @escaping @MainActor () -> Date = { .now },
        sleepUntil: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        },
        publishAvailability: @escaping @MainActor (Bool) -> Void,
        chooseTiming: @escaping ChooseTiming,
        runUpdate: @escaping RunUpdate = ReviewMonitorCodexUpdateProcess.run,
        presentFailure: @escaping @MainActor (String, String) -> Void
    ) {
        self.store = store
        self.check = check
        self.now = now
        self.date = date
        self.sleepUntil = sleepUntil
        self.publishAvailability = publishAvailability
        self.chooseTiming = chooseTiming
        self.runUpdate = runUpdate
        self.presentFailure = presentFailure
    }

    var isBusy: Bool { checkState == .checking || updateTask != nil }

    func start() {
        guard monitorTask == nil, stopping == false else { return }
        let origin = now()
        monitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while Task.isCancelled == false, stopping == false {
                // Every installation ends with one check, including requests due during it.
                if updateTask == nil { await performCheck() }
                guard Task.isCancelled == false, stopping == false else { return }
                let elapsed = max(0, origin.duration(to: now()).components.seconds)
                let nextSlot = elapsed / (8 * 60 * 60) + 1
                let deadline = origin.advanced(by: .seconds(nextSlot * 8 * 60 * 60))
                do { try await sleepUntil(deadline) } catch { return }
            }
        }
    }

    /// Stop read-only checking before Store shutdown cancels a deferred update or joins installation.
    func stopChecking() async {
        stopping = true
        monitorTask?.cancel()
        checkTask?.cancel()
        await checkTask?.value
        await monitorTask?.value
        monitorTask = nil
    }

    func checkForUpdates() async {
        guard stopping == false else { return }
        if let updateTask {
            await updateTask.value
            return
        }
        await performCheck()
    }

    @discardableResult
    func requestUpdate() -> Task<Void, Never>? {
        guard stopping == false else { return nil }
        if let updateTask { return updateTask }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { updateTask = nil }
            if case .failed = store.codexUpdateState, case .failed = store.serverState {
                await store.start()
                if stopping == false {
                    if case .failed(let message) = store.serverState {
                        presentFailure("Codex Could Not Restart", message)
                    }
                    await performCheck()
                }
                return
            }
            await performCheck()
            guard stopping == false else { return }
            switch checkState {
            case .failed(let message), .unavailable(let message):
                presentFailure("Codex Update Could Not Start", message)
                return
            default: break
            }
            guard case .available(let plan) = checkState,
                  let timing = await chooseTiming(), stopping == false else { return }
            do {
                let runUpdate = runUpdate
                try await store.updateCodex(when: timing) { try await runUpdate(plan) }
            } catch is CancellationError {
            } catch {
                if stopping == false {
                    presentFailure("Codex Could Not Be Updated", error.localizedDescription)
                }
            }
            if stopping == false { await performCheck() }
        }
        updateTask = task
        return task
    }

    private func performCheck() async {
        guard stopping == false else { return }
        if let checkTask {
            await checkTask.value
            return
        }
        let previousState = checkState
        checkState = .checking
        publishAvailability(false)
        let task = Task { @MainActor [self] in
            defer { checkTask = nil }
            do {
                let result = try await check()
                try Task.checkCancellation()
                switch result {
                case .available(let plan): checkState = .available(plan)
                case .upToDate: checkState = .upToDate
                case .unavailable(let message): checkState = .unavailable(message)
                }
                lastCheckedAt = date()
            } catch is CancellationError {
                checkState = previousState
            } catch {
                checkState = .failed(error.localizedDescription)
                lastCheckedAt = date()
            }
            if case .available = checkState { publishAvailability(true) }
            else { publishAvailability(false) }
        }
        checkTask = task
        await task.value
    }
}

private enum ReviewMonitorCodexUpdateProcess {
    @MainActor
    static func run(_ plan: CodexCommandUpdatePlan) async throws {
        // `codex update` owns a package mutation and only reports completion after
        // its package-manager child exits. Cancelling or timing it out would make
        // the installation state unknowable.
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = plan.executableURL
            process.arguments = ["update"]
            process.environment = plan.environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationReason == .exit,
                  process.terminationStatus == 0 else {
                throw ReviewMonitorCodexUpdateProcessError.failed(
                    status: process.terminationStatus,
                    reason: process.terminationReason
                )
            }
        }.value
    }
}

private enum ReviewMonitorCodexUpdateProcessError: LocalizedError {
    case failed(status: Int32, reason: Process.TerminationReason)

    var errorDescription: String? {
        switch self {
        case .failed(let status, let reason):
            "`codex update` terminated with status \(status) (\(reason))."
        }
    }
}
