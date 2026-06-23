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

    public var transcript: CodexThreadTranscriptSequence {
        .init(events: events)
    }

    public var logEntries: CodexThreadLogSequence {
        .init(events: events)
    }

    public func respond(
        to prompt: CodexPrompt,
        options: CodexTurn.Options = .init()
    ) async throws -> CodexTurnResult {
        let turn = try await startTurn(prompt, options: options)
        return try await turn.result()
    }

    public func respond(
        to prompt: String,
        options: CodexTurn.Options = .init()
    ) async throws -> CodexTurnResult {
        try await respond(to: CodexPrompt(prompt), options: options)
    }

    public func startTurn(
        _ prompt: CodexPrompt,
        options: CodexTurn.Options = .init()
    ) async throws -> CodexTurn {
        let response = try await client.send(
            AppServerAPI.Turn.Start.Request(
                params: .init(
                    threadID: id.rawValue,
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
            threadID: id,
            client: client,
            router: router
        )
    }

    public func startTurn(
        _ prompt: String,
        options: CodexTurn.Options = .init()
    ) async throws -> CodexTurn {
        try await startTurn(CodexPrompt(prompt), options: options)
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

extension CodexTurn {
    public var events: CodexTurnEventSequence {
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

    public var progress: CodexTurnProgressSequence {
        .init(events: events)
    }

    public func result() async throws -> CodexTurnResult {
        try await CodexTurnResultCollector.collect(from: events)
    }

    public func steer(with prompt: CodexPrompt) async throws {
        let _: AppServerAPI.Turn.Steer.Response = try await client.send(
            AppServerAPI.Turn.Steer.Request(
                params: .init(
                    threadID: threadID.rawValue,
                    expectedTurnID: id.rawValue,
                    input: prompt.appServerInput
                )
            ))
    }

    public func steer(with prompt: String) async throws {
        try await steer(with: CodexPrompt(prompt))
    }

    public func interrupt() async throws {
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
