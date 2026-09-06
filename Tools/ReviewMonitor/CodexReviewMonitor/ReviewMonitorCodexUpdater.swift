import AppKit
import Foundation
import OSLog

private let codexUpdateLogger = Logger(
    subsystem: "CodexReviewMonitor",
    category: "codex-update"
)

@MainActor
final class ReviewMonitorCodexUpdater {
    typealias Check = @MainActor @Sendable () async throws -> CodexCommandUpdateCheckResult
    typealias Wait = @Sendable () async throws -> Void
    typealias PublishAvailability = @MainActor (Bool) -> Void
    typealias RunUpdate = @MainActor (CodexCommandUpdatePlan) async throws -> Void
    typealias ScheduleRelaunch = @MainActor (_ reportsFailure: Bool) throws -> Void
    typealias PresentFailure = @MainActor (_ title: String, _ message: String) -> Void

    private let check: Check
    private let wait: Wait
    private let publishAvailability: PublishAvailability
    private let prepareForUpdate: @MainActor () async -> Bool
    private let runUpdate: RunUpdate
    private let scheduleRelaunch: ScheduleRelaunch
    private let requestApplicationTermination: @MainActor () -> Void
    private let presentFailure: PresentFailure
    private var monitorTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var availablePlan: CodexCommandUpdatePlan?

    init(
        check: @escaping Check,
        wait: @escaping Wait = {
            try await Task.sleep(for: .seconds(20 * 60 * 60))
        },
        publishAvailability: @escaping PublishAvailability,
        prepareForUpdate: @escaping @MainActor () async -> Bool,
        runUpdate: @escaping RunUpdate = ReviewMonitorCodexUpdateProcess.run,
        scheduleRelaunch: @escaping ScheduleRelaunch = ReviewMonitorApplicationRelauncher.schedule,
        requestApplicationTermination: @escaping @MainActor () -> Void,
        presentFailure: @escaping PresentFailure
    ) {
        self.check = check
        self.wait = wait
        self.publishAvailability = publishAvailability
        self.prepareForUpdate = prepareForUpdate
        self.runUpdate = runUpdate
        self.scheduleRelaunch = scheduleRelaunch
        self.requestApplicationTermination = requestApplicationTermination
        self.presentFailure = presentFailure
    }

    func start() {
        startMonitoring(checkImmediately: true)
    }

    private func startMonitoring(checkImmediately: Bool) {
        guard monitorTask == nil, updateTask == nil else {
            return
        }
        monitorTask = Task { @MainActor [weak self] in
            await self?.monitorForUpdate(checkImmediately: checkImmediately)
            self?.monitorTask = nil
        }
    }

    func stopAndWait() async {
        let monitorTask = monitorTask
        let updateTask = updateTask
        monitorTask?.cancel()
        self.monitorTask = nil
        await monitorTask?.value
        await updateTask?.value
        let successorMonitorTask = self.monitorTask
        successorMonitorTask?.cancel()
        self.monitorTask = nil
        await successorMonitorTask?.value
    }

    func requestUpdate() {
        guard updateTask == nil,
              availablePlan != nil else {
            return
        }
        publishAvailability(false)
        let monitorTask = monitorTask
        monitorTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await monitorTask?.value
            let plan: CodexCommandUpdatePlan
            do {
                guard case .available(let currentPlan) = try await check() else {
                    availablePlan = nil
                    updateTask = nil
                    startMonitoring(checkImmediately: false)
                    return
                }
                plan = currentPlan
                availablePlan = currentPlan
            } catch {
                updateTask = nil
                publishAvailability(true)
                startMonitoring(checkImmediately: false)
                presentFailure(
                    "Codex Update Could Not Start",
                    "ReviewMonitor could not confirm that the Codex update is still available. \(error.localizedDescription)"
                )
                return
            }
            guard await prepareForUpdate() else {
                updateTask = nil
                publishAvailability(true)
                startMonitoring(checkImmediately: false)
                return
            }
            availablePlan = nil
            let updateFailure: (any Error)?
            do {
                try await runUpdate(plan)
                updateFailure = nil
            } catch {
                codexUpdateLogger.error(
                    "Codex update failed: \(error.localizedDescription, privacy: .public)"
                )
                updateFailure = error
            }
            do {
                try scheduleRelaunch(updateFailure != nil)
                updateTask = nil
                requestApplicationTermination()
            } catch {
                updateTask = nil
                if let updateFailure {
                    presentFailure(
                        "Codex Could Not Be Updated",
                        "\(updateFailure.localizedDescription) ReviewMonitor also could not schedule an automatic restart. Quit and reopen the app. \(error.localizedDescription)"
                    )
                } else {
                    presentFailure(
                        "ReviewMonitor Could Not Restart",
                        "Codex was updated, but ReviewMonitor could not restart automatically. Quit and reopen the app. \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func monitorForUpdate(checkImmediately: Bool) async {
        if checkImmediately == false {
            do {
                try await wait()
            } catch {
                return
            }
        }
        while Task.isCancelled == false, updateTask == nil {
            do {
                switch try await check() {
                case .disabled:
                    availablePlan = nil
                    publishAvailability(false)
                    return
                case .unavailable:
                    availablePlan = nil
                    publishAvailability(false)
                case .available(let plan):
                    availablePlan = plan
                    publishAvailability(true)
                }
            } catch is CancellationError {
                return
            } catch {
                codexUpdateLogger.error(
                    "Failed to check for Codex updates: \(error.localizedDescription, privacy: .public)"
                )
            }

            do {
                try await wait()
            } catch {
                return
            }
        }
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

@MainActor
enum ReviewMonitorApplicationRelauncher {
    nonisolated static let failedUpdateLaunchArgument = "--review-monitor-codex-update-failed"

    static func schedule(reportsFailure: Bool) throws {
        let applicationURL = Bundle.main.bundleURL.standardizedFileURL
        guard applicationURL.pathExtension == "app" else {
            throw ReviewMonitorApplicationRelaunchError.invalidApplicationBundle(
                applicationURL.path
            )
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = helperArguments(
            applicationURL: applicationURL,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            reportsFailure: reportsFailure
        )
        helper.environment = ProcessInfo.processInfo.environment
        helper.currentDirectoryURL = FileManager.default.temporaryDirectory
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    static func helperArguments(
        applicationURL: URL,
        processIdentifier: pid_t,
        reportsFailure: Bool
    ) -> [String] {
        [
            "-c",
            "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; if [ -n \"$3\" ]; then exec /usr/bin/open \"$2\" --args \"$3\"; else exec /usr/bin/open \"$2\"; fi",
            "reviewmonitor-relaunch",
            String(processIdentifier),
            applicationURL.path,
            reportsFailure ? failedUpdateLaunchArgument : "",
        ]
    }
}

private enum ReviewMonitorApplicationRelaunchError: LocalizedError {
    case invalidApplicationBundle(String)

    var errorDescription: String? {
        switch self {
        case .invalidApplicationBundle(let path):
            "ReviewMonitor cannot relaunch because its application bundle is invalid: \(path)"
        }
    }
}
