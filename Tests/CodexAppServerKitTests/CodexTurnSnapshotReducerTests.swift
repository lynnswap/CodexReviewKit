import Testing

@testable import CodexAppServerKit

@Suite("Turn snapshot reducer")
struct CodexTurnSnapshotReducerTests {
    @Test func identityAloneDoesNotClaimTranscriptCompleteness() {
        var reducer = CodexTurnSnapshotReducer(turnID: "turn-1")

        #expect(reducer.snapshot.itemsLoadState == .notLoaded)

        reducer.markStarted()

        #expect(reducer.snapshot.itemsLoadState == .full)
    }

    @Test func delayedStartDoesNotPromoteSummarySnapshotCompleteness() {
        let summary = item(id: "summary", kind: .agentMessage, text: "Summary")
        let terminal = item(id: "terminal", kind: .agentMessage, text: "Terminal")
        var reducer = CodexTurnSnapshotReducer(snapshot: .init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .summary,
            items: [summary]
        ))

        reducer.markStarted()
        let compact = reducer.finish(.completed(.init(
            turnID: "turn-1",
            transcript: .init(items: [terminal]),
            transcriptItemsLoadState: .summary
        )))

        #expect(compact.snapshot.itemsLoadState == .summary)
        #expect(compact.snapshot.items == [summary, terminal])
    }

    @Test func delayedStartDoesNotPromoteNotLoadedHistorySnapshot() {
        var reducer = CodexTurnSnapshotReducer(snapshot: .init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .notLoaded
        ))

        reducer.markStarted()

        #expect(reducer.snapshot.itemsLoadState == .notLoaded)
    }

    @Test func delayedStartPromotesIdentityOnlyBindingSnapshot() {
        var reducer = CodexTurnSnapshotReducer(turnID: "turn-1")
        reducer.replaceBindingSnapshot(with: .init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .notLoaded
        ))

        reducer.markStarted()

        #expect(reducer.snapshot.itemsLoadState == .full)
    }

    @Test func sparseTerminalUpdatesAnUnobservedItemWithTheSameRawIDAsAnotherKind() {
        let entered = item(
            id: "review-marker",
            kind: .enteredReviewMode,
            text: "Entered"
        )
        let staleExit = item(
            id: "review-marker",
            kind: .exitedReviewMode,
            text: "Stale"
        )
        let observedEntered = item(
            id: "review-marker",
            kind: .enteredReviewMode,
            text: "Entered live"
        )
        let terminalExit = item(
            id: "review-marker",
            kind: .exitedReviewMode,
            text: "Final review"
        )
        var reducer = CodexTurnSnapshotReducer(snapshot: .init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .summary,
            items: [entered, staleExit]
        ))
        reducer.observe(observedEntered)

        let compact = reducer.finish(.completed(.init(
            turnID: "turn-1",
            transcript: .init(items: [terminalExit]),
            transcriptItemsLoadState: .summary
        )))

        #expect(compact.snapshot.items == [observedEntered, terminalExit])
        #expect(compact.outcome.response.transcript.items == [observedEntered, terminalExit])
    }

    @Test func sparseTerminalPreservesObservedOrderAndItems() {
        let seeded = item(id: "seeded", kind: .agentMessage, text: "Seeded")
        let observed = item(id: "observed", kind: .agentMessage, text: "Observed")
        let terminal = item(id: "observed", kind: .agentMessage, text: "Summary")
        var reducer = CodexTurnSnapshotReducer(snapshot: .init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .summary,
            items: [seeded]
        ))
        reducer.observe(observed)

        let compact = reducer.finish(.completed(.init(
            turnID: "turn-1",
            transcript: .init(items: [terminal]),
            transcriptItemsLoadState: .summary
        )))

        #expect(compact.snapshot.items == [seeded, observed])
        #expect(compact.outcome.response.transcript.items == [seeded, observed])
    }

    @Test func fullTerminalRemovesOmittedItems() {
        let omitted = item(id: "omitted", kind: .agentMessage, text: "Omitted")
        let retained = item(id: "retained", kind: .agentMessage, text: "Retained")
        var reducer = CodexTurnSnapshotReducer(snapshot: .init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .full,
            items: [omitted]
        ))

        let compact = reducer.finish(.completed(.init(
            turnID: "turn-1",
            transcript: .init(items: [retained]),
            transcriptItemsLoadState: .full
        )))

        #expect(compact.snapshot.items == [retained])
        #expect(compact.outcome.response.transcript.items == [retained])
    }

    @Test func fullResponseSnapshotKeepsOnlyConcurrentObservedItems() {
        let stale = item(id: "stale", kind: .agentMessage, text: "Stale")
        let observed = item(id: "observed", kind: .agentMessage, text: "Observed")
        let response = item(id: "response", kind: .agentMessage, text: "Response")
        var reducer = CodexTurnSnapshotReducer(snapshot: .init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .summary,
            items: [stale]
        ))
        reducer.observe(observed)

        reducer.merge(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .full,
            items: [response]
        ))

        #expect(reducer.snapshot.items == [response, observed])
        #expect(reducer.snapshot.itemsLoadState == .full)
    }

    @Test func partialResponseSnapshotCannotReplaceACompleteItem() {
        let first = item(id: "first", kind: .agentMessage, text: "First")
        let complete = item(id: "message", kind: .agentMessage, text: "Complete")
        let summary = item(id: "message", kind: .agentMessage, text: "Summary")
        let newSummary = item(id: "new", kind: .agentMessage, text: "New summary")
        var reducer = CodexTurnSnapshotReducer(snapshot: .init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .full,
            items: [first, complete]
        ))

        reducer.merge(.init(
            id: "turn-1",
            state: .inProgress,
            itemsLoadState: .summary,
            items: [summary, newSummary]
        ))

        #expect(reducer.snapshot.items == [first, complete, newSummary])
        #expect(reducer.snapshot.itemsLoadState == .full)
    }

    private func item(
        id: String,
        kind: CodexThreadItem.Kind,
        text: String
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch kind {
        case .agentMessage:
            content = .message(.init(id: id, role: .assistant, text: text))
        case .enteredReviewMode, .exitedReviewMode:
            content = .log(text)
        default:
            Issue.record("Unsupported test item kind \(kind).")
            content = .log(text)
        }
        return .init(id: id, kind: kind, content: content)
    }
}
