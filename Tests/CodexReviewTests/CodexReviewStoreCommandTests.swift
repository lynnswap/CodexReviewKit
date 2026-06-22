import Foundation
import Testing
@_spi(Testing) @testable import CodexReview
import CodexReviewDomain
import CodexReviewTesting

@Suite("Codex review store", .serialized)
@MainActor
struct CodexReviewStoreCommandTests {
    @Test func reviewStartPublishesCompletedJobAndRetainsResult() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { Date(timeIntervalSince1970: 1) }),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.log("started"))
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result

            #expect(read.jobID == "job-1")
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.output.lastAgentMessage == "review text")
            #expect(store.listReviews(sessionID: nil).items.map(\.jobID) == ["job-1"])

            let commands = await backend.recordedCommands()
            #expect(commands.contains(.cleanupReview(.init(
                threadID: "thread-1",
                turnID: "turn-1",
                reviewThreadID: "review-thread-1"
            ))))
        }
    }

    @Test func boundedReviewStartReturnsRunningSnapshotAndCanBeAwaitedLater() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            let running = try await result

            #expect(running.jobID == "job-1")
            #expect(running.core.lifecycle.status == .running)
            #expect(running.core.output.hasFinalReview == false)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let final = try await store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(final.core.output.lastAgentMessage == "review text")
        }
    }

    @Test func domainEventsMutateTimelineAndSuppressLegacyLogProjection() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { Date(timeIntervalSince1970: 10) }),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "msg-1")
            await backend.yield(.domainEvents([
                .itemStarted(.init(
                    id: itemID,
                    kind: .agentMessage,
                    family: .message,
                    phase: .running,
                    content: .message(.init(text: ""))
                )),
            ], legacyProjectionSuppressionCount: 0))
            #expect(await waitUntil {
                store.job(id: "job-1")?.timeline.item(for: itemID) != nil
            })
            let originalItem = try #require(store.job(id: "job-1")?.timeline.item(for: itemID))

            await backend.yield(.domainEvents([
                .textDelta(
                    itemID: itemID,
                    kind: .agentMessage,
                    family: .message,
                    content: .message(.init(text: "")),
                    delta: "domain text"
                ),
            ], legacyProjectionSuppressionCount: 1))
            #expect(await waitUntil {
                guard let item = store.job(id: "job-1")?.timeline.item(for: itemID),
                      case .message(let message) = item.content
                else {
                    return false
                }
                return message.text == "domain text"
            })
            let updatedItem = try #require(store.job(id: "job-1")?.timeline.item(for: itemID))
            #expect(originalItem === updatedItem)

            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: " legacy text",
                groupID: "msg-1",
                replacesGroup: false
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.contains { $0.text == " legacy text" } == true
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.timeline.items.count == 1)
            #expect(job.timeline.item(for: itemID) === originalItem)
            guard case .message(let message) = job.timeline.item(for: itemID)?.content else {
                Issue.record("expected direct message timeline content")
                return
            }
            #expect(message.text == "domain text")

            await backend.yield(.logEntry(
                kind: .diagnostic,
                text: "legacy-only diagnostic",
                groupID: nil,
                replacesGroup: false
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.timeline.items.count == 2
            })
            #expect(store.job(id: "job-1")?.timeline.item(for: itemID) === originalItem)
        }
    }

    @Test func terminalCommandCompatibilityLogUpdatesDirectTimelineItem() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "cmd-1")
            await backend.yield(.domainEvents([
                .itemStarted(.init(
                    id: itemID,
                    kind: .commandExecution,
                    family: .command,
                    phase: .running,
                    content: .command(.init(command: "swift test"))
                )),
            ], legacyProjectionSuppressionCount: 0))
            #expect(await waitUntil {
                store.job(id: "job-1")?.timeline.activeItemIDs.contains(itemID) == true
            })
            let originalItem = try #require(store.job(id: "job-1")?.timeline.item(for: itemID))

            await backend.yield(.logEntry(
                kind: .command,
                text: "$ swift test",
                groupID: "cmd-1",
                replacesGroup: true,
                metadata: .init(
                    sourceType: "commandExecution",
                    status: "completed",
                    itemID: "cmd-1",
                    command: "swift test",
                    commandStatus: "completed"
                )
            ))
            #expect(await waitUntil {
                guard let item = store.job(id: "job-1")?.timeline.item(for: itemID) else {
                    return false
                }
                return item.phase == .completed
                    && store.job(id: "job-1")?.timeline.activeItemIDs.contains(itemID) == false
            })

            let updatedItem = try #require(store.job(id: "job-1")?.timeline.item(for: itemID))
            #expect(originalItem === updatedItem)
        }
    }

    @Test func skippedLegacyDeltaConsumesDirectProjectionSuppression() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "msg-1")
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: itemID,
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: "final"))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: "final",
                groupID: "msg-1",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.contains { $0.text == "final" } == true
            })

            await backend.yield(.domainEvents([
                .textDelta(
                    itemID: itemID,
                    kind: .agentMessage,
                    family: .message,
                    content: .message(.init(text: "")),
                    delta: "late"
                ),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.messageDelta("late", itemID: "msg-1"))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.contains { $0.text == "late" } == false
            })
            let messageItem = try #require(store.job(id: "job-1")?.timeline.item(for: itemID))
            guard case .message(let message) = messageItem.content else {
                Issue.record("expected message timeline content")
                return
            }
            #expect(message.text == "final")

            let timelineCount = try #require(store.job(id: "job-1")?.timeline.items.count)
            await backend.yield(.logEntry(
                kind: .diagnostic,
                text: "legacy-only diagnostic",
                groupID: nil,
                replacesGroup: false
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.timeline.items.count == timelineCount + 1
            })
        }
    }

    @Test func directTerminalErrorSuppressesCompatibleErrorLogTimelineProjection() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "error:turn-1")
            let longError = String(repeating: "App-server failed.", count: 20_000)
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: itemID,
                    kind: .init(rawValue: "error"),
                    family: .diagnostic,
                    phase: .failed,
                    content: .diagnostic(.init(message: longError))
                )),
            ], legacyProjectionSuppressionCount: 0))
            await backend.yield(.suppressNextTerminalFailureLogTimelineProjection)
            await backend.yield(.failed(longError))

            #expect(await waitUntil {
                store.job(id: "job-1")?.core.lifecycle.status == .failed
            })
            let job = try #require(store.job(id: "job-1"))
            #expect(job.logEntries.contains { $0.kind == .error })
            let item = try #require(job.timeline.item(for: itemID))
            guard case .diagnostic(let diagnostic) = item.content else {
                Issue.record("expected diagnostic timeline content")
                return
            }
            #expect(diagnostic.message.count < longError.count)
            #expect(job.timeline.items.count == 1)
        }
    }

    @Test func directTimelineTextIsTrimmedWhenReviewLogLimitApplies() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "msg-1")
            let longText = String(repeating: "x", count: 300_000)
            await backend.yield(.domainEvents([
                .itemStarted(.init(
                    id: itemID,
                    kind: .agentMessage,
                    family: .message,
                    phase: .running,
                    content: .message(.init(text: ""))
                )),
                .textDelta(
                    itemID: itemID,
                    kind: .agentMessage,
                    family: .message,
                    content: .message(.init(text: "")),
                    delta: longText
                ),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: longText,
                groupID: "msg-1",
                replacesGroup: false
            ))
            #expect(await waitUntil {
                guard let item = store.job(id: "job-1")?.timeline.item(for: itemID),
                      case .message(let message) = item.content
                else {
                    return false
                }
                return message.text.count == longText.count
            })

            await backend.yield(.failed("Failed."))
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.lifecycle.status == .failed
            })
            let item = try #require(store.job(id: "job-1")?.timeline.item(for: itemID))
            guard case .message(let message) = item.content else {
                Issue.record("expected message timeline content")
                return
            }
            #expect(message.text.count < longText.count)
        }
    }

    @Test func directFullItemTimelineTextIsTrimmedWhenReviewLogLimitApplies() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "msg-1")
            let longText = String(repeating: "x", count: 300_000)
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: itemID,
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: longText))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: longText,
                groupID: "msg-1",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                guard let item = store.job(id: "job-1")?.timeline.item(for: itemID),
                      case .message(let message) = item.content
                else {
                    return false
                }
                return message.text.count == longText.count
            })

            await backend.yield(.failed("Failed."))
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.lifecycle.status == .failed
            })
            let item = try #require(store.job(id: "job-1")?.timeline.item(for: itemID))
            guard case .message(let message) = item.content else {
                Issue.record("expected message timeline content")
                return
            }
            #expect(message.text.count < longText.count)
        }
    }

    @Test func retainedCommandOutputChunksAppendWhenTrimmingDirectTimelineText() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "cmd-1")
            let firstChunk = "first retained chunk\n"
            let secondChunk = "second retained chunk\n"
            await backend.yield(.domainEvents([
                .itemStarted(.init(
                    id: itemID,
                    kind: .commandExecution,
                    family: .command,
                    phase: .running,
                    content: .command(.init(command: "swift test"))
                )),
                .textDelta(
                    itemID: itemID,
                    kind: .commandExecution,
                    family: .command,
                    content: .command(.init(command: "swift test")),
                    delta: firstChunk
                ),
                .textDelta(
                    itemID: itemID,
                    kind: .commandExecution,
                    family: .command,
                    content: .command(.init(command: "swift test")),
                    delta: secondChunk
                ),
            ], legacyProjectionSuppressionCount: 2))
            let outputMetadata = ReviewLogEntry.Metadata(
                sourceType: "commandExecution",
                title: "Command output",
                itemID: itemID.rawValue,
                command: "swift test"
            )
            await backend.yield(.logEntry(
                kind: .commandOutput,
                text: firstChunk,
                groupID: itemID.rawValue,
                replacesGroup: false,
                metadata: outputMetadata
            ))
            await backend.yield(.logEntry(
                kind: .commandOutput,
                text: secondChunk,
                groupID: itemID.rawValue,
                replacesGroup: false,
                metadata: outputMetadata
            ))
            await backend.yield(.logEntry(
                kind: .diagnostic,
                text: String(repeating: "x", count: 300_000),
                groupID: "diagnostic-1",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.count == 3
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.applyReviewLogLimit())
            let item = try #require(job.timeline.item(for: itemID))
            guard case .command(let command) = item.content else {
                Issue.record("expected command timeline content")
                return
            }
            #expect(command.output == firstChunk + secondChunk)
        }
    }

    @Test func syntheticDirectTimelineTextIsTrimmedThroughSuppressedCompatibilityLog() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "msg-1")
            let longText = String(repeating: "x", count: 300_000)
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: itemID,
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: longText))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: longText,
                groupID: nil,
                replacesGroup: true
            ))

            await backend.yield(.failed("Failed."))
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.lifecycle.status == .failed
            })
            let item = try #require(store.job(id: "job-1")?.timeline.item(for: itemID))
            guard case .message(let message) = item.content else {
                Issue.record("expected message timeline content")
                return
            }
            #expect(message.text.count < longText.count)
        }
    }

    @Test func eventCompatibilityLogTrimsDirectDiagnosticTimelineText() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "diff-1")
            let longText = String(repeating: "diff --git\n", count: 40_000)
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: itemID,
                    kind: .init(rawValue: "turn/diff/updated"),
                    family: .diagnostic,
                    phase: .completed,
                    content: .diagnostic(.init(message: longText))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .event,
                text: longText,
                groupID: itemID.rawValue,
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.contains {
                    $0.kind == .event && $0.groupID == itemID.rawValue
                } == true
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.applyReviewLogLimit())
            let item = try #require(job.timeline.item(for: itemID))
            guard case .diagnostic(let diagnostic) = item.content else {
                Issue.record("expected diagnostic timeline content")
                return
            }
            #expect(diagnostic.message.count < longText.count)
        }
    }

    @Test func fileChangeStatusCompatibilityLogDoesNotTrimDirectPatchText() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "file-1:patch")
            let patchText = String(repeating: "diff --git a/Sources/App.swift b/Sources/App.swift\n", count: 8_000)
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: itemID,
                    kind: .fileChange,
                    family: .fileChange,
                    phase: .running,
                    content: .fileChange(.init(title: "Sources/App.swift", output: patchText))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .toolCall,
                text: "File changes updated.",
                groupID: "file-1",
                replacesGroup: false,
                metadata: .init(sourceType: "fileChange", title: "File changes", status: "updated")
            ))
            await backend.yield(.logEntry(
                kind: .diagnostic,
                text: String(repeating: "x", count: 300_000),
                groupID: "diagnostic-1",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.count == 2
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.applyReviewLogLimit())
            let item = try #require(job.timeline.item(for: itemID))
            guard case .fileChange(let fileChange) = item.content else {
                Issue.record("expected file-change timeline content")
                return
            }
            #expect(fileChange.output == patchText)
        }
    }

    @Test func directRawReasoningTimelineTextTrimUsesLegacyGroupIDAndBumpsRevision() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "reasoning-1:content:0")
            let longText = String(repeating: "r", count: 300_000)
            await backend.yield(.domainEvents([
                .textDelta(
                    itemID: itemID,
                    kind: .reasoning,
                    family: .reasoning,
                    content: .reasoning(.init(text: "", style: .raw)),
                    delta: longText
                ),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: longText,
                groupID: "reasoning-1:0",
                replacesGroup: false
            ))
            #expect(await waitUntil {
                guard let item = store.job(id: "job-1")?.timeline.item(for: itemID),
                      case .reasoning(let reasoning) = item.content
                else {
                    return false
                }
                return reasoning.text.count == longText.count
                    && store.job(id: "job-1")?.logEntries.contains {
                        $0.kind == .rawReasoning && $0.groupID == "reasoning-1:0"
                    } == true
            })

            let job = try #require(store.job(id: "job-1"))
            let revisionBeforeTrim = job.timeline.revision
            #expect(job.applyReviewLogLimit())
            #expect(job.timeline.revision > revisionBeforeTrim)
            let item = try #require(job.timeline.item(for: itemID))
            guard case .reasoning(let reasoning) = item.content else {
                Issue.record("expected reasoning timeline content")
                return
            }
            #expect(reasoning.text.count < longText.count)
        }
    }

    @Test func directPlanTimelineTextTrimUsesSyntheticTurnPlanID() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "turn-1:turn/plan/updated")
            let longText = String(repeating: "- [pending] Review file\n", count: 15_000)
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: itemID,
                    kind: .plan,
                    family: .plan,
                    phase: .running,
                    content: .plan(.init(markdown: longText))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .todoList,
                text: longText,
                groupID: "turn-1",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.contains {
                    $0.kind == .todoList && $0.groupID == "turn-1"
                } == true
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.applyReviewLogLimit())
            let item = try #require(job.timeline.item(for: itemID))
            guard case .plan(let plan) = item.content else {
                Issue.record("expected plan timeline content")
                return
            }
            #expect(plan.markdown.count < longText.count)
        }
    }

    @Test func mcpToolCompletionLogDoesNotReplaceDirectProgressTextDuringTrim() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let progressItemID = ReviewTimelineItem.ID(rawValue: "tool-1:progress")
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: progressItemID,
                    kind: .mcpToolCall,
                    family: .tool,
                    phase: .running,
                    content: .toolCall(.init(
                        server: "codex_review",
                        tool: "review_read",
                        progress: "Reading review job"
                    ))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .toolCall,
                text: "Reading review job",
                groupID: "tool-1",
                replacesGroup: false,
                metadata: .init(sourceType: "mcpToolCall", title: "Tool progress")
            ))
            await backend.yield(.logEntry(
                kind: .toolCall,
                text: "codex_review.review_read completed. Result: ok",
                groupID: "tool-1",
                replacesGroup: true,
                metadata: .init(
                    sourceType: "mcpToolCall",
                    title: "codex_review.review_read",
                    status: "completed",
                    server: "codex_review",
                    tool: "review_read",
                    resultText: "ok"
                )
            ))
            await backend.yield(.logEntry(
                kind: .diagnostic,
                text: String(repeating: "x", count: 300_000),
                groupID: "diagnostic-1",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.count == 3
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.applyReviewLogLimit())
            let item = try #require(job.timeline.item(for: progressItemID))
            guard case .toolCall(let toolCall) = item.content else {
                Issue.record("expected tool progress timeline content")
                return
            }
            #expect(toolCall.progress == "Reading review job")
            #expect(try store.readReview(jobID: "job-1", logFilter: .all).logs.contains {
                $0.kind == .toolCall && $0.text == "Reading review job"
            })
        }
    }

    @Test func directToolCallErrorTextIsTrimmedWhenReviewLogLimitApplies() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let itemID = ReviewTimelineItem.ID(rawValue: "tool-error-1")
            let longError = String(repeating: "error", count: 60_000)
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: itemID,
                    kind: .mcpToolCall,
                    family: .tool,
                    phase: .failed,
                    content: .toolCall(.init(
                        server: "codex_review",
                        tool: "review_read",
                        error: longError
                    ))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .toolCall,
                text: longError,
                groupID: itemID.rawValue,
                replacesGroup: true,
                metadata: .init(
                    sourceType: "mcpToolCall",
                    title: "codex_review.review_read",
                    status: "failed",
                    server: "codex_review",
                    tool: "review_read",
                    errorText: longError
                )
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.contains {
                    $0.kind == .toolCall && $0.groupID == itemID.rawValue
                } == true
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.applyReviewLogLimit())
            let item = try #require(job.timeline.item(for: itemID))
            guard case .toolCall(let toolCall) = item.content else {
                Issue.record("expected tool call timeline content")
                return
            }
            #expect((toolCall.error ?? "").count < longError.count)
        }
    }

    @Test func mappedDirectTimelineTextClearsWhenCompatibilityLogIsRemovedByLimit() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let firstItemID = ReviewTimelineItem.ID(rawValue: "msg-1")
            let secondItemID = ReviewTimelineItem.ID(rawValue: "msg-2")
            let firstText = String(repeating: "a", count: 300_000)
            let secondText = String(repeating: "b", count: 300_000)
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: firstItemID,
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: firstText))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: firstText,
                groupID: "msg-1",
                replacesGroup: true
            ))
            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: secondItemID,
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: secondText))
                )),
            ], legacyProjectionSuppressionCount: 1))
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: secondText,
                groupID: "msg-2",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logEntries.count == 2
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.applyReviewLogLimit())
            let firstItem = try #require(job.timeline.item(for: firstItemID))
            let secondItem = try #require(job.timeline.item(for: secondItemID))
            guard case .message(let firstMessage) = firstItem.content,
                  case .message(let secondMessage) = secondItem.content
            else {
                Issue.record("expected message timeline content")
                return
            }
            #expect(firstMessage.text.isEmpty)
            #expect(secondMessage.text.count < secondText.count)
        }
    }

    @Test func legacyTimelineTextFromBeforeDirectEventsIsTrimmed() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            let longText = String(repeating: "legacy", count: 60_000)
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: longText,
                groupID: "legacy-message",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.timeline.items.contains { item in
                    guard case .message(let message) = item.content else {
                        return false
                    }
                    return message.text == longText
                } == true
            })
            let legacyItemID = try #require(store.job(id: "job-1")?.timeline.items.first { item in
                guard case .message(let message) = item.content else {
                    return false
                }
                return message.text == longText
            }?.id)

            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: .init(rawValue: "direct-message"),
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: "direct"))
                )),
            ], legacyProjectionSuppressionCount: 0))
            #expect(await waitUntil {
                store.job(id: "job-1")?.timeline.item(for: .init(rawValue: "direct-message")) != nil
            })

            let job = try #require(store.job(id: "job-1"))
            #expect(job.applyReviewLogLimit())
            let item = try #require(job.timeline.item(for: legacyItemID))
            guard case .message(let message) = item.content else {
                Issue.record("expected message timeline content")
                return
            }
            #expect(message.text.count < longText.count)
        }
    }

    @Test func legacyProjectedTimelineTextIsTrimmedAfterDirectEvents() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await result

            await backend.yield(.domainEvents([
                .itemUpdated(.init(
                    id: .init(rawValue: "msg-1"),
                    kind: .agentMessage,
                    family: .message,
                    phase: .completed,
                    content: .message(.init(text: "direct"))
                )),
            ], legacyProjectionSuppressionCount: 0))

            let longText = String(repeating: "y", count: 300_000)
            await backend.yield(.logEntry(
                kind: .diagnostic,
                text: longText,
                groupID: "diagnostic-1",
                replacesGroup: true
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.timeline.items.contains { item in
                    guard case .diagnostic(let diagnostic) = item.content else {
                        return false
                    }
                    return diagnostic.message == longText
                } == true
            })
            let legacyItemID = try #require(store.job(id: "job-1")?.timeline.items.first { item in
                guard case .diagnostic(let diagnostic) = item.content else {
                    return false
                }
                return diagnostic.message == longText
            }?.id)

            await backend.yield(.failed("Failed."))
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.lifecycle.status == .failed
            })
            let item = try #require(store.job(id: "job-1")?.timeline.item(for: legacyItemID))
            guard case .diagnostic(let diagnostic) = item.content else {
                Issue.record("expected diagnostic timeline content")
                return
            }
            #expect(diagnostic.message.count < longText.count)
        }
    }

    @Test func awaitReviewReturnsWhenRunningJobCompletes() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let final = try await awaited

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(final.core.output.lastAgentMessage == "review text")
        }
    }

    @Test func awaitReviewReturnsWhenRunningJobIsCancelled() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )
            _ = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            let final = try await awaited

            #expect(final.core.lifecycle.status == .cancelled)
            #expect(final.core.output.summary == "Stop")
        }
    }

    @Test func awaitReviewReturnsCurrentSnapshotOnTimeout() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            let snapshot = try await store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .milliseconds(10)
            )

            #expect(snapshot.core.lifecycle.status == .running)
            #expect(snapshot.core.output.hasFinalReview == false)
        }
    }

    @Test func awaitReviewReturnsWhenLocalTerminationUpdatesTimeline() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let start = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges),
                waitTimeout: .milliseconds(20)
            )
            _ = try await start

            async let awaited = store.awaitReview(
                sessionID: "session-1",
                jobID: "job-1",
                timeout: .seconds(1)
            )
            await Task.yield()
            store.terminateAllRunningJobsLocally(
                failureMessage: "Review runtime stopped."
            )
            let final = try await awaited

            #expect(final.core.lifecycle.status == .failed)
            #expect(final.core.output.summary == "Failed to cancel review: Review runtime stopped.")
        }
    }

    @Test func forceStartWhileRunningInvokesBackendRestartPath() async {
        let reviewBackend = FakeCodexReviewBackend()
        let backend = TestingCodexReviewStoreBackend(reviewBackend: reviewBackend)
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        await withStoreCommandTestCleanup(backend: reviewBackend, store: store) {
            await store.start()
            await store.start()
            await store.start(forceRestartIfNeeded: true)

            #expect(backend.startRequests == [false, true])
        }
    }

    @Test func reviewStartPassesEffectiveSettingsModelToBackend() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: backend,
                seed: .init(initialSettingsSnapshot: .init(fallbackModel: "gpt-5.5"))
            ),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result

            let commands = await backend.recordedCommands()
            let starts = commands.compactMap { command -> CodexReviewBackendModel.Review.Start? in
                if case .startReview(let request) = command {
                    return request
                }
                return nil
            }
            #expect(starts.first?.model == "gpt-5.5")
        }
    }

    @Test func reviewStartAppliesStartedTurnAndMergesAgentMessageDeltas() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.started(turnID: "turn-actual", reviewThreadID: "review-thread-1", model: "gpt-5.5"))
            await backend.yield(.messageDelta("hello", itemID: "message-1"))
            await backend.yield(.messageDelta(" world", itemID: "message-1"))
            await backend.yield(.logEntry(
                kind: .reasoningSummary,
                text: " with space",
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: nil))
            let read = try await result

            #expect(read.core.run.turnID == "turn-actual")
            #expect(read.core.output.lastAgentMessage == "hello world")
            #expect(read.rawLogText.isEmpty)
            #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == [
                "hello world",
                " with space",
            ])
            #expect(try #require(store.job(id: "job-1")).reviewOutputText == "hello world\n\n with space")
            #expect(try store.readReview(jobID: "job-1").core.run.model == "gpt-5.5")
        }
    }

    @Test func reviewStartTracksAgentMessageDeltasByItemID() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.messageDelta("first", itemID: "message-1"))
            await backend.yield(.messageDelta("second", itemID: "message-2"))
            await backend.yield(.completed(summary: "Succeeded.", result: nil))
            let read = try await result

            #expect(read.core.output.lastAgentMessage == "second")
            #expect(read.core.reviewText == "second")
            #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == ["first", "second"])
        }
    }

    @Test func reviewCompletionDoesNotDuplicateAlreadyLoggedFinalMessage() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.logEntry(
                kind: .agentMessage,
                text: "final review text",
                groupID: "review-item-1",
                replacesGroup: true
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: "final review text"))
            let read = try await result

            #expect(read.core.output.lastAgentMessage == "final review text")
            #expect(read.core.reviewText == "final review text")
            #expect(try store.readReview(jobID: "job-1").logs.map(\.text) == ["final review text"])
        }
    }

    @Test func reviewCompletionEnforcesLogLimitWithoutFinalAppend() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let initialText = String(repeating: "a", count: 250 * 1024)
            let delta = String(repeating: "b", count: 20 * 1024)

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: initialText,
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: delta,
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.completed(summary: "Succeeded.", result: nil))
            let read = try await result
            let job = try #require(store.job(id: "job-1"))

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(job.cappedLogBytes <= 256 * 1024)
            #expect(job.logText.hasSuffix(delta))
            #expect(job.lastLogMutation == .reload)
        }
    }

    @Test func readReviewDefaultsToCommandOutputFilteredLogs() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .succeeded,
            summary: "Done",
            logEntries: [
                .init(kind: .event, text: "Turn started: turn-1"),
                .init(kind: .progress, text: "Reviewing current changes"),
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "Tests passed"),
                .init(kind: .plan, groupID: "plan-1", text: "Plan text"),
                .init(kind: .todoList, groupID: "turn-1", text: "[inProgress] Inspect diff"),
                .init(kind: .reasoningSummary, groupID: "reasoning-1:summary:0", text: "Reasoning summary"),
                .init(kind: .rawReasoning, groupID: "reasoning-1:0", text: "Raw reasoning"),
                .init(kind: .toolCall, groupID: "tool-1", text: "MCP tool started"),
                .init(kind: .diagnostic, text: "Warning"),
                .init(kind: .error, text: "Recoverable error"),
                .init(kind: .agentMessage, text: "No correctness issues found."),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        #expect(try store.readReview(jobID: "job-1").logs.map(\.kind) == [
            .event,
            .progress,
            .command,
            .plan,
            .todoList,
            .reasoningSummary,
            .rawReasoning,
            .toolCall,
            .diagnostic,
            .error,
            .agentMessage,
        ])
        #expect(try store.readReview(jobID: "job-1", logFilter: .all).logs.map(\.kind) == [
            .event,
            .progress,
            .command,
            .commandOutput,
            .plan,
            .todoList,
            .reasoningSummary,
            .rawReasoning,
            .toolCall,
            .diagnostic,
            .error,
            .agentMessage,
        ])
    }

    @Test func readReviewDefaultsToLatestPagedLogs() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let entries = (0..<125).map { index in
            ReviewLogEntry(kind: .progress, text: "line-\(index)")
        }
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: entries
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        let read = try store.readReview(jobID: "job-1")

        #expect(read.logs.map(\.text).first == "line-25")
        #expect(read.logs.map(\.text).last == "line-124")
        #expect(read.logsPage == CodexReviewAPI.Log.Page(
            total: 125,
            offset: 25,
            limit: 100,
            returned: 100,
            hasMoreBefore: true,
            hasMoreAfter: false,
            previousOffset: 0,
            nextOffset: nil
        ))
    }

    @Test func readReviewReturnsRequestedLogPage() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let entries = (0..<12).map { index in
            ReviewLogEntry(kind: .progress, text: "line-\(index)")
        }
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: entries
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        let read = try store.readReview(
            jobID: "job-1",
            logPage: .init(offset: 5, limit: 4)
        )

        #expect(read.logs.map(\.text) == ["line-5", "line-6", "line-7", "line-8"])
        #expect(read.logsPage == CodexReviewAPI.Log.Page(
            total: 12,
            offset: 5,
            limit: 4,
            returned: 4,
            hasMoreBefore: true,
            hasMoreAfter: true,
            previousOffset: 1,
            nextOffset: 9
        ))
    }

    @Test func readReviewRejectsInvalidLogPageRequests() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running"
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        #expect(throws: (any Error).self) {
            try store.readReview(jobID: "job-1", logPage: .init(offset: -1))
        }
        #expect(throws: (any Error).self) {
            try store.readReview(jobID: "job-1", logPage: .init(limit: -1))
        }
        #expect(throws: (any Error).self) {
            try store.readReview(jobID: "job-1", logPage: .init(limit: CodexReviewAPI.Log.PageRequest.maxLimit + 1))
        }
    }

    @Test func readReviewProjectsGroupedLogEntriesBeforeFilteringAndPaging() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .reasoningSummary, groupID: "reasoning-1", text: "first"),
                .init(kind: .reasoningSummary, groupID: "reasoning-1", text: " + second"),
                .init(
                    kind: .plan,
                    groupID: "plan-1",
                    text: "- old",
                    metadata: .init(sourceType: "plan", status: "inProgress")
                ),
                .init(kind: .plan, groupID: "plan-1", replacesGroup: true, text: "- new"),
                .init(kind: .command, groupID: "cmd-1", text: "$ swift test"),
                .init(kind: .commandOutput, groupID: "cmd-1", text: "output"),
                .init(kind: .agentMessage, text: "Done"),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        let defaultRead = try store.readReview(jobID: "job-1")
        let allRead = try store.readReview(jobID: "job-1", logFilter: .all)

        #expect(defaultRead.logs.map(\.text) == [
            "first + second",
            "- new",
            "$ swift test",
            "Done",
        ])
        #expect(defaultRead.logs.allSatisfy { $0.replacesGroup == false })
        #expect(defaultRead.logs.first { $0.groupID == "plan-1" }?.metadata == nil)
        #expect(defaultRead.logsPage.total == 4)
        #expect(allRead.logs.map(\.text) == [
            "first + second",
            "- new",
            "$ swift test",
            "output",
            "Done",
        ])
        #expect(allRead.logsPage.total == 5)
    }

    @Test func readReviewFoldsReplacementOnlyGroupedKindsBeforePaging() throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        let job = CodexReviewJob.makeForTesting(
            id: "job-1",
            cwd: "/tmp/project",
            targetSummary: "Uncommitted changes",
            status: .running,
            summary: "Running",
            logEntries: [
                .init(kind: .progress, groupID: "progress-1", replacesGroup: true, text: "Reviewing started"),
                .init(kind: .progress, groupID: "progress-1", replacesGroup: true, text: "Reviewing completed"),
                .init(kind: .toolCall, groupID: "tool-1", replacesGroup: true, text: "MCP tool started"),
                .init(kind: .toolCall, groupID: "tool-1", replacesGroup: true, text: "MCP tool completed"),
                .init(kind: .todoList, groupID: "turn-1", replacesGroup: true, text: "[inProgress] Inspect"),
                .init(kind: .todoList, groupID: "turn-1", replacesGroup: true, text: "[completed] Inspect"),
                .init(kind: .event, groupID: "turn-1", replacesGroup: true, text: "old diff"),
                .init(kind: .event, groupID: "turn-1", replacesGroup: true, text: "new diff"),
                .init(kind: .progress, groupID: "progress-2", text: "first progress"),
                .init(kind: .progress, groupID: "progress-2", text: "second progress"),
                .init(kind: .toolCall, groupID: "tool-2", replacesGroup: true, text: "Tool 2 started"),
                .init(kind: .toolCall, groupID: "tool-2", text: "Tool 2 progress"),
                .init(kind: .toolCall, groupID: "tool-2", replacesGroup: true, text: "Tool 2 completed"),
            ]
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [.init(cwd: "/tmp/project")],
            jobs: [job]
        )

        let read = try store.readReview(jobID: "job-1", logPage: .init(limit: 10))

        #expect(read.logs.map(\.text) == [
            "Reviewing completed",
            "MCP tool completed",
            "[completed] Inspect",
            "new diff",
            "first progress",
            "second progress",
            "Tool 2 completed",
            "Tool 2 progress",
        ])
        #expect(read.logs.allSatisfy { $0.replacesGroup == false })
        #expect(read.logsPage.total == 8)
    }

    @Test func reviewStartParsesFinalReviewFindings() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: """
            Full review comments:
            - [P2] Add parser tests — Sources/Parser.swift:12-15
              The final review parser should be covered at the model layer.
            """))
            let read = try await result

            #expect(read.core.output.hasFinalReview)
            #expect(read.core.output.reviewResult?.state == .hasFindings)
            #expect(read.core.output.reviewResult?.findingCount == 1)
            #expect(read.core.output.reviewResult?.findings.first?.title == "[P2] Add parser tests")
        }
    }

    @Test func newlyStartedWorkspaceAppearsBeforeExistingWorkspaces() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let first = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/old-project", target: .baseBranch("main"))
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "first"))
            _ = try await first
            await backend.finishEvents()

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "second"))
            _ = try await second

            #expect(store.orderedWorkspaces.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
        }
    }

    @Test func newlyStartedWorkspaceUsesSortOrderAboveCurrentMaximum() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/old-project")]
            )
            store.workspace(cwd: "/tmp/old-project")?.sortOrder = 10

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/new-project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "new"))
            _ = try await result

            #expect(store.orderedWorkspaces.map(\.cwd) == ["/tmp/new-project", "/tmp/old-project"])
        }
    }

    @Test func newlyStartedReviewAppearsBeforeExistingJobsInWorkspace() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let first = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "first"))
            _ = try await first
            await backend.finishEvents()

            async let second = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "second"))
            _ = try await second

            #expect(store.orderedJobs(inWorkspace: "/tmp/project").map(\.targetSummary) == [
                "Uncommitted changes",
                "Base branch: main",
            ])
        }
    }

    @Test func runningReviewElapsedSecondsUsesInjectedClock() async throws {
        let backend = FakeCodexReviewBackend()
        let clock = MutableTestClock(Date(timeIntervalSince1970: 1))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { clock.now() }),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            clock.current = Date(timeIntervalSince1970: 13)

            #expect(try store.readReview(jobID: "job-1").elapsedSeconds == 12)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result
        }
    }

    @Test func newlyStartedReviewUsesSortOrderAboveCurrentWorkspaceMaximum() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let existing = CodexReviewJob.makeForTesting(
                id: "job-existing",
                cwd: "/tmp/project",
                targetSummary: "Existing",
                status: .succeeded,
                summary: "Done"
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [existing]
            )
            store.job(id: "job-existing")?.sortOrder = 10

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "new"))
            _ = try await result

            #expect(store.orderedJobs(inWorkspace: "/tmp/project").map(\.targetSummary).first == "Uncommitted changes")
        }
    }

    @Test func workspaceReorderBeforeAnchorMovesBlockAndReportsMutation() {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        let firstGroupedWorkspace = CodexReviewWorkspace(cwd: "/tmp/group-a-1")
        let secondWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-b")
        let thirdWorkspace = CodexReviewWorkspace(cwd: "/tmp/workspace-c")
        let secondGroupedWorkspace = CodexReviewWorkspace(cwd: "/tmp/group-a-2")
        store.loadForTesting(
            serverState: .running,
            workspaces: [firstGroupedWorkspace, secondWorkspace, thirdWorkspace, secondGroupedWorkspace]
        )

        #expect(store.reorderWorkspaces(
            cwds: [firstGroupedWorkspace.cwd, secondGroupedWorkspace.cwd],
            beforeCWD: thirdWorkspace.cwd
        ))
        #expect(store.orderedWorkspaces.map(\.cwd) == [
            secondWorkspace.cwd,
            firstGroupedWorkspace.cwd,
            secondGroupedWorkspace.cwd,
            thirdWorkspace.cwd,
        ])
        #expect(store.reorderWorkspaces(cwds: [firstGroupedWorkspace.cwd], beforeCWD: firstGroupedWorkspace.cwd) == false)
        #expect(store.reorderWorkspaces(cwds: [firstGroupedWorkspace.cwd], beforeCWD: "/tmp/missing") == false)
    }

    @Test func jobReorderBeforeAnchorMovesItemAndReportsMutation() {
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: FakeCodexReviewBackend())
        )
        let workspace = CodexReviewWorkspace(cwd: "/tmp/project")
        let firstJob = CodexReviewJob.makeForTesting(
            id: "job-first",
            cwd: workspace.cwd,
            targetSummary: "First",
            status: .running,
            summary: "Running"
        )
        let secondJob = CodexReviewJob.makeForTesting(
            id: "job-second",
            cwd: workspace.cwd,
            targetSummary: "Second",
            status: .running,
            summary: "Running"
        )
        let thirdJob = CodexReviewJob.makeForTesting(
            id: "job-third",
            cwd: workspace.cwd,
            targetSummary: "Third",
            status: .running,
            summary: "Running"
        )
        store.loadForTesting(
            serverState: .running,
            workspaces: [workspace],
            jobs: [firstJob, secondJob, thirdJob]
        )

        #expect(store.reorderJob(id: firstJob.id, inWorkspace: workspace.cwd, beforeJobID: thirdJob.id))
        #expect(store.orderedJobs(in: workspace).map(\.id) == ["job-second", "job-first", "job-third"])
        #expect(store.reorderJob(id: firstJob.id, inWorkspace: workspace.cwd, beforeJobID: firstJob.id) == false)
        #expect(store.reorderJob(id: firstJob.id, inWorkspace: workspace.cwd, beforeJobID: "job-missing") == false)
    }

    @Test func cancelRunningReviewUsesBackendInterruptAndPublicState() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            let cancel = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.cancelled("Stop"))
            _ = try await result

            #expect(cancel.cancelled)
            #expect(try store.readReview(jobID: "job-1").core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                .init(message: "Stop")
            )))
        }
    }

    @Test func cancellationEnforcesLogLimitWithoutPostTerminalAppend() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let initialText = String(repeating: "a", count: 250 * 1024)
            let delta = String(repeating: "b", count: 20 * 1024)

            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: initialText,
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            await backend.yield(.logEntry(
                kind: .rawReasoning,
                text: delta,
                groupID: "reasoning-1",
                replacesGroup: false
            ))
            #expect(await waitUntil {
                store.job(id: "job-1")?.logText.hasSuffix(delta) == true
            })
            _ = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.cancelled("Stop"))
            let read = try await result
            let job = try #require(store.job(id: "job-1"))

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(job.cappedLogBytes <= 256 * 1024)
            #expect(job.logText.hasSuffix(delta))
            #expect(job.lastLogMutation == .reload)
        }
    }

    @Test func transientNetworkOutageDoesNotRecoverReview() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in await debounceGate.wait() }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            networkMonitor.yield(.satisfied())
            await debounceGate.open()

            let attemptedRecovery = await waitUntil(timeout: .milliseconds(100)) {
                let commands = await backend.recordedCommands()
                return commands.contains { command in
                    if case .beginReviewRecovery = command {
                        true
                    } else {
                        false
                    }
                }
            }
            #expect(attemptedRecovery == false)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .beginReviewRecovery = command {
                    true
                } else {
                    false
                }
            } == false)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result
            #expect(read.core.lifecycle.status == .succeeded)
        }
    }

    @Test func sustainedNetworkOutageInterruptsForRecoveryWithoutTerminalJob() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))

            let running = try store.readReview(jobID: "job-1")
            #expect(running.core.lifecycle.status == .running)
            #expect(running.core.output.summary == "Network unavailable; waiting to reconnect.")
            _ = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            await backend.yield(.cancelled("Stop"))
            _ = try await result
        }
    }

    @Test func networkRecoveryWaitDiscardsOldAttemptCompletion() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            _ = try await running

            await backend.yield(.message("completed review text"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: nil), for: initialRun)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let final = try await store.awaitReview(sessionID: "session-1", jobID: "job-1", timeout: .seconds(1))

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(final.core.run.turnID == "turn-2")
            #expect(final.core.output.lastAgentMessage == "recovered review")
            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .resumeReviewRecovery = command {
                    true
                } else {
                    false
                }
            })
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("completed review text") == false)
        }
    }

    @Test func networkRecoveryDiscardsOldAttemptEventsDuringRecoverySettle() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let settleGate = AsyncGate()
        let sleeper = ControlledTestSleeper(gate: settleGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in await sleeper.sleep() }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            await sleeper.blockFutureSleeps()
            networkMonitor.yield(.satisfied())
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.output.summary == "Network restored; restarting review."
            })

            await backend.yield(.message("completed during settle"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: nil), for: initialRun)
            await settleGate.open()
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .resumeReviewRecovery = command {
                    true
                } else {
                    false
                }
            })
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("completed during settle") == false)
        }
    }

    @Test func networkRecoveryRepeatedSatisfiedSnapshotsRestartAfterLatestSettle() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let settleGate = AsyncGate()
        let sleeper = ControlledTestSleeper(gate: settleGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in await sleeper.sleep() }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            await sleeper.blockFutureSleeps()
            networkMonitor.yield(.satisfied())
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.output.summary == "Network restored; restarting review."
            })
            networkMonitor.yield(.satisfied())
            await settleGate.open()
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryClosesActiveCommandsAsCanceled() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            await backend.yield(.logEntry(
                kind: .command,
                text: "$ git diff",
                groupID: "cmd-1",
                replacesGroup: true,
                metadata: .init(
                    sourceType: "commandExecution",
                    status: "inProgress",
                    itemID: "cmd-1",
                    command: "git diff",
                    startedAt: Date(timeIntervalSince1970: 1),
                    commandStatus: "inProgress"
                )
            ), for: initialRun)

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            _ = try await running
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)

            let final = try await store.awaitReview(sessionID: "session-1", jobID: "job-1", timeout: .seconds(1))
            let commandLogs = try #require(store.job(id: "job-1"))
                .logEntries
                .filter { $0.kind == .command && $0.groupID == "cmd-1" }
            let closed = try #require(commandLogs.last)

            #expect(final.core.lifecycle.status == .succeeded)
            #expect(commandLogs.count == 2)
            #expect(closed.metadata?.status == "canceled")
            #expect(closed.metadata?.commandStatus == "canceled")
        }
    }

    @Test func networkRecoveryUsesActualStartedTurn() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-response",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-recovered",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            await backend.yield(.started(
                turnID: "turn-actual",
                reviewThreadID: "review-thread-1",
                model: "gpt-5"
            ), for: initialRun)
            #expect(await waitUntil {
                store.job(id: "job-1")?.core.run.turnID == "turn-actual"
            })

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            let commandsAfterInterrupt = await backend.recordedCommands()
            let interruptedRuns = commandsAfterInterrupt.compactMap { command -> CodexReviewBackendModel.Review.Run? in
                if case .beginReviewRecovery(let run, _) = command {
                    return run
                }
                return nil
            }
            #expect(interruptedRuns.last?.turnID == "turn-actual")

            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            let commandsAfterRecovery = await backend.recordedCommands()
            let recoveredFromRuns = commandsAfterRecovery.compactMap { command -> CodexReviewBackendModel.Review.Run? in
                if case .resumeReviewRecovery(let token, _) = command {
                    return token.interruptedRun
                }
                return nil
            }
            #expect(recoveredFromRuns.last?.turnID == "turn-actual")

            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-recovered")
        }
    }

    @Test func networkRecoveryRestartsReviewOnSameJobAndSucceeds() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            await backend.yield(.message("stale aborted output"), for: initialRun)
            await backend.yield(.cancelled("Network lost"), for: initialRun)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            #expect(await waitUntil {
                guard let read = try? store.readReview(jobID: "job-1") else {
                    return false
                }
                return read.core.run.turnID == "turn-2"
            })
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.run.threadID == "thread-1")
            #expect(read.core.output.lastAgentMessage == "recovered review")
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("Network unavailable; waiting to reconnect."))
            #expect(logText.contains("Network restored; restarting review."))
            #expect(logText.contains("stale aborted output") == false)
        }
    }

    @Test func networkRecoveryClearsAbandonedAttemptOutputBeforeRecoveredCompletion() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)

            await backend.yield(.messageDelta("stale ", itemID: "message-1"), for: initialRun)
            await backend.yield(.messageDelta("output", itemID: "message-1"), for: initialRun)
            try #require(await StoreSnapshotProbe(store: store).waitUntil(timeout: .seconds(2)) {
                $0.job("job-1")?.lastAgentMessage == "stale output"
            } != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.messageDelta("fresh review", itemID: "message-1"), for: recoveredRun)
            await backend.yield(.completed(summary: "Succeeded.", result: nil), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "fresh review")
            #expect(read.core.output.hasFinalReview)
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("stale output") == false)
            #expect(logText.contains("fresh review"))
        }
    }

    @Test func networkRecoveryIgnoresStaleCompletionAfterRecoveredSubscriptionStarts() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "stale review"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)

            let read = try await result
            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryIgnoresStaleTerminalQueuedWhileRestarting() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdResumeReviewRecovery(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            await backend.yield(.cancelled("Network lost"), for: initialRun)
            await recoverGate.open()
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func networkRecoveryResubscribesWhenInterruptedEventStreamFinished() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            await backend.finishEvents(for: initialRun)
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func cancellationWhileRecoveryRestartIsInFlightStopsRecoveredRun() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let recoverGate = AsyncGate()
        await backend.holdResumeReviewRecovery(with: recoverGate)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))

            let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            #expect(cancel.cancelled)
            await recoverGate.open()

            let read = try await result
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.run.turnID == "turn-1")

            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                initialRun,
                .init(message: "Stop")
            )) == false)
            #expect(commands.contains(.interruptReview(
                recoveredRun,
                .init(message: "Stop")
            )))
            #expect(commands.contains(.cleanupReview(recoveredRun)))
        }
    }

    @Test func cancellationAfterRecoveryEventStreamFinishesWakesWorker() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            _ = try await running
            await backend.finishEvents(for: initialRun)

            let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            let cleanedUp = await waitUntil {
                store.reviewWorkerTasks["job-1"] == nil && store.activeRuns["job-1"] == nil
            }
            let read = try store.readReview(jobID: "job-1")

            #expect(cancel.cancelled)
            #expect(cleanedUp)
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Stop")
        }
    }

    @Test func runtimeStopLocalCancellationDetachesWorker() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped."),
                cancelWorkers: false
            )
            let cancelled = try store.readReview(jobID: "job-1")

            #expect(locallyCancelledJobIDs == ["job-1"])
            #expect(cancelled.core.lifecycle.status == .cancelled)
            #expect(store.reviewWorkerTasks["job-1"] != nil)
            #expect(store.activeRuns["job-1"] == run)

            store.cancelAndDetachReviewWorkersForRuntimeStop(jobIDs: locallyCancelledJobIDs)

            #expect(store.reviewWorkerTasks["job-1"] == nil)
            #expect(store.activeRuns["job-1"] == nil)
        }
    }

    @Test func stopInterruptsActiveReviewBeforeMarkingJobStopped() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.start()
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let stopTask = Task { @MainActor in
                await store.stop()
            }
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            let inFlight = try store.readReview(jobID: "job-1")

            #expect(inFlight.core.lifecycle.status == .running)
            await interruptGate.open()
            await stopTask.value

            let stopped = try store.readReview(jobID: "job-1")
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(run, .init(message: "Review runtime stopped."))))
            #expect(stopped.core.lifecycle.status == .cancelled)
            #expect(store.activeRuns["job-1"] == nil)
            #expect(store.reviewWorkerTasks["job-1"] == nil)
        }
    }

    @Test func runtimeStopDetachesNetworkRecoveryWaitingWorker() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            _ = try await running

            let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped."),
                cancelWorkers: false
            )
            store.cancelAndDetachReviewWorkersForRuntimeStop(jobIDs: locallyCancelledJobIDs)

            #expect(store.reviewWorkerTasks["job-1"] == nil)
            #expect(store.activeRuns["job-1"] == nil)
            #expect(store.reviewRecoveryWaitingJobIDs.contains("job-1") == false)
        }
    }

    @Test func runtimeStopCanDrainDetachedWorkerCleanup() async throws {
        let run = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: run)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let running = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main")),
                waitTimeout: .milliseconds(20)
            )
            _ = try await running

            let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped."),
                cancelWorkers: false
            )
            store.cancelAndDetachReviewWorkersForRuntimeStop(jobIDs: locallyCancelledJobIDs)

            #expect(await store.drainRuntimeStopDetachedReviewWorkers(timeout: .seconds(2)))
            #expect(store.runtimeStopDetachedReviewWorkerTasks["job-1"] == nil)
            #expect(await backend.recordedCommands().contains(.cleanupReview(run)))
        }
    }

    @Test func runtimeStopDetachLetsStartReviewReturnWhenBackendStartIsStuck() async throws {
        let backend = FakeCodexReviewBackend()
        let startReviewGate = AsyncGate()
        await backend.holdStartReview(with: startReviewGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
                )
            }
            try await backend.waitForStartReview(timeout: .seconds(2))

            let locallyCancelledJobIDs = store.cancelActiveReviewsLocallyForRuntimeStop(
                reason: .system(message: "Review runtime stopped."),
                cancelWorkers: false
            )
            store.cancelAndDetachReviewWorkersForRuntimeStop(jobIDs: locallyCancelledJobIDs)
            let resultBeforeStartReviewUnblocked = try await waitForTaskValue(running, timeout: .seconds(1))
            await startReviewGate.open()
            let result = try #require(resultBeforeStartReviewUnblocked)

            #expect(locallyCancelledJobIDs == ["job-1"])
            #expect(result.core.lifecycle.status == .cancelled)
            #expect(store.reviewWorkerTasks["job-1"] == nil)
            #expect(store.activeRuns["job-1"] == nil)
        }
    }

    @Test func cancellationDuringNetworkRecoveryStopsWhenEventStreamFinishes() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            _ = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            await backend.finishEvents(for: initialRun)

            let read = try await result
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.lifecycle.cancellation?.message == "Stop")
        }
    }

    @Test func networkRecoveryIgnoresOldAttemptEventsAfterRecoveryBegins() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .unsatisfied))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            await backend.yield(.message("stale old attempt output"), for: initialRun)
            await backend.yield(.completed(summary: "Succeeded.", result: nil), for: initialRun)

            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))
            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.run.turnID == "turn-2")
            #expect(read.core.output.lastAgentMessage == "recovered review")
            let logText = try store.readReview(jobID: "job-1").logs.map(\.text).joined(separator: "\n")
            #expect(logText.contains("stale old attempt output") == false)
        }
    }

    @Test func userCancellationWinsOverPendingNetworkRecovery() async throws {
        let backend = FakeCodexReviewBackend()
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in await debounceGate.wait() })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            _ = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            await debounceGate.open()
            await backend.yield(.cancelled("Stop"))
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .beginReviewRecovery = command {
                    true
                } else {
                    false
                }
            } == false)
            #expect(commands.contains { command in
                if case .resumeReviewRecovery = command {
                    true
                } else {
                    false
                }
            } == false)
        }
    }

    @Test func recoveryFailureFailsReviewAndLogsError() async throws {
        let backend = FakeCodexReviewBackend()
        await backend.failRecovery(message: "Rollback failed")
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(sleep: { _ in })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            networkMonitor.yield(.init(status: .requiresConnection))
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            let read = try await result

            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.lifecycle.errorMessage == "Rollback failed")
            #expect(read.logs.contains { $0.kind == .error && $0.text == "Rollback failed" })
        }
    }

    @Test func cancelRunningReviewClosesActiveCommandLog() async throws {
        let backend = FakeCodexReviewBackend()
        let completedAt = Date(timeIntervalSince1970: 10)
        let startedAt = Date(timeIntervalSince1970: 6)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            clock: .init(now: { completedAt })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = CodexReviewJob.makeForTesting(
                id: "job-1",
                cwd: "/tmp/project",
                targetSummary: "Uncommitted changes",
                threadID: "thread-1",
                turnID: "turn-1",
                status: .running,
                startedAt: startedAt,
                summary: "Running",
                logEntries: [
                    .init(
                        kind: .command,
                        groupID: "cmd-1",
                        replacesGroup: true,
                        text: "$ git diff",
                        metadata: .init(
                            sourceType: "commandExecution",
                            status: "inProgress",
                            itemID: "cmd-1",
                            command: "git diff",
                            startedAt: startedAt,
                            commandStatus: "inProgress"
                        ),
                        timestamp: startedAt
                    )
                ]
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [running]
            )

            let cancel = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            let read = try store.readReview(jobID: "job-1", logFilter: .all)
            let commandLogs = try #require(store.job(id: "job-1"))
                .logEntries
                .filter { $0.kind == .command && $0.groupID == "cmd-1" }
            let closed = try #require(commandLogs.last)

            #expect(cancel.cancelled)
            #expect(read.core.lifecycle.status == .cancelled)
            #expect(commandLogs.count == 2)
            #expect(closed.replacesGroup)
            #expect(closed.metadata?.status == "canceled")
            #expect(closed.metadata?.commandStatus == "canceled")
            #expect(closed.metadata?.command == "git diff")
            #expect(closed.metadata?.startedAt == startedAt)
            #expect(closed.metadata?.completedAt == completedAt)
            #expect(closed.metadata?.durationMs == 4_000)
        }
    }

    @Test func sessionScopedCancelRejectsJobFromDifferentSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )

            await #expect(throws: (any Error).self) {
                try await store.cancelReview(
                    jobID: "job-1",
                    sessionID: "session-2",
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            #expect(try store.readReview(jobID: "job-1").cancellable)

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result

            let commands = await backend.recordedCommands()
            #expect(commands.contains {
                if case .interruptReview = $0 {
                    return true
                }
                return false
            } == false)
        }
    }

    @Test func cancelledReviewStaysCancelledWhenStreamClosesWithError() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            _ = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.finishEvents(throwing: StreamClosedError())
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
        }
    }

    @Test func failedReviewPreservesBufferedEventsBeforeStreamError() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            await backend.yield(.message("partial review"))
            await backend.finishEvents(throwing: StreamClosedError())
            let read = try await result

            #expect(read.core.lifecycle.status == .failed)
            #expect(read.core.output.lastAgentMessage == "partial review")
            #expect(read.logs.map(\.text).contains("partial review"))
        }
    }

    @Test func pendingNetworkOutageDefersStreamFailureUntilRecovery() async throws {
        let initialRun = CodexReviewBackendModel.Review.Run(
            threadID: "thread-1",
            turnID: "turn-1",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let recoveredRun = CodexReviewBackendModel.Review.Run(
            attemptID: "attempt-recovered",
            threadID: "thread-1",
            turnID: "turn-2",
            reviewThreadID: "review-thread-1",
            model: "gpt-5"
        )
        let backend = FakeCodexReviewBackend(nextRun: initialRun)
        await backend.setNextRecoveredRun(recoveredRun)
        let networkMonitor = ManualCodexReviewNetworkMonitor()
        let outageSleepStarted = AsyncGate()
        let debounceGate = AsyncGate()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" }),
            networkMonitor: networkMonitor,
            networkRecoveryPolicy: .init(
                outageDebounce: .seconds(10),
                recoverySettle: .seconds(1),
                sleep: { _ in
                    await outageSleepStarted.open()
                    await debounceGate.wait()
                }
            )
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)

            networkMonitor.yield(.init(status: .unsatisfied))
            await outageSleepStarted.wait()
            await backend.finishEvents(throwing: StreamClosedError(), for: initialRun)

            let failedBeforeOutageConfirmed = await StoreSnapshotProbe(store: store)
                .waitUntilJobStatus(.failed, jobID: "job-1", timeout: .milliseconds(100)) != nil
            #expect(failedBeforeOutageConfirmed == false)

            await debounceGate.open()
            try await backend.waitForBeginReviewRecovery(timeout: .seconds(2))
            networkMonitor.yield(.satisfied())
            try await backend.waitForResumeReviewRecovery(timeout: .seconds(2))
            try #require(await waitForRunAttemptActivation(store: store, run: recoveredRun))

            await backend.yield(.completed(summary: "Succeeded.", result: "recovered review"), for: recoveredRun)
            let read = try await result

            #expect(read.core.lifecycle.status == .succeeded)
            #expect(read.core.output.lastAgentMessage == "recovered review")
        }
    }

    @Test func reviewStartCancellationInterruptsBackendRun() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            await backend.finishEvents(throwing: CancellationError())
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                .init(message: "Cancellation requested.")
            )))
        }
    }

    @Test func reviewStartTaskCancellationInterruptsBackendRun() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let task = Task { @MainActor in
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
                )
            }
            task.cancel()
            let read = try await task.value

            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                .init(message: "Cancellation requested.")
            )))
        }
    }

    @Test func failedInterruptClearsCancellationRequestState() async throws {
        let backend = FakeCodexReviewBackend()
        await backend.failInterrupts(message: "Interrupt failed")
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            await #expect(throws: FakeCodexReviewBackendError.self) {
                try await store.cancelReview(
                    jobID: "job-1",
                    cancellation: .mcpClient(message: "Stop")
                )
            }
            let readAfterFailure = try store.readReview(jobID: "job-1")

            #expect(readAfterFailure.cancellable)
            #expect(readAfterFailure.core.lifecycle.cancellation == nil)
            #expect(readAfterFailure.core.output.summary == "Failed to cancel review: Interrupt failed")

            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            _ = try await result
        }
    }

    @Test func cancelledReviewIgnoresBufferedTerminalEvents() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .baseBranch("main"))
            )
            try #require(await StoreSnapshotProbe(store: store).waitUntilJobStatus(.running, jobID: "job-1") != nil)
            _ = try await store.cancelReview(
                jobID: "job-1",
                cancellation: .mcpClient(message: "Stop")
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "late result"))
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
            #expect(read.core.output.lastAgentMessage == nil)
        }
    }

    @Test func terminalEventDuringPendingCancellationKeepsCancelledState() async throws {
        let backend = FakeCodexReviewBackend()
        let interruptGate = AsyncGate()
        await backend.holdInterruptReview(with: interruptGate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            async let cancel = store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            try await backend.waitForInterruptReview(timeout: .seconds(2))
            await backend.yield(.completed(summary: "Reviewer failed to output a response.", result: nil))
            await interruptGate.open()
            _ = try await cancel
            let read = try await result

            #expect(read.core.lifecycle.status == .cancelled)
            #expect(read.core.output.summary == "Stop")
            #expect(read.core.output.hasFinalReview == false)
        }
    }

    @Test func cancelDuringReviewStartupInterruptsAfterRunBecomesAvailable() async throws {
        let backend = FakeCodexReviewBackend()
        let gate = AsyncGate()
        await backend.holdStartReview(with: gate)
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            try await backend.waitForStartReview(timeout: .seconds(2))
            let cancel = try await store.cancelReview(jobID: "job-1", cancellation: .mcpClient(message: "Stop"))
            let cancelledDuringStartup = try #require(store.jobs.first)
            #expect(cancel.core.lifecycle.status == .cancelled)
            #expect(cancelledDuringStartup.core.lifecycle.status == .cancelled)
            await gate.open()
            let read = try await result

            #expect(cancel.cancelled)
            #expect(read.core.lifecycle.status == .cancelled)
            let commands = await backend.recordedCommands()
            #expect(commands.contains(.interruptReview(
                .init(threadID: "thread-1", turnID: "turn-1", reviewThreadID: "review-thread-1"),
                .init(message: "Stop")
            )))
            #expect(commands.contains(.cleanupReview(.init(
                threadID: "thread-1",
                turnID: "turn-1",
                reviewThreadID: "review-thread-1"
            ))))
        }
    }

    @Test func closedSessionRejectsNewReviews() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.closeSession("session-1")

            await #expect(throws: (any Error).self) {
                try await store.startReview(
                    sessionID: "session-1",
                    request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
                )
            }
        }
    }

    @Test func closeActiveReviewSessionsCancelsJobsWithoutClosingMCPServerSession() async throws {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend),
            idGenerator: .init(next: { "job-1" })
        )
        try await withStoreCommandTestCleanup(backend: backend, store: store) {
            let running = CodexReviewJob.makeForTesting(
                id: "running-job",
                sessionID: "session-1",
                cwd: "/tmp/project",
                targetSummary: "Running",
                status: .running,
                summary: "Running"
            )
            store.loadForTesting(
                serverState: .running,
                workspaces: [.init(cwd: "/tmp/project")],
                jobs: [running]
            )

            await store.closeActiveReviewSessions(reason: .system(message: "Account switched."))

            #expect(running.core.lifecycle.status == .cancelled)
            async let result = store.startReview(
                sessionID: "session-1",
                request: .init(cwd: "/tmp/project", target: .uncommittedChanges)
            )
            await backend.yield(.completed(summary: "Succeeded.", result: "review text"))
            let read = try await result

            #expect(read.jobID == "job-1")
            #expect(read.core.lifecycle.status == .succeeded)
        }
    }

    @Test func authAndSettingsUseSingleBackendContract() async throws {
        let backend = FakeCodexReviewBackend(settings: .init(model: "gpt-5"))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.refreshSettings()

            #expect(store.settings.effectiveModel == "gpt-5")
        }
    }

    @Test func initialActiveAccountKeySelectsPersistedAccount() {
        let active = CodexAccount(email: "active@example.com")
        let inactive = CodexAccount(email: "inactive@example.com")
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(
                reviewBackend: backend,
                seed: .init(
                    initialAccounts: [inactive, active],
                    initialActiveAccountKey: active.accountKey
                )
            )
        )

        #expect(store.auth.persistedAccounts.map(\.accountKey) == [
            inactive.accountKey,
            active.accountKey,
        ])
        #expect(store.auth.persistedActiveAccountKey == active.accountKey)
        #expect(store.auth.selectedAccount?.accountKey == active.accountKey)
    }

    @Test func switchActionsAreUnavailableForSelectedAccount() async throws {
        let selectedAccount = CodexAccount(email: "selected@example.com", planType: "pro")
        let otherAccount = CodexAccount(email: "other@example.com", planType: "plus")
        let backend = SwitchRecordingBackend()
        let store = CodexReviewStore.makeTestingStore(backend: backend)
        store.loadForTesting(
            serverState: .running,
            account: selectedAccount,
            persistedAccounts: [selectedAccount, otherAccount],
            workspaces: []
        )
        let displayedSelectedAccount = try #require(store.auth.selectedAccount)
        let displayedOtherAccount = try #require(
            store.auth.persistedAccounts.first { $0.accountKey == otherAccount.accountKey }
        )

        #expect(store.switchActionIsDisabled(for: displayedSelectedAccount))
        #expect(store.switchActionRequiresRunningJobsConfirmation(for: displayedSelectedAccount) == false)
        #expect(store.switchActionIsDisabled(for: displayedOtherAccount) == false)
        #expect(store.switchActionRequiresRunningJobsConfirmation(for: displayedOtherAccount))

        store.requestSwitchAccountFromUserAction(displayedSelectedAccount)
        await Task.yield()
        #expect(backend.switchRequests.isEmpty)

        try await store.switchAccount(displayedSelectedAccount)
        #expect(backend.switchRequests.isEmpty)

        try await store.switchAccount(displayedOtherAccount)
        #expect(backend.switchRequests == [displayedOtherAccount.accountKey])
    }

    @Test func fakeBackendPreservesSettingsCatalogWhenApplyingOverrides() async throws {
        let model = CodexReviewSettings.ModelCatalogItem(
            id: "gpt-5.5",
            model: "gpt-5.5",
            displayName: "GPT-5.5",
            hidden: false,
            supportedReasoningEfforts: [
                .init(reasoningEffort: .medium, description: "Balanced"),
            ],
            defaultReasoningEffort: .medium,
            supportedServiceTiers: [.fast],
            isDefault: true
        )
        let backend = FakeCodexReviewBackend(settings: .init(
            fallbackModel: "gpt-5.5",
            models: [model]
        ))
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            await store.refreshSettings()
            await store.updateSettingsReasoningEffort(.medium)

            #expect(store.settings.effectiveModel == "gpt-5.5")
            #expect(store.settings.models == [model])
        }
    }

    @Test func primaryAuthenticationActionIsAvailableWhenRuntimeCanRecoverOrStartLogin() {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )

        store.loadForTesting(serverState: .stopped, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.loadForTesting(serverState: .starting, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction == false)

        store.loadForTesting(serverState: .running, authPhase: .signedOut, workspaces: [])
        #expect(store.canPerformPrimaryAuthenticationAction)

        store.auth.updatePhase(.signingIn(.init(title: "Sign in", detail: "Open browser.")))
        store.transitionToFailed("Runtime failed.")
        #expect(store.canPerformPrimaryAuthenticationAction)
    }

    @Test func primaryAuthenticationActionRestartsRecoverableRuntimeBeforeLogin() async {
        let backend = FakeCodexReviewBackend()
        let store = CodexReviewStore.makeTestingStore(
            backend: TestingCodexReviewStoreBackend(reviewBackend: backend)
        )
        await withStoreCommandTestCleanup(backend: backend, store: store) {
            store.loadForTesting(serverState: .failed("Runtime failed."), authPhase: .signedOut, workspaces: [])

            await store.performPrimaryAuthenticationAction()

            #expect(store.serverState == .running)
            #expect(store.auth.isAuthenticating)
            let commands = await backend.recordedCommands()
            #expect(commands.contains { command in
                if case .startLogin = command {
                    return true
                }
                return false
            })
        }
    }
}

@MainActor
private final class SwitchRecordingBackend: PreviewCodexReviewStoreBackend {
    private(set) var switchRequests: [String] = []

    override func switchAccount(
        auth _: CodexReviewAuthModel,
        accountKey: String
    ) async throws {
        switchRequests.append(accountKey)
    }

    override func requiresCurrentSessionRecovery(
        auth _: CodexReviewAuthModel,
        accountKey _: String
    ) -> Bool {
        true
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while await condition() == false {
        if clock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
private func waitForRunAttemptActivation(
    store: CodexReviewStore,
    run: CodexReviewBackendModel.Review.Run,
    timeout: Duration = .seconds(2)
) async -> Bool {
    await StoreSnapshotProbe(store: store)
        .waitUntilRunAttempt(run.attemptID, timeout: timeout) != nil
}

private func waitForTaskValue<T: Sendable>(
    _ task: Task<T, any Error>,
    timeout: Duration
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await task.value
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            return nil
        }
        let result = try await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

@MainActor
private func withStoreCommandTestCleanup(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore,
    operation: () async throws -> Void
) async rethrows {
    do {
        try await operation()
    } catch {
        await cleanupStoreCommandTest(backend: backend, store: store)
        throw error
    }
    await cleanupStoreCommandTest(backend: backend, store: store)
}

@MainActor
private func cleanupStoreCommandTest(
    backend: FakeCodexReviewBackend,
    store: CodexReviewStore
) async {
    await backend.finishEventMailboxes()
    await store.cancelAndDrainReviewWorkersForTesting()
    await backend.finishEventMailboxes()
}

private struct StreamClosedError: Error {}

private actor ControlledTestSleeper {
    private let gate: AsyncGate
    private var shouldBlock = false

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func blockFutureSleeps() {
        shouldBlock = true
    }

    func sleep() async {
        if shouldBlock {
            await gate.wait()
        }
    }
}

private final class MutableTestClock: @unchecked Sendable {
    var current: Date

    init(_ current: Date) {
        self.current = current
    }

    func now() -> Date {
        current
    }
}
