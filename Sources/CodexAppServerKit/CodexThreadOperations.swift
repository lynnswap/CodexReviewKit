import Foundation

extension CodexThread {
    /// Thread-scoped events emitted by the app-server.
    ///
    /// The sequence replays buffered events for this thread before yielding
    /// live notifications. It finishes when the app-server reports the thread
    /// as closed or when the app-server connection closes.
    public var events: CodexThreadEventSequence {
        .init {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let stream = await router.events(for: id)
                    do {
                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
    }

    /// Agent messages emitted by this thread.
    ///
    /// This sequence is derived from `events` and is useful when callers only
    /// need the conversational output rather than every item lifecycle event.
    public var messages: CodexThreadMessageSequence {
        .init(events: events)
    }

    /// Incremental transcript snapshots derived from this thread's events.
    public var transcriptUpdates: CodexThreadTranscriptSequence {
        .init(events: events)
    }

    /// Log-oriented item events for this thread.
    ///
    /// This includes command, tool, file-change, diagnostic, and unknown
    /// app-server items that are useful for review logs or progress views.
    public var logEntries: CodexThreadLogSequence {
        .init(events: events)
    }

    /// Sends a prompt to the thread and waits for the final response.
    ///
    /// Use `streamResponse(to:options:)` when the caller needs incremental
    /// progress, transcript updates, steering, or interruption.
    ///
    /// - Parameters:
    ///   - prompt: The structured prompt to send.
    ///   - options: Per-turn generation options.
    /// - Returns: The completed response collected from app-server events.
    public func respond(
        to prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await streamResponse(to: prompt, options: options).collect()
    }

    /// Sends a text prompt to the thread and waits for the final response.
    public func respond(
        to prompt: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await respond(to: CodexPrompt(prompt), options: options)
    }

    /// Builds a structured prompt, sends it to the thread, and waits for the final response.
    public func respond(
        options: CodexGenerationOptions = .init(),
        @CodexPromptBuilder prompt: () throws -> CodexPrompt
    ) async throws -> CodexResponse {
        try await respond(to: try prompt(), options: options)
    }

    /// Sends a prompt and returns a live response stream.
    ///
    /// The returned stream exposes events, progress, transcript updates, the
    /// collected result, and Codex-specific controls such as steer and
    /// interrupt.
    ///
    /// - Parameters:
    ///   - prompt: The structured prompt to send.
    ///   - options: Per-turn generation options.
    /// - Returns: A live response stream for the started turn.
    public func streamResponse(
        to prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponseStream {
        let turn = try await startTurn(prompt, options: options)
        return .init(
            turn: turn,
            transcriptErrorHandlingPolicy: options.transcriptErrorHandlingPolicy
        )
    }

    /// Sends a text prompt and returns a live response stream.
    public func streamResponse(
        to prompt: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponseStream {
        try await streamResponse(to: CodexPrompt(prompt), options: options)
    }

    /// Builds a structured prompt, sends it, and returns a live response stream.
    public func streamResponse(
        options: CodexGenerationOptions = .init(),
        @CodexPromptBuilder prompt: () throws -> CodexPrompt
    ) async throws -> CodexResponseStream {
        try await streamResponse(to: try prompt(), options: options)
    }

    /// Starts a Codex code review in this thread.
    ///
    /// The returned session exposes both the response stream for the review
    /// turn and thread-level event streams, including log entries. When the
    /// app-server uses a detached review thread, those event streams are bound
    /// to that review thread.
    ///
    /// - Parameters:
    ///   - target: The repository changes or custom instructions to review.
    ///   - delivery: Whether the app-server should run the review inline or in a detached review thread.
    ///   - transcriptErrorHandlingPolicy: How collection should treat transcript errors.
    /// - Returns: A live review session.
    public func startReview(
        target: CodexReviewTarget,
        delivery: CodexReviewDelivery = .inline,
        transcriptErrorHandlingPolicy: CodexTranscriptErrorHandlingPolicy = .preserveTranscript
    ) async throws -> CodexReviewSession {
        let response = try await client.send(AppServerAPI.Review.Start.Request(
            params: .init(threadID: id.rawValue, target: target, delivery: delivery)
        ))
        let reviewThreadID = response.reviewThreadID.map(CodexThreadID.init(rawValue:)) ?? id
        let turnID = CodexTurnID(rawValue: response.turnID)
        await router.seedReviewTurn(turnID, reviewThreadID: reviewThreadID)
        let turn = CodexTurn(
            id: turnID,
            threadID: reviewThreadID,
            client: client,
            router: router
        )
        let eventThread = CodexThread(
            id: reviewThreadID,
            workspace: workspace,
            model: model,
            client: client,
            router: router
        )
        return .init(
            threadID: id,
            turnID: turn.id,
            reviewThreadID: reviewThreadID,
            response: .init(
                turn: turn,
                transcriptErrorHandlingPolicy: transcriptErrorHandlingPolicy
            ),
            eventThread: eventThread
        )
    }

    package func startTurn(
        _ prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexTurn {
        try await startCodexTurn(
            threadID: id,
            prompt: prompt,
            options: options,
            client: client,
            router: router
        )
    }

    /// Reads the current thread snapshot.
    ///
    /// - Parameter includeTurns: Whether to include turn summaries in the snapshot.
    /// - Returns: The current app-server snapshot for this thread.
    public func read(includeTurns: Bool = false) async throws -> CodexThreadSnapshot {
        let response = try await client.send(
            AppServerAPI.Thread.Read.Request(
                params: .init(threadID: id.rawValue, includeTurns: includeTurns)
            ))
        return .init(
            id: .init(rawValue: response.thread.id),
            workspace: response.thread.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            name: response.thread.name,
            preview: response.thread.preview,
            turns: (response.thread.turns ?? []).map {
                CodexTurnSnapshot(
                    id: .init(rawValue: $0.id),
                    status: $0.status.map(CodexTurnStatus.init(rawValue:)),
                    errorMessage: $0.error?.message
                )
            }
        )
    }

    /// Renames this thread.
    ///
    /// - Parameter name: The new user-visible thread name.
    public func rename(to name: String) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Name.Set.Request(
                params: .init(threadID: id.rawValue, name: name)
            ))
    }

    /// Starts app-server context compaction for this thread.
    public func compact() async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Compact.Start.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Archives this thread.
    public func archive() async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Archive.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Restores this thread from the archive.
    ///
    /// - Returns: The restored thread snapshot.
    public func unarchive() async throws -> CodexThreadSnapshot {
        let response = try await client.send(
            AppServerAPI.Thread.Unarchive.Request(
                params: .init(threadID: id.rawValue)
            ))
        return CodexAppServer.threadSnapshot(from: response.thread)
    }

    /// Rolls this thread back by the specified number of turns.
    ///
    /// - Parameter turnCount: The number of latest turns to remove.
    public func rollback(turnCount: Int = 1) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Rollback.Request(
                params: .init(threadID: id.rawValue, numTurns: turnCount)
            ))
    }

    /// Permanently deletes this thread.
    public func delete() async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Delete.Request(
                params: .init(threadID: id.rawValue)
            ))
    }
}

package func startCodexTurn(
    threadID: CodexThreadID,
    prompt: CodexPrompt,
    options: CodexGenerationOptions = .init(),
    client: AppServerClient,
    router: CodexAppServerNotificationRouter
) async throws -> CodexTurn {
    let response = try await client.send(
        AppServerAPI.Turn.Start.Request(
            params: .init(
                threadID: threadID.rawValue,
                input: prompt.appServerInput,
                approvalPolicy: options.approvalMode?.approvalPolicy,
                approvalsReviewer: options.approvalMode?.approvalsReviewer,
                clientUserMessageID: options.clientUserMessageID,
                cwd: options.cwd?.path,
                effort: options.effort?.rawValue,
                model: options.model,
                outputSchema: options.outputSchema?.appServerJSONValue,
                personality: options.personality?.rawValue,
                sandboxPolicy: options.sandbox?.turnSandboxPolicy,
                serviceTier: options.serviceTier,
                summary: options.summary?.rawValue
            )
        ))
    return CodexTurn(
        id: .init(rawValue: response.turn.id),
        threadID: threadID,
        client: client,
        router: router
    )
}

extension CodexTurn {
    package var events: CodexTurnEventSequence {
        .init {
            AsyncThrowingStream { continuation in
                let task = Task {
                    let stream = await router.events(for: id)
                    do {
                        for try await event in stream {
                            continuation.yield(event)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
    }

    package var progress: CodexTurnProgressSequence {
        .init(events: events)
    }

    package func result() async throws -> CodexResponse {
        try await CodexResponseCollector.collect(from: events)
    }

    package func steer(with prompt: CodexPrompt) async throws {
        let _: AppServerAPI.Turn.Steer.Response = try await client.send(
            AppServerAPI.Turn.Steer.Request(
                params: .init(
                    threadID: threadID.rawValue,
                    expectedTurnID: id.rawValue,
                    input: prompt.appServerInput
                )
            ))
    }

    package func steer(with prompt: String) async throws {
        try await steer(with: CodexPrompt(prompt))
    }

    @discardableResult
    package func interrupt() async throws -> CodexTurnInterruption {
        try await interruptCodexTurn(threadID: threadID, turnID: id, client: client)
    }
}

@discardableResult
package func interruptCodexTurn(
    threadID: CodexThreadID,
    turnID: CodexTurnID?,
    client: AppServerClient,
    willInterruptActiveTurn: (@Sendable (CodexTurnInterruption) async -> Void)? = nil
) async throws -> CodexTurnInterruption {
    do {
        try await sendInterrupt(threadID: threadID, turnID: turnID, client: client)
        return .init(threadID: threadID, turnID: turnID)
    } catch {
        guard let activeTurnID = activeTurnID(from: error),
              activeTurnID != turnID?.rawValue
        else {
            throw error
        }
        let activeTurn = CodexTurnID(rawValue: activeTurnID)
        let interruption = CodexTurnInterruption(threadID: threadID, turnID: activeTurn)
        if let willInterruptActiveTurn {
            await willInterruptActiveTurn(interruption)
        }
        try await sendInterrupt(threadID: threadID, turnID: activeTurn, client: client)
        return interruption
    }
}

private func sendInterrupt(
    threadID: CodexThreadID,
    turnID: CodexTurnID?,
    client: AppServerClient
) async throws {
    let _: EmptyResponse = try await client.send(
        AppServerAPI.Turn.Interrupt.Request(
            params: .init(threadID: threadID.rawValue, turnID: turnID?.rawValue ?? "")
        ))
}

private func activeTurnID(from error: Error) -> String? {
    guard case JSONRPC.Error.responseError(_, let message) = error,
          let range = message.range(of: " but found ")
    else {
        return nil
    }
    return String(message[range.upperBound...])
        .trimmingCharacters(in: CharacterSet(charactersIn: "` ").union(.whitespacesAndNewlines))
        .nonEmpty
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

extension CodexPrompt {
    package var appServerInput: [AppServerAPI.UserInput] {
        parts.map { part in
            switch part {
            case .text(let text):
                .text(text)
            case .imageURL(let url):
                .image(url: url.absoluteString)
            case .localImage(let url):
                .localImage(path: url.path)
            case .skill(let name, let path):
                .skill(name: name, path: path.path)
            case .mention(let name, let path):
                .mention(name: name, path: path.path)
            }
        }
    }
}
