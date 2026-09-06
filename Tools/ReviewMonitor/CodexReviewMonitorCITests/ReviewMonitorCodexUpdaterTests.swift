import Foundation
import Testing
@_spi(ApplicationHostSupport) import CodexReviewHost
@testable import CodexReviewMonitor

@Suite("ReviewMonitor Codex updater", .serialized)
@MainActor
struct ReviewMonitorCodexUpdaterTests {
    @Test func checksAtLaunchAndAgainAfterTheSchedule() async {
        let plan = updatePlan()
        var results: [CodexCommandUpdateCheckResult] = [
            .unavailable,
            .available(plan),
        ]
        var checkCount = 0
        var publishedAvailability: [Bool] = []
        let available = TestSignal()
        let waitCount = UpdateTestCounter()
        let updater = ReviewMonitorCodexUpdater(
            check: {
                checkCount += 1
                return results.removeFirst()
            },
            wait: {
                await waitCount.increment()
            },
            publishAvailability: { value in
                publishedAvailability.append(value)
                if value {
                    Task { await available.signal() }
                }
            },
            prepareForUpdate: {},
            requestApplicationTermination: {},
            presentFailure: { _, _ in }
        )

        updater.start()
        await available.wait()

        #expect(checkCount == 2)
        #expect(await waitCount.value == 1)
        #expect(publishedAvailability == [false, true])
    }

    @Test func disabledCheckStopsWithoutSchedulingAnotherCheck() async {
        let checkCompleted = TestSignal()
        let waitCount = UpdateTestCounter()
        let updater = ReviewMonitorCodexUpdater(
            check: { .disabled },
            wait: {
                await waitCount.increment()
            },
            publishAvailability: { _ in
                Task { await checkCompleted.signal() }
            },
            prepareForUpdate: {},
            requestApplicationTermination: {},
            presentFailure: { _, _ in }
        )

        updater.start()
        await checkCompleted.wait()
        await Task.yield()

        #expect(await waitCount.value == 0)
    }

    @Test func acceptedUpdateSchedulesOneHelperBeforeRequestingTermination() async {
        let plan = updatePlan()
        let available = TestSignal()
        var publishedAvailability: [Bool] = []
        var preparedUpdateCount = 0
        var updatedPlans: [CodexCommandUpdatePlan] = []
        var scheduledFailureValues: [Bool] = []
        var terminationRequestCount = 0
        let terminationRequested = TestSignal()
        let updater = ReviewMonitorCodexUpdater(
            check: { .available(plan) },
            publishAvailability: { value in
                publishedAvailability.append(value)
                if value {
                    Task { await available.signal() }
                }
            },
            prepareForUpdate: { preparedUpdateCount += 1 },
            runUpdate: { updatedPlans.append($0) },
            scheduleRelaunch: { scheduledFailureValues.append($0) },
            requestApplicationTermination: {
                terminationRequestCount += 1
                Task { await terminationRequested.signal() }
            },
            presentFailure: { _, _ in }
        )
        updater.start()
        await available.wait()

        updater.requestUpdate()
        updater.requestUpdate()
        await terminationRequested.wait()

        #expect(preparedUpdateCount == 1)
        #expect(updatedPlans == [plan])
        #expect(scheduledFailureValues == [false])
        #expect(terminationRequestCount == 1)
        #expect(publishedAvailability == [true, false])
    }

    @Test func updateAndRelaunchFailuresPreserveThePrimaryUpdateError() async {
        let plan = updatePlan()
        let available = TestSignal()
        var publishedAvailability: [Bool] = []
        var terminationRequestCount = 0
        var failures: [(String, String)] = []
        let failurePresented = TestSignal()
        let updater = ReviewMonitorCodexUpdater(
            check: { .available(plan) },
            publishAvailability: { value in
                publishedAvailability.append(value)
                if value, publishedAvailability.count == 1 {
                    Task { await available.signal() }
                }
            },
            prepareForUpdate: {},
            runUpdate: { _ in throw UpdateTestFailure.injected },
            scheduleRelaunch: { _ in throw UpdateTestFailure.injected },
            requestApplicationTermination: {
                terminationRequestCount += 1
            },
            presentFailure: {
                failures.append(($0, $1))
                Task { await failurePresented.signal() }
            }
        )
        updater.start()
        await available.wait()

        updater.requestUpdate()
        await failurePresented.wait()

        #expect(terminationRequestCount == 0)
        #expect(publishedAvailability == [true, false])
        #expect(failures.count == 1)
        #expect(failures.first?.0 == "Codex Could Not Be Updated")
        #expect(failures.first?.1.contains("also could not schedule") == true)
    }

    @Test func updateFailureIsReportedToTheRelaunchedApplication() async {
        let plan = updatePlan()
        let available = TestSignal()
        let terminationRequested = TestSignal()
        var scheduledFailureValues: [Bool] = []
        let updater = ReviewMonitorCodexUpdater(
            check: { .available(plan) },
            publishAvailability: { value in
                if value {
                    Task { await available.signal() }
                }
            },
            prepareForUpdate: {},
            runUpdate: { _ in throw UpdateTestFailure.injected },
            scheduleRelaunch: { scheduledFailureValues.append($0) },
            requestApplicationTermination: {
                Task { await terminationRequested.signal() }
            },
            presentFailure: { _, _ in }
        )
        updater.start()
        await available.wait()

        updater.requestUpdate()
        await terminationRequested.wait()

        #expect(scheduledFailureValues == [true])
    }

    @Test func applicationTerminationWaitsForAnUncancelledUpdate() async {
        let plan = updatePlan()
        let available = TestSignal()
        let updateStarted = TestSignal()
        let releaseUpdate = TestGate()
        let stopCompleted = UpdateTestCounter()
        var updateObservedCancellation: [Bool] = []
        let updater = ReviewMonitorCodexUpdater(
            check: { .available(plan) },
            publishAvailability: { value in
                if value {
                    Task { await available.signal() }
                }
            },
            prepareForUpdate: {},
            runUpdate: { _ in
                await updateStarted.signal()
                await releaseUpdate.wait()
                updateObservedCancellation.append(Task.isCancelled)
            },
            scheduleRelaunch: { _ in },
            requestApplicationTermination: {},
            presentFailure: { _, _ in }
        )
        updater.start()
        await available.wait()
        updater.requestUpdate()
        await updateStarted.wait()

        let stop = Task { @MainActor in
            await updater.stopAndWait()
            await stopCompleted.increment()
        }
        await Task.yield()
        #expect(await stopCompleted.value == 0)

        await releaseUpdate.open()
        await stop.value
        #expect(updateObservedCancellation == [false])
    }

    @Test func helperWaitsForThisAppThenRelaunchesWithTheResult() {
        let applicationURL = URL(fileURLWithPath: "/Applications/ReviewMonitor.app")

        let arguments = ReviewMonitorApplicationRelauncher.helperArguments(
            applicationURL: applicationURL,
            processIdentifier: 42,
            reportsFailure: true
        )

        #expect(arguments[0] == "-c")
        #expect(arguments[2...] == [
            "reviewmonitor-relaunch",
            "42",
            applicationURL.path,
            ReviewMonitorApplicationRelauncher.failedUpdateLaunchArgument,
        ])
        #expect(arguments[1].contains("/usr/bin/open \"$2\""))
    }

    @Test func failedUpdateRelaunchArgumentIsRecognizedByLaunchContext() {
        let context = ReviewMonitorLaunchContext(
            environment: [:],
            arguments: [
                "ReviewMonitor",
                ReviewMonitorApplicationRelauncher.failedUpdateLaunchArgument,
            ],
            launchMode: .application
        )

        #expect(context.reportsFailedCodexUpdate)
    }

    private func updatePlan() -> CodexCommandUpdatePlan {
        CodexCommandUpdatePlan(
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]
        )
    }
}

private enum UpdateTestFailure: Error {
    case injected
}

private actor UpdateTestCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
