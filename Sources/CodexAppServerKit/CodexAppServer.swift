import Foundation

public actor CodexAppServer {
    public struct Configuration: Sendable {
        public var executable: String?
        public var arguments: [String]?
        public var environment: [String: String]
        public var codexHomeURL: URL?
        public var clientName: String
        public var clientVersion: String

        public init(
            executable: String? = nil,
            arguments: [String]? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            codexHomeURL: URL? = nil,
            clientName: String = "CodexAppServerKit",
            clientVersion: String = "1"
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.codexHomeURL = codexHomeURL
            self.clientName = clientName
            self.clientVersion = clientVersion
        }

        public static let `default` = Configuration()
    }

    private let client: AppServerClient
    private let router: CodexAppServerNotificationRouter

    public init(configuration: Configuration = .default) async throws {
        let transportConfiguration = AppServerProcessTransport.Configuration(
            executable: configuration.executable,
            arguments: configuration.arguments,
            environment: configuration.environment,
            codexHomeURL: configuration.codexHomeURL
                ?? Self.defaultCodexHomeURL(environment: configuration.environment)
        )
        let client = AppServerClient(
            transport: try AppServerProcessTransport(configuration: transportConfiguration))
        _ = try await client.initialize(
            clientName: configuration.clientName,
            clientVersion: configuration.clientVersion
        )
        let router = CodexAppServerNotificationRouter(client: client)
        await router.start()
        self.client = client
        self.router = router
    }

    package init(client: AppServerClient, router: CodexAppServerNotificationRouter) {
        self.client = client
        self.router = router
    }

    public func close() async {
        await router.stop()
        await client.close()
    }

    public func startThread(
        in workspace: URL,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init()
    ) async throws -> CodexThread {
        let approvalMode = options.approvalMode ?? .autoReview
        let response = try await client.send(
            AppServerAPI.Thread.Start.Request(
                params: .init(
                    cwd: workspace.path,
                    model: options.model,
                    modelProvider: options.modelProvider,
                    ephemeral: options.ephemeral,
                    baseInstructions: instructions?.base,
                    developerInstructions: instructions?.developer,
                    approvalPolicy: approvalMode.approvalPolicy,
                    approvalsReviewer: approvalMode.approvalsReviewer,
                    sandbox: options.sandbox?.threadSandboxValue,
                    serviceTier: options.serviceTier
                )
            ))
        return CodexThread(
            id: .init(rawValue: response.threadID),
            workspace: workspace,
            model: response.model ?? options.model,
            client: client,
            router: router
        )
    }

    public func resumeThread(
        _ id: CodexThread.ID,
        options: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexThread {
        let response = try await client.send(
            AppServerAPI.Thread.Resume.Request(
                threadID: id.rawValue,
                params: threadStartParams(options: options)
            ))
        return thread(from: response.thread)
    }

    public func forkThread(
        _ id: CodexThread.ID,
        options: CodexThread.Options = .init()
    ) async throws -> CodexThread {
        let response = try await client.send(
            AppServerAPI.Thread.Fork.Request(
                threadID: id.rawValue,
                params: threadStartParams(options: options)
            ))
        return thread(from: response.thread)
    }

    public func unarchiveThread(_ id: CodexThread.ID) async throws -> CodexThread {
        let response = try await client.send(
            AppServerAPI.Thread.Unarchive.Request(
                params: .init(threadID: id.rawValue)
            ))
        return thread(from: response.thread)
    }

    public func deleteThread(_ id: CodexThread.ID) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Delete.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    public func listThreads(_ query: CodexThreadQuery = .init()) async throws -> CodexThreadPage {
        let response = try await client.send(
            AppServerAPI.Thread.List.Request(
                params: .init(
                    archived: query.archived,
                    cursor: query.cursor,
                    cwd: query.workspace.map { .path($0.path) },
                    limit: query.limit,
                    searchTerm: query.searchTerm
                )))
        return .init(
            threads: response.data.map(Self.threadSnapshot),
            nextCursor: response.nextCursor,
            backwardsCursor: response.backwardsCursor
        )
    }

    public func models(includeHidden: Bool = false) async throws -> [CodexModel] {
        var cursor: String?
        var models: [CodexModel] = []
        repeat {
            let response = try await client.send(
                AppServerAPI.Model.List.Request(
                    params: .init(cursor: cursor, includeHidden: includeHidden)
                ))
            models.append(contentsOf: response.data)
            cursor = response.nextCursor
        } while cursor != nil
        return models
    }

    public func account(refreshToken: Bool = false) async throws -> CodexAccount? {
        let response = try await client.send(
            AppServerAPI.Account.Read.Request(params: .init(refreshToken: refreshToken))
        )
        return response.account.map(Self.account)
    }

    public func configuration() async throws -> CodexConfiguration {
        let response = try await client.send(AppServerAPI.Config.Read.Request())
        return .init(
            model: response.config.model,
            reviewModel: response.config.reviewModel,
            reasoningEffort: response.config.modelReasoningEffort,
            serviceTier: response.config.serviceTier
        )
    }

    public func rateLimits() async throws -> CodexRateLimits {
        let response = try await client.send(AppServerAPI.Account.RateLimits.Read.Request())
        return .init(
            planType: response.codexPlanType,
            windows: response.codexRateLimitWindows.map {
                .init(
                    windowDurationMinutes: $0.windowDurationMinutes,
                    usedPercent: $0.usedPercent,
                    resetsAt: $0.resetsAt
                )
            }
        )
    }

    @discardableResult
    public func loginAPIKey(_ apiKey: String) async throws -> CodexLoginHandle {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(type: "apiKey", apiKey: apiKey)
            ))
        return try Self.loginHandle(from: response)
    }

    public func loginChatGPT(callbackURLScheme: String? = nil) async throws -> CodexLoginHandle {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(
                    type: "chatgpt",
                    nativeWebAuthentication: callbackURLScheme.map {
                        .init(callbackURLScheme: $0)
                    }
                )
            ))
        return try Self.loginHandle(from: response)
    }

    public func loginChatGPTDeviceCode() async throws -> CodexLoginHandle {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(type: "chatgptDeviceCode")
            ))
        return try Self.loginHandle(from: response)
    }

    public func cancelLogin(_ handle: CodexLoginHandle) async throws {
        guard let id = handle.id else {
            return
        }
        try await cancelLogin(id: id)
    }

    public func cancelLogin(id: CodexLoginHandle.ID) async throws {
        let _: AppServerAPI.Account.Login.Cancel.Response = try await client.send(
            AppServerAPI.Account.Login.Cancel.Request(params: .init(loginID: id.rawValue))
        )
    }

    public func completeLogin(_ handle: CodexLoginHandle, callbackURL: URL) async throws {
        guard let id = handle.id else {
            return
        }
        try await completeLogin(id: id, callbackURL: callbackURL)
    }

    public func completeLogin(id: CodexLoginHandle.ID, callbackURL: URL) async throws {
        let _: AppServerAPI.Account.Login.Complete.Response = try await client.send(
            AppServerAPI.Account.Login.Complete.Request(
                params: .init(
                    loginID: id.rawValue,
                    callbackURL: callbackURL.absoluteString
                ))
        )
    }

    public func logout() async throws {
        let _: EmptyResponse = try await client.send(AppServerAPI.Account.Logout.Request())
    }

    private func threadStartParams(options: CodexThread.Options) -> AppServerAPI.Thread.Start.Params
    {
        .init(
            model: options.model,
            modelProvider: options.modelProvider,
            ephemeral: options.ephemeral,
            approvalPolicy: options.approvalMode?.approvalPolicy,
            approvalsReviewer: options.approvalMode?.approvalsReviewer,
            sandbox: options.sandbox?.threadSandboxValue,
            serviceTier: options.serviceTier
        )
    }

    private func thread(from snapshot: AppServerAPI.Thread.Snapshot) -> CodexThread {
        CodexThread(
            id: .init(rawValue: snapshot.id),
            workspace: snapshot.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            client: client,
            router: router
        )
    }

    package nonisolated static func threadSnapshot(
        from snapshot: AppServerAPI.Thread.Snapshot
    ) -> CodexThreadSnapshot {
        .init(
            id: .init(rawValue: snapshot.id),
            workspace: snapshot.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            name: snapshot.name,
            preview: snapshot.preview,
            turns: (snapshot.turns ?? []).map {
                CodexTurnSnapshot(
                    id: .init(rawValue: $0.id),
                    status: $0.status.map(CodexTurnStatus.init(rawValue:)),
                    errorMessage: $0.error?.message
                )
            }
        )
    }

    private nonisolated static func account(from snapshot: AppServerAPI.Account.Snapshot)
        -> CodexAccount
    {
        .init(
            id: snapshot.id,
            kind: .init(rawValue: snapshot.kind.rawValue) ?? .chatGPT,
            label: snapshot.label,
            planType: snapshot.planType
        )
    }

    private nonisolated static func loginHandle(
        from response: AppServerAPI.Account.Login.Response
    ) throws -> CodexLoginHandle {
        switch response {
        case .apiKey:
            return .apiKey
        case .chatgpt(let loginID, let authURL, _):
            guard let url = URL(string: authURL) else {
                throw CodexAppServerError.jsonRPC(
                    code: -32602, message: "Invalid ChatGPT authentication URL.")
            }
            return .chatGPT(id: .init(rawValue: loginID), authenticationURL: url)
        case .chatgptDeviceCode(let loginID, let verificationURL, let userCode):
            guard let url = URL(string: verificationURL) else {
                throw CodexAppServerError.jsonRPC(
                    code: -32602, message: "Invalid ChatGPT device-code verification URL.")
            }
            return .chatGPTDeviceCode(
                id: .init(rawValue: loginID),
                verificationURL: url,
                userCode: userCode
            )
        case .chatgptAuthTokens:
            return .apiKey
        }
    }

    private nonisolated static func defaultCodexHomeURL(environment: [String: String]) -> URL {
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(
            in: .whitespacesAndNewlines),
            codexHome.isEmpty == false
        {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            home.isEmpty == false
        {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}
