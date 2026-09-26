import Foundation
import AppKit
import SwiftUI
import CodexReviewHost
import Testing
@_spi(ApplicationHostSupport) import CodexReview
@_spi(PreviewSupport) import ReviewUI
@testable import CodexReviewMonitor

@Suite("ReviewMonitor Codex updater", .serialized)
@MainActor
struct ReviewMonitorCodexUpdaterTests {
    @Test func launchAndEightHourChecksStayAnchoredAcrossManualChecks() async {
        let clock = UpdateTestClock()
        var checks = 0
        let updater = makeUpdater(clock: clock, check: { checks += 1; return .upToDate })
        updater.start()
        updater.start()
        #expect(await waitUntil { checks == 1 && clock.waiterCount == 1 })
        clock.advance(by: .seconds(3 * 3600))
        await updater.checkForUpdates()
        #expect(checks == 2)
        clock.advance(by: .seconds(5 * 3600))
        #expect(await waitUntil { checks == 3 && clock.deadlines.last == 16 * 3600 })
        clock.advance(by: .seconds(8 * 3600))
        #expect(await waitUntil { checks == 4 && clock.deadlines.last == 24 * 3600 })
        let expectedDeadlines: [Int64] = [8 * 3600, 16 * 3600, 24 * 3600]
        #expect(clock.deadlines == expectedDeadlines)
        await updater.stopChecking()
        #expect(clock.waiterCount == 0)
    }

    @Test func wakingAfterSeveralIntervalsChecksOnce() async {
        let clock = UpdateTestClock()
        var checks = 0
        let updater = makeUpdater(clock: clock, check: { checks += 1; return .upToDate })
        updater.start()
        #expect(await waitUntil { checks == 1 && clock.waiterCount == 1 })
        clock.advance(by: .seconds(26 * 3600))
        #expect(await waitUntil { checks == 2 && clock.deadlines.last == 32 * 3600 })
        await updater.stopChecking()
        #expect(checks == 2)
    }

    @Test func manualAndAutomaticChecksJoinTheSameRequest() async {
        let clock = UpdateTestClock()
        let entered = TestSignal()
        let release = TestGate()
        var checks = 0
        let updater = makeUpdater(clock: clock, check: {
            checks += 1
            await entered.signal()
            await release.wait()
            return .upToDate
        })
        let manual = Task { await updater.checkForUpdates() }
        await entered.wait()
        let second = Task { await updater.checkForUpdates() }
        updater.start()
        await release.open()
        await manual.value
        await second.value
        #expect(await waitUntil { clock.waiterCount == 1 })
        #expect(checks == 1)
        #expect(updater.checkState == .upToDate)
        await updater.stopChecking()
    }

    @Test func updateKeepsTheStoreAliveAndCoalescesChecksUntilInstallationFinishes() async throws {
        let clock = UpdateTestClock()
        let store = ReviewMonitorUpdatePreview().store
        await store.start()
        let plan = updatePlan()
        var checks = 0
        var installations = 0
        let entered = TestSignal()
        let release = TestGate()
        let updater = makeUpdater(store: store, clock: clock, check: {
            checks += 1
            return checks <= 2 ? .available(plan) : .upToDate
        }, runUpdate: { received in
            #expect(received == plan)
            installations += 1
            await entered.signal()
            await release.wait()
        })
        updater.start()
        #expect(await waitUntil { checks == 1 && clock.waiterCount == 1 })
        let update = try #require(updater.requestUpdate())
        await entered.wait()
        let duplicate = try #require(updater.requestUpdate())
        let manual = Task { await updater.checkForUpdates() }
        clock.advance(by: .seconds(8 * 3600))
        #expect(await waitUntil { clock.deadlines.last == 16 * 3600 })
        #expect(checks == 2)
        await release.open()
        await update.value
        await duplicate.value
        await manual.value
        #expect(installations == 1)
        #expect(checks == 3)
        #expect(updater.checkState == .upToDate)
        #expect(store.serverState == .running)
        #expect(store.codexUpdateState == .idle)
        await updater.stopChecking()
        await store.shutdown()
    }

    @Test func stoppingChecksDoesNotWaitForAnUpdateThatStoreShutdownOwns() async throws {
        let store = ReviewMonitorUpdatePreview().store
        await store.start()
        let entered = TestSignal()
        let release = TestGate()
        var observedCancellation = false
        let updater = makeUpdater(store: store, check: { .available(updatePlan()) }, runUpdate: { _ in
            await entered.signal()
            await release.wait()
            observedCancellation = Task.isCancelled
        })
        let update = try #require(updater.requestUpdate())
        await entered.wait()
        await updater.stopChecking()
        var stopped = false
        let shutdown = Task { await store.shutdown(); stopped = true }
        await Task.yield()
        #expect(stopped == false)
        await release.open()
        await update.value
        await shutdown.value
        #expect(observedCancellation == false)
        #expect(store.serverState == .stopped)
    }

    @Test func checkResultsAndAttemptTimeDistinguishFailureAndUnsupportedInstallations() async {
        let clock = UpdateTestClock()
        var checks = 0
        let updater = makeUpdater(clock: clock, check: {
            checks += 1
            if checks == 1 { throw UpdateTestFailure.offline }
            if checks == 2 { return .unavailable("Manual installation") }
            return .upToDate
        })
        await updater.checkForUpdates()
        #expect(updater.checkState == .failed("Offline"))
        #expect(updater.lastCheckedAt == clock.date)
        clock.advance(by: .seconds(5))
        await updater.checkForUpdates()
        #expect(updater.checkState == .unavailable("Manual installation"))
        #expect(updater.lastCheckedAt == clock.date)
        await updater.checkForUpdates()
        #expect(updater.checkState == .upToDate)
        await updater.stopChecking()
    }

    @Test func updateFailureKeepsItsStoreErrorAndReportsItWithoutRelaunching() async throws {
        let store = ReviewMonitorUpdatePreview().store
        await store.start()
        var failures: [String] = []
        let updater = makeUpdater(store: store, check: { .available(updatePlan()) },
            runUpdate: { _ in throw UpdateTestFailure.offline },
            presentFailure: { _, message in failures.append(message) })
        await updater.requestUpdate()?.value
        #expect(failures == ["Offline"])
        #expect(store.codexUpdateState == .failed("Offline"))
        #expect(store.serverState == .running)
        await updater.stopChecking()
        await store.shutdown()
    }

    @Test func updateAlertOffersDeferredAndImmediateChoices() {
        let alert = ReviewMonitorAppDelegate.makeCodexUpdateAlert()
        #expect(alert.buttons.map(\.title) == ["Update After Reviews", "Stop Reviews and Update"])
        #expect(alert.buttons[1].hasDestructiveAction)
    }

    @Test func settingsPaneSharesTheUpdaterAndDoesNotStartCheckingOnOpen() {
        var checks = 0
        let updater = makeUpdater(check: { checks += 1; return .upToDate })
        let controller = ReviewMonitorSettingsWindowController(
            runtimePreferencesStore: CodexReviewRuntime.UserDefaultsPreferencesStore(),
            updater: updater
        )
        let tabs = controller.contentViewController as? NSTabViewController
        #expect(tabs?.tabViewItems.map(\.label) == ["Runtime", "Updates"])
        let pane = tabs?.tabViewItems.last?.viewController as? ReviewMonitorUpdateSettingsViewController
        #expect(pane?.rootView.updater === updater)
        #expect(checks == 0)
    }

    @Test func explicitUpdateReportsCheckFailureWithoutInstalling() async {
        var failures: [String] = []
        var installations = 0
        let updater = makeUpdater(check: { throw UpdateTestFailure.offline },
            runUpdate: { _ in installations += 1 },
            presentFailure: { _, message in failures.append(message) })
        await updater.requestUpdate()?.value
        #expect(installations == 0)
        #expect(failures == ["Offline"])
        #expect(updater.checkState == .failed("Offline"))
        await updater.stopChecking()
    }

    @Test func retryRecoversTheRuntimeWithoutInstallingAgain() async {
        let preview = ReviewMonitorUpdatePreview()
        await preview.run(.failed)
        var installations = 0
        let updater = makeUpdater(store: preview.store, check: { .upToDate },
            runUpdate: { _ in installations += 1 })
        await updater.requestUpdate()?.value
        #expect(installations == 0)
        #expect(preview.store.serverState == .running)
        await updater.stopChecking()
        await preview.stop()
    }

    private func makeUpdater(
        store: CodexReviewStore? = nil,
        clock: UpdateTestClock = UpdateTestClock(),
        check: @escaping ReviewMonitorCodexUpdater.Check,
        runUpdate: @escaping ReviewMonitorCodexUpdater.RunUpdate = { _ in },
        presentFailure: @escaping @MainActor (String, String) -> Void = { _, _ in }
    ) -> ReviewMonitorCodexUpdater {
        ReviewMonitorCodexUpdater(
            store: store ?? ReviewMonitorUpdatePreview().store,
            check: check,
            now: { clock.instant },
            date: { clock.date },
            sleepUntil: { try await clock.sleep(until: $0) },
            publishAvailability: { _ in },
            chooseTiming: { .afterCurrentReviews },
            runUpdate: runUpdate,
            presentFailure: presentFailure
        )
    }

    private func updatePlan() -> CodexCommandUpdatePlan {
        .init(executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), environment: [:])
    }
}

private enum UpdateTestFailure: LocalizedError {
    case offline
    var errorDescription: String? { "Offline" }
}

@MainActor
private final class UpdateTestClock {
    let origin = ContinuousClock.now
    var instant: ContinuousClock.Instant
    private var waiters: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]
    private(set) var deadlines: [Int64] = []
    var waiterCount: Int { waiters.count }
    var date: Date { Date(timeIntervalSince1970: Double(origin.duration(to: instant).components.seconds)) }

    init() { instant = origin }

    func advance(by duration: Duration) {
        instant = instant.advanced(by: duration)
        let due = waiters.filter { $0.value.0 <= instant }
        for (id, waiter) in due {
            waiters.removeValue(forKey: id)
            waiter.1.resume()
        }
    }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        deadlines.append(origin.duration(to: deadline).components.seconds)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                if deadline <= instant { continuation.resume() }
                else { waiters[id] = (deadline, continuation) }
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.1.resume(throwing: CancellationError())
            }
        }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while condition() == false {
        if ContinuousClock.now >= deadline { return false }
        await Task.yield()
    }
    return true
}
