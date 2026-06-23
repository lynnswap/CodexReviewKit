import Foundation

extension CodexThread {
    public var events: CodexThreadEventSequence {
        .init {
            AsyncThrowingStream { continuation in
                Task {
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
            }
        }
    }

    public var messages: CodexThreadMessageSequence {
        .init(events: events)
    }

    public var transcriptUpdates: CodexThreadTranscriptSequence {
        .init(events: events)
    }

    public var logEntries: CodexThreadLogSequence {
        .init(events: events)
    }

    public func respond(
        to prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await streamResponse(to: prompt, options: options).collect()
    }

    public func respond(
        to prompt: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponse {
        try await respond(to: CodexPrompt(prompt), options: options)
    }

    public func respond(
        options: CodexGenerationOptions = .init(),
        @CodexPromptBuilder prompt: () throws -> CodexPrompt
    ) async throws -> CodexResponse {
        try await respond(to: try prompt(), options: options)
    }

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

    public func streamResponse(
        to prompt: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexResponseStream {
        try await streamResponse(to: CodexPrompt(prompt), options: options)
    }

    public func streamResponse(
        options: CodexGenerationOptions = .init(),
        @CodexPromptBuilder prompt: () throws -> CodexPrompt
    ) async throws -> CodexResponseStream {
        try await streamResponse(to: try prompt(), options: options)
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

    public func rename(to name: String) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Name.Set.Request(
                params: .init(threadID: id.rawValue, name: name)
            ))
    }

    public func compact() async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Compact.Start.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    public func archive() async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Archive.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    public func unarchive() async throws -> CodexThreadSnapshot {
        let response = try await client.send(
            AppServerAPI.Thread.Unarchive.Request(
                params: .init(threadID: id.rawValue)
            ))
        return CodexAppServer.threadSnapshot(from: response.thread)
    }

    public func rollback(turnCount: Int = 1) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Rollback.Request(
                params: .init(threadID: id.rawValue, numTurns: turnCount)
            ))
    }

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
                cwd: options.cwd?.path,
                effort: options.effort,
                model: options.model,
                sandboxPolicy: options.sandbox?.turnSandboxPolicy,
                serviceTier: options.serviceTier,
                summary: options.summary
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
                Task {
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

    package func interrupt() async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Turn.Interrupt.Request(
                params: .init(threadID: threadID.rawValue, turnID: id.rawValue)
            ))
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
