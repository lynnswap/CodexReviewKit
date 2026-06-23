import Foundation

/// A live connection to a Codex app-server process.
///
/// `CodexAppServer` owns the app-server transport, performs the initial
/// JSON-RPC handshake, and routes server notifications to thread, turn, and
/// login domain objects.
public actor CodexAppServer {
    /// Options for launching and identifying a Codex app-server process.
    public struct Configuration: Sendable {
        /// The `codex` executable path or command name.
        ///
        /// Set this when the executable is not available through the process
        /// environment. When `nil`, the default transport command is used.
        public var executable: String?

        /// Command-line arguments passed to the app-server executable.
        ///
        /// When `nil`, the transport uses the default arguments for starting
        /// `codex app-server`.
        public var arguments: [String]?

        /// Environment variables supplied to the app-server process.
        public var environment: [String: String]

        /// The Codex home directory used by the app-server process.
        ///
        /// When `nil`, the value is derived from `CODEX_HOME` or the user's
        /// home directory in the supplied environment.
        public var codexHomeURL: URL?

        /// The client name sent in the app-server `initialize` request.
        public var clientName: String

        /// The client version sent in the app-server `initialize` request.
        public var clientVersion: String

        /// Creates a configuration for launching a Codex app-server process.
        ///
        /// - Parameters:
        ///   - executable: The `codex` executable path or command name.
        ///   - arguments: Command-line arguments for the app-server process.
        ///   - environment: Environment variables for the app-server process.
        ///   - codexHomeURL: Codex home directory, or `nil` to infer it.
        ///   - clientName: Client name sent during app-server initialization.
        ///   - clientVersion: Client version sent during app-server initialization.
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

        /// A configuration that uses the local `codex` executable and current environment.
        public static let `default` = Configuration()
    }

    private let client: AppServerClient
    private let router: CodexAppServerNotificationRouter

    /// Starts a Codex app-server process and initializes the client session.
    ///
    /// The initializer completes after the app-server has accepted the
    /// `initialize` request and notification routing is ready.
    ///
    /// - Parameter configuration: Process and client identity configuration.
    /// - Throws: A transport, JSON-RPC, or app-server initialization error.
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

    /// Closes the app-server connection and stops notification routing.
    ///
    /// Call this when the container is no longer needed. Closing is idempotent
    /// from the perspective of public callers.
    public func close() async {
        await router.stop()
        await client.close()
    }

    /// Creates a new Codex thread in a workspace.
    ///
    /// - Parameters:
    ///   - workspace: The workspace directory for the thread.
    ///   - instructions: Optional base and developer instructions.
    ///   - options: Thread creation options, including model, approval, and sandbox settings.
    /// - Returns: A domain handle for the created thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
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

    /// Resumes an existing Codex thread.
    ///
    /// - Parameters:
    ///   - id: The thread identifier to resume.
    ///   - options: Resume options that may override the stored thread context.
    /// - Returns: A domain handle for the resumed thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func resumeThread(
        _ id: CodexThreadID,
        options: CodexThread.ResumeOptions = .init()
    ) async throws -> CodexThread {
        let response = try await client.send(
            AppServerAPI.Thread.Resume.Request(
                threadID: id.rawValue,
                params: threadStartParams(options: options)
            ))
        return thread(from: response.thread)
    }

    /// Forks an existing Codex thread into a new thread.
    ///
    /// - Parameters:
    ///   - id: The source thread identifier.
    ///   - options: Options for the forked thread.
    /// - Returns: A domain handle for the forked thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func forkThread(
        _ id: CodexThreadID,
        options: CodexThread.Options = .init()
    ) async throws -> CodexThread {
        let response = try await client.send(
            AppServerAPI.Thread.Fork.Request(
                threadID: id.rawValue,
                params: threadStartParams(options: options)
            ))
        return thread(from: response.thread)
    }

    /// Restores an archived Codex thread.
    ///
    /// - Parameter id: The archived thread identifier.
    /// - Returns: A domain handle for the restored thread.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func unarchiveThread(_ id: CodexThreadID) async throws -> CodexThread {
        let response = try await client.send(
            AppServerAPI.Thread.Unarchive.Request(
                params: .init(threadID: id.rawValue)
            ))
        return thread(from: response.thread)
    }

    /// Permanently deletes a Codex thread.
    ///
    /// - Parameter id: The thread identifier to delete.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func deleteThread(_ id: CodexThreadID) async throws {
        let _: EmptyResponse = try await client.send(
            AppServerAPI.Thread.Delete.Request(
                params: .init(threadID: id.rawValue)
            ))
    }

    /// Lists Codex threads visible to the app-server account.
    ///
    /// - Parameter query: Paging and filtering options.
    /// - Returns: A page of thread snapshots.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
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

    /// Lists available Codex models.
    ///
    /// - Parameter includeHidden: Whether hidden models should be included.
    /// - Returns: The complete model list across all app-server result pages.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
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

    /// Reads the active Codex account.
    ///
    /// - Parameter refreshToken: Whether the app-server should refresh token state before returning.
    /// - Returns: The active account, or `nil` when no account is signed in.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func account(refreshToken: Bool = false) async throws -> CodexAccount? {
        let response = try await client.send(
            AppServerAPI.Account.Read.Request(params: .init(refreshToken: refreshToken))
        )
        return response.account.map(Self.account)
    }

    /// Reads the app-server configuration visible to Codex clients.
    ///
    /// - Returns: Model, reasoning, review model, and service-tier settings.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func configuration() async throws -> CodexConfiguration {
        let response = try await client.send(AppServerAPI.Config.Read.Request())
        return .init(
            model: response.config.model,
            reviewModel: response.config.reviewModel,
            reasoningEffort: response.config.modelReasoningEffort,
            serviceTier: response.config.serviceTier
        )
    }

    /// Reads Codex account rate-limit information.
    ///
    /// - Returns: Current plan type and rate-limit windows reported by the app-server.
    /// - Throws: A transport, JSON-RPC, or app-server request error.
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

    /// Starts an API-key login flow.
    ///
    /// - Parameter apiKey: The OpenAI API key to register with Codex.
    /// - Returns: The login handle reported by the app-server.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    @discardableResult
    public func loginAPIKey(_ apiKey: String) async throws -> CodexLoginHandle {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(type: "apiKey", apiKey: apiKey)
            ))
        return try Self.loginHandle(from: response)
    }

    /// Starts a ChatGPT browser login flow.
    ///
    /// - Parameter callbackURLScheme: Optional native callback URL scheme for completing login.
    /// - Returns: A login handle containing the next browser or callback step.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
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

    /// Starts a ChatGPT device-code login flow.
    ///
    /// - Returns: A login handle containing device-code instructions.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func loginChatGPTDeviceCode() async throws -> CodexLoginHandle {
        let response = try await client.send(
            AppServerAPI.Account.Login.Start.Request(
                params: .init(type: "chatgptDeviceCode")
            ))
        return try Self.loginHandle(from: response)
    }

    /// Cancels a pending login flow.
    ///
    /// Handles without an app-server login identifier are treated as already complete.
    ///
    /// - Parameter handle: The login handle returned from a login-start method.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func cancelLogin(_ handle: CodexLoginHandle) async throws {
        guard let id = handle.id else {
            return
        }
        try await cancelLogin(id: id)
    }

    /// Cancels a pending login flow by identifier.
    ///
    /// - Parameter id: The app-server login identifier.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func cancelLogin(id: CodexLoginHandle.ID) async throws {
        let _: AppServerAPI.Account.Login.Cancel.Response = try await client.send(
            AppServerAPI.Account.Login.Cancel.Request(params: .init(loginID: id.rawValue))
        )
    }

    /// Completes a native ChatGPT browser login flow.
    ///
    /// Handles without an app-server login identifier are treated as already complete.
    ///
    /// - Parameters:
    ///   - handle: The login handle returned from `loginChatGPT(callbackURLScheme:)`.
    ///   - callbackURL: The callback URL received by the client application.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func completeLogin(_ handle: CodexLoginHandle, callbackURL: URL) async throws {
        guard let id = handle.id else {
            return
        }
        try await completeLogin(id: id, callbackURL: callbackURL)
    }

    /// Completes a native ChatGPT browser login flow by identifier.
    ///
    /// - Parameters:
    ///   - id: The app-server login identifier.
    ///   - callbackURL: The callback URL received by the client application.
    /// - Throws: A transport, JSON-RPC, or app-server login error.
    public func completeLogin(id: CodexLoginHandle.ID, callbackURL: URL) async throws {
        let _: AppServerAPI.Account.Login.Complete.Response = try await client.send(
            AppServerAPI.Account.Login.Complete.Request(
                params: .init(
                    loginID: id.rawValue,
                    callbackURL: callbackURL.absoluteString
                ))
        )
    }

    /// Logs out of the active Codex account.
    ///
    /// - Throws: A transport, JSON-RPC, or app-server request error.
    public func logout() async throws {
        let _: EmptyResponse = try await client.send(AppServerAPI.Account.Logout.Request())
    }

    private func threadStartParams(options: CodexThread.Options) -> AppServerAPI.Thread.Start.Params {
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

    private nonisolated static func account(from snapshot: AppServerAPI.Account.Snapshot) -> CodexAccount {
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
        if let codexHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            codexHome.isEmpty == false {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
        }
        if let home = environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            home.isEmpty == false {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".codex", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }
}
