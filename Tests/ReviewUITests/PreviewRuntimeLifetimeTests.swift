import CodexAppServerKit
import CodexAppServerKitTesting
import CodexDataKit
import Testing
@testable import ReviewUIPreviewSupport

@Suite(.serialized)
@MainActor
struct PreviewRuntimeLifetimeTests {
    @Test func concurrentStoreStopsShareFullCloseAndReleaseResources() async throws {
        let source = ReviewMonitorPreviewContent.makeContentSource()
        await source.startAndWaitForTesting()
        let lifetime = try #require(source.runtimeLifetimeForTesting)

        weak var weakContainer: CodexModelContainer?
        weak var weakServer: CodexAppServer?
        do {
            weakContainer = source.modelContainerForTesting
            weakServer = lifetime.runtimeServerForTesting
        }
        source.startStreamingForTesting(interval: .seconds(60))
        _ = await source.appendPreviewChatLogStreamTick(
            after: 0,
            emitsNotifications: true
        )
        #expect(source.activeRuntimeTaskCountForTesting >= 2)

        let firstStop = Task { @MainActor in
            await source.store.stop()
        }
        let secondStop = Task { @MainActor in
            await source.store.stop()
        }
        await firstStop.value
        await secondStop.value

        #expect(source.stopOperationCountForTesting == 1)
        #expect(lifetime.lifecycleStateForTesting.fullCloseCount == 1)
        #expect(source.codexModelSource.modelContext == nil)
        #expect(source.modelContainerForTesting == nil)
        #expect(source.activeRuntimeTaskCountForTesting == 0)
        #expect(weakContainer == nil)
        #expect(weakServer == nil)
    }

    @Test func stoppedStoreRejectsLateStreamMutationAndNotification() async throws {
        let source = ReviewMonitorPreviewContent.makeContentSource()
        await source.startAndWaitForTesting()
        let lifetime = try #require(source.runtimeLifetimeForTesting)
        let chatID = try #require(source.initialChatID)
        let snapshotBeforeStop = await source.snapshotForTesting(chatID: chatID)
        let notificationCountBeforeStop = lifetime.lifecycleStateForTesting.emittedNotificationCount

        await source.store.stop()
        let tick = await source.appendPreviewChatLogStreamTick(
            after: 42,
            emitsNotifications: true
        )

        #expect(tick == 42)
        #expect(await source.snapshotForTesting(chatID: chatID) == snapshotBeforeStop)
        #expect(lifetime.lifecycleStateForTesting.emittedNotificationCount == notificationCountBeforeStop)
    }

    @Test func sourceDropOnlySignalsCancellationSoExplicitStopRemainsRequired() async throws {
        var source: ReviewMonitorPreviewContentSource? = ReviewMonitorPreviewContent.makeContentSource()
        await source?.startAndWaitForTesting()
        weak var weakLifetime: PreviewRuntimeLifetime?
        let lifecycleState: PreviewRuntimeLifecycleState
        let transport: CodexAppServerTestTransport
        do {
            let lifetime = try #require(source?.runtimeLifetimeForTesting)
            weakLifetime = lifetime
            lifecycleState = lifetime.lifecycleStateForTesting
            transport = try #require(source?.runtimeTransportForTesting)
        }

        source = nil

        #expect(weakLifetime == nil)
        #expect(lifecycleState.fullCloseCount == 0)

        await transport.close()
    }
}
