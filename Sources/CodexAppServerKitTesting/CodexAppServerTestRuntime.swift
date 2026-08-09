import Foundation
import CodexAppServerKit
import Synchronization

/// An in-memory store for app-server thread snapshots used by test stubs.
///
/// Use this store when tests or previews need to mutate the same authoritative
/// snapshots that back `thread/list`, `thread/read`, `thread/resume`, and
/// `thread/start` in ``CodexAppServerTestTransport``.
public actor CodexAppServerTestThreadStore {
    private struct PlannedStart: Sendable {
        var thread: CodexAppServerTestStoredThread
    }

    private struct PlannedFork: Sendable {
        var sourceID: CodexThreadID
        var thread: CodexAppServerTestStoredThread
    }

    private var threadsByID: [String: CodexAppServerTestStoredThread]
    private var threadOrder: [String]
    private var plannedStarts: [PlannedStart]
    private var plannedForks: [PlannedFork] = []
    private static let cursorPrefix = "test-thread-store:"
    private static let threadListDefaultLimit = 25
    private static let threadListMaximumLimit = 100

    /// Creates an in-memory store from validated opaque thread fixtures.
    public init(
        threads: [CodexAppServerTestStoredThread] = [],
        plannedStarts: [CodexAppServerTestStoredThread] = []
    ) throws {
        guard Set(threads.map(\.snapshot.id)).count == threads.count else {
            throw CodexAppServerTestError.invalidFixture(
                "Stored test threads must use unique identities."
            )
        }
        guard Set(plannedStarts.map(\.snapshot.id)).count == plannedStarts.count,
            Set(threads.map(\.snapshot.id)).isDisjoint(with: plannedStarts.map(\.snapshot.id))
        else {
            throw CodexAppServerTestError.invalidFixture(
                "Planned test thread starts must use distinct new identities."
            )
        }
        self.threadsByID = Dictionary(
            uniqueKeysWithValues: threads.map { ($0.snapshot.id.rawValue, $0) }
        )
        self.threadOrder = threads.map(\.snapshot.id.rawValue)
        self.plannedStarts = plannedStarts.map { .init(thread: $0) }
    }

    /// Returns the complete validated fixture for `id`, if one exists.
    public func storedThread(id: CodexThreadID) -> CodexAppServerTestStoredThread? {
        threadsByID[id.rawValue]
    }

    /// Inserts or replaces a stored fixture without changing an existing list position.
    public func upsert(_ thread: CodexAppServerTestStoredThread) {
        let id = thread.snapshot.id.rawValue
        if threadsByID[id] == nil {
            threadOrder.insert(id, at: 0)
        }
        threadsByID[id] = thread
    }

    /// Enqueues the complete fixture consumed by the next `thread/start` request.
    public func enqueueStart(
        _ thread: CodexAppServerTestStoredThread
    ) throws {
        let id = thread.snapshot.id
        guard threadsByID[id.rawValue] == nil,
            plannedStarts.contains(where: { $0.thread.snapshot.id == id }) == false
        else {
            throw CodexAppServerTestError.invalidFixture(
                "A planned thread start must use a new thread identity."
            )
        }
        plannedStarts.append(.init(thread: thread))
    }

    /// Enqueues the complete fixture consumed by the next matching `thread/fork` request.
    public func enqueueFork(
        _ fork: CodexAppServerTestStoredThread,
        from sourceID: CodexThreadID
    ) throws {
        guard threadsByID[sourceID.rawValue] != nil else {
            throw CodexAppServerTestError.invalidFixture(
                "A planned fork source must already exist in the thread store."
            )
        }
        let forkID = fork.snapshot.id
        guard threadsByID[forkID.rawValue] == nil,
            forkID != sourceID,
            plannedForks.contains(where: { $0.thread.snapshot.id == forkID }) == false
        else {
            throw CodexAppServerTestError.invalidFixture(
                "A planned thread fork must use a new thread identity."
            )
        }
        guard fork.metadata.forkedFromID == sourceID else {
            throw CodexAppServerTestError.invalidFixture(
                "A planned fork must identify its source in thread metadata."
            )
        }
        plannedForks.append(.init(sourceID: sourceID, thread: fork))
    }

    /// Removes and returns the complete stored fixture for `id`, if one exists.
    @discardableResult
    public func remove(id: CodexThreadID) -> CodexAppServerTestStoredThread? {
        threadOrder.removeAll { $0 == id.rawValue }
        return threadsByID.removeValue(forKey: id.rawValue)
    }

    private func replacing(
        _ thread: CodexAppServerTestStoredThread,
        snapshot: CodexThreadSnapshot? = nil,
        isArchived: Bool? = nil
    ) throws -> CodexAppServerTestStoredThread {
        try .init(
            snapshot: snapshot ?? thread.snapshot,
            turns: thread.turns,
            metadata: thread.metadata,
            runtimeMetadata: thread.runtimeMetadata,
            isArchived: isArchived ?? thread.isArchived
        )
    }

    func startThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Start.Params.self, from: params)
        guard plannedStarts.isEmpty == false else {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "thread/start requires an explicitly planned test thread."
            ))
        }
        let planned = plannedStarts.removeFirst()
        let thread = planned.thread
        let snapshot = thread.snapshot
        if let requestedID = request.threadID, requestedID != snapshot.id.rawValue {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "The planned thread/start identity does not match the request."
            ))
        }
        if let requestedCWD = request.cwd,
           requestedCWD != snapshot.workspace?.standardizedFileURL.path {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "The planned thread/start workspace does not match the request."
            ))
        }
        if let requestedProvider = request.modelProvider,
           requestedProvider != snapshot.modelProvider {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "The planned thread/start model provider does not match the request."
            ))
        }
        if let requestedEphemeral = request.ephemeral,
           requestedEphemeral != snapshot.ephemeral {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "The planned thread/start ephemeral flag does not match the request."
            ))
        }
        upsert(thread)
        return try JSONEncoder().encode(
            thread.runtimeResponseWireValue(includingTurns: false)
        )
    }

    func forkThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Fork.Params.self, from: params)
        guard let sourceID = request.threadID.map(CodexThreadID.init(rawValue:)),
            threadsByID[sourceID.rawValue] != nil
        else {
            throw Self.missingThreadError(operation: "thread/fork")
        }
        guard let plannedIndex = plannedForks.firstIndex(where: { $0.sourceID == sourceID }) else {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "thread/fork requires an explicitly planned test thread."
            ))
        }
        let planned = plannedForks.remove(at: plannedIndex)
        let thread = planned.thread
        let snapshot = thread.snapshot
        if let requestedCWD = request.cwd,
           requestedCWD != snapshot.workspace?.standardizedFileURL.path {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "The planned thread/fork workspace does not match the request."
            ))
        }
        if let requestedProvider = request.modelProvider,
           requestedProvider != snapshot.modelProvider {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "The planned thread/fork model provider does not match the request."
            ))
        }
        if let requestedEphemeral = request.ephemeral,
           requestedEphemeral != snapshot.ephemeral {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "The planned thread/fork ephemeral flag does not match the request."
            ))
        }
        upsert(thread)
        return try JSONEncoder().encode(
            thread.runtimeResponseWireValue(includingTurns: true)
        )
    }

    func listThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.List.Params.self, from: params)
        let archived = request.archived ?? false
        let storedThreads = threadOrder.compactMap { id -> CodexAppServerTestStoredThread? in
            guard let thread = threadsByID[id], thread.isArchived == archived else {
                return nil
            }
            return thread
        }
        let filteredSnapshots = try CodexAppServerTestTransport.sortedThreadSnapshots(
            CodexAppServerTestTransport.filteredThreadSnapshots(
                storedThreads.map(\.snapshot),
                for: request
            ),
            sortKey: request.sortKey,
            sortDirection: request.sortDirection
        )
        let filteredThreads = filteredSnapshots.compactMap {
            threadsByID[$0.id.rawValue]
        }
        let page = try page(filteredThreads, cursor: request.cursor, limit: request.limit)
        return try JSONEncoder().encode(page.wireValue)
    }

    private func page(
        _ threads: [CodexAppServerTestStoredThread],
        cursor: String?,
        limit: Int?
    ) throws -> CodexAppServerTestThreadPage {
        let start = min(try offset(from: cursor), threads.count)
        let pageSize = min(
            max(limit ?? Self.threadListDefaultLimit, 1),
            Self.threadListMaximumLimit
        )
        let end = min(start + pageSize, threads.count)
        let previousStart = max(0, start - pageSize)
        return CodexAppServerTestThreadPage(
            threads: Array(threads[start..<end]),
            nextCursor: end < threads.count ? Self.cursor(for: end) : nil,
            backwardsCursor: start > 0 ? Self.cursor(for: previousStart) : nil
        )
    }

    private func offset(from cursor: String?) throws -> Int {
        guard let cursor else {
            return 0
        }
        guard cursor.hasPrefix(Self.cursorPrefix),
              let offset = Int(cursor.dropFirst(Self.cursorPrefix.count)),
              offset >= 0 else {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "Invalid test thread-store cursor."
            ))
        }
        return offset
    }

    private static func cursor(for offset: Int) -> String {
        "\(cursorPrefix)\(offset)"
    }

    func resumeThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Resume.Params.self, from: params)
        guard let threadID = request.threadID,
            let thread = threadsByID[threadID]
        else {
            throw JSONRPC.Error.responseError(.init(
                code: -32004,
                message: "No stubbed thread matches thread/resume."
            ))
        }
        return try JSONEncoder().encode(
            thread.runtimeResponseWireValue(includingTurns: true)
        )
    }

    func readThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Read.Params.self, from: params)
        guard let thread = threadsByID[request.threadID] else {
            throw JSONRPC.Error.responseError(.init(
                code: -32004,
                message: "No stubbed thread matches thread/read."
            ))
        }
        return try JSONEncoder().encode(
            CodexJSONValue.object([
                "thread": thread.wireValue(includingTurns: request.includeTurns == true),
            ])
        )
    }

    func listThreadTurnsResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(
            AppServerAPI.Thread.Turns.List.Params.self,
            from: params
        )
        guard let thread = threadsByID[request.threadID] else {
            throw JSONRPC.Error.responseError(.init(
                code: -32004,
                message: "No stubbed thread matches thread/turns/list."
            ))
        }
        var turns = thread.turns
        if request.sortDirection == .descending {
            turns.reverse()
        }
        let page = try page(turns, cursor: request.cursor, limit: request.limit)
        return try JSONEncoder().encode(page.wireValue)
    }

    private func page(
        _ turns: [CodexAppServerTestTurn],
        cursor: String?,
        limit: Int?
    ) throws -> CodexAppServerTestTurnPage {
        let start = min(try offset(from: cursor), turns.count)
        guard let limit else {
            return CodexAppServerTestTurnPage(
                turns: Array(turns[start..<turns.endIndex]),
                backwardsCursor: start > 0 ? Self.cursor(for: 0) : nil
            )
        }
        guard limit > 0 else {
            return CodexAppServerTestTurnPage(
                turns: [],
                nextCursor: nil,
                backwardsCursor: nil
            )
        }

        let end = min(start + limit, turns.count)
        let previousStart = max(0, start - limit)
        return CodexAppServerTestTurnPage(
            turns: Array(turns[start..<end]),
            nextCursor: end < turns.count ? Self.cursor(for: end) : nil,
            backwardsCursor: start > 0 ? Self.cursor(for: previousStart) : nil
        )
    }

    func archiveThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Archive.Params.self, from: params)
        guard let thread = threadsByID[request.threadID] else {
            throw Self.missingThreadError(operation: "thread/archive")
        }
        threadsByID[request.threadID] = try replacing(thread, isArchived: true)
        return try JSONEncoder().encode(EmptyResponse())
    }

    func unarchiveThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Unarchive.Params.self, from: params)
        guard let thread = threadsByID[request.threadID] else {
            throw Self.missingThreadError(operation: "thread/unarchive")
        }
        let unarchived = try replacing(thread, isArchived: false)
        threadsByID[request.threadID] = unarchived
        return try JSONEncoder().encode(CodexJSONValue.object([
            "thread": unarchived.wireValue(includingTurns: false),
        ]))
    }

    func deleteThreadResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Delete.Params.self, from: params)
        guard remove(id: .init(rawValue: request.threadID)) != nil else {
            throw Self.missingThreadError(operation: "thread/delete")
        }
        return try JSONEncoder().encode(EmptyResponse())
    }

    func setThreadNameResponse(for params: Data) throws -> Data {
        let request = try JSONDecoder().decode(AppServerAPI.Thread.Name.Set.Params.self, from: params)
        guard let thread = threadsByID[request.threadID] else {
            throw Self.missingThreadError(operation: "thread/name/set")
        }
        var snapshot = thread.snapshot
        snapshot.name = request.name
        threadsByID[request.threadID] = try replacing(thread, snapshot: snapshot)
        return try JSONEncoder().encode(EmptyResponse())
    }

    private static func missingThreadError(operation: String) -> JSONRPC.Error {
        .responseError(.init(
            code: -32004,
            message: "No stored test thread matches \(operation)."
        ))
    }
}

private extension CodexAppServerTestStoredThread {
    func runtimeResponseWireValue(
        includingTurns: Bool,
        initialTurnsPage: CodexAppServerTestTurnPage? = nil
    ) -> CodexJSONValue {
        guard case .object(var fields) = runtimeMetadata.wireValue else {
            preconditionFailure("Thread runtime metadata must own an object wire value.")
        }
        fields["thread"] = wireValue(includingTurns: includingTurns)
        if let initialTurnsPage {
            fields["initialTurnsPage"] = initialTurnsPage.wireValue
        }
        return .object(fields)
    }
}

/// A manually advanced monotonic clock for deterministic deadline tests.
public final class CodexAppServerTestDeadlineClock: Sendable {
    private enum Registration {
        case ready
        case closed
        case waiting
    }

    private final class Waiter: Sendable {
        private enum State: Sendable {
            case pending(CheckedContinuation<Result<Void, CancellationError>, Never>?)
            case resolved(Result<Void, CancellationError>)
        }

        private let state = Mutex<State>(.pending(nil))

        func wait() async throws {
            let result = await withCheckedContinuation { continuation in
                let resolved = state.withLock {
                    state -> Result<Void, CancellationError>? in
                    switch state {
                    case .pending(nil):
                        state = .pending(continuation)
                        return nil
                    case .pending(.some):
                        preconditionFailure("A deadline-clock waiter can suspend exactly once.")
                    case .resolved(let result):
                        return result
                    }
                }
                if let resolved {
                    continuation.resume(returning: resolved)
                }
            }
            try result.get()
        }

        func resolve(_ result: Result<Void, CancellationError>) {
            let continuation = state.withLock {
                state -> CheckedContinuation<Result<Void, CancellationError>, Never>? in
                switch state {
                case .pending(let continuation):
                    state = .resolved(result)
                    return continuation
                case .resolved:
                    return nil
                }
            }
            continuation?.resume(returning: result)
        }
    }

    private struct Sleeper: Sendable {
        var deadline: Duration
        var waiter: Waiter
    }

    private struct CountObserver: Sendable {
        var count: Int
        var waiter: Waiter
    }

    private struct State: Sendable {
        var now: Duration = .zero
        var isClosed = false
        var sleepers: [UUID: Sleeper] = [:]
        var countObservers: [UUID: CountObserver] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Advances the clock and resumes sleepers whose deadline is now due.
    public func advance(by duration: Duration) {
        precondition(duration >= .zero, "A deadline clock cannot move backwards.")
        let waiters = state.withLock { state -> [Waiter] in
            guard state.isClosed == false else {
                return []
            }
            state.now += duration
            let dueIDs = state.sleepers.compactMap { id, sleeper in
                sleeper.deadline <= state.now ? id : nil
            }
            return dueIDs.compactMap { state.sleepers.removeValue(forKey: $0)?.waiter }
        }
        for waiter in waiters {
            waiter.resolve(.success(()))
        }
    }

    /// Suspends until at least `count` deadline sleepers have registered.
    public func waitForSleeperCount(_ count: Int) async throws {
        precondition(count >= 0, "A sleeper count cannot be negative.")
        try Task.checkCancellation()
        let id = UUID()
        let waiter = Waiter()
        let registration = state.withLock { state -> Registration in
            if state.sleepers.count >= count {
                return .ready
            }
            if state.isClosed {
                return .closed
            }
            state.countObservers[id] = .init(count: count, waiter: waiter)
            return .waiting
        }
        switch registration {
        case .ready:
            return
        case .closed:
            throw CancellationError()
        case .waiting:
            break
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await waiter.wait()
        } onCancel: {
            self.cancelCountObserver(id: id, waiter: waiter)
        }
    }

    /// Closes the clock and cancels every pending sleeper and observer.
    public func close() {
        let waiters = state.withLock { state -> [Waiter] in
            guard state.isClosed == false else {
                return []
            }
            state.isClosed = true
            let waiters = state.sleepers.values.map(\.waiter)
                + state.countObservers.values.map(\.waiter)
            state.sleepers.removeAll(keepingCapacity: false)
            state.countObservers.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.resolve(.failure(CancellationError()))
        }
    }

    package var codexDeadlineClock: CodexDeadlineClock {
        .init { [self] duration in
            try await sleep(for: duration)
        }
    }

    private func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else {
            return
        }
        let id = UUID()
        let waiter = Waiter()
        let registration = state.withLock {
            state -> (Registration, [Waiter]) in
            guard state.isClosed == false else {
                return (.closed, [])
            }
            state.sleepers[id] = .init(deadline: state.now + duration, waiter: waiter)
            let observers = readyCountObservers(in: &state)
            return (.waiting, observers)
        }
        for observer in registration.1 {
            observer.resolve(.success(()))
        }
        switch registration.0 {
        case .ready:
            preconditionFailure("A positive deadline sleep cannot complete at registration.")
        case .closed:
            throw CancellationError()
        case .waiting:
            break
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await waiter.wait()
        } onCancel: {
            self.cancelSleeper(id: id, waiter: waiter)
        }
    }

    private func readyCountObservers(in state: inout State) -> [Waiter] {
        let readyIDs = state.countObservers.compactMap { id, observer in
            observer.count <= state.sleepers.count ? id : nil
        }
        return readyIDs.compactMap { state.countObservers.removeValue(forKey: $0)?.waiter }
    }

    private func cancelSleeper(id: UUID, waiter: Waiter) {
        let removed = state.withLock { state -> Bool in
            guard state.sleepers[id]?.waiter === waiter else {
                return false
            }
            state.sleepers.removeValue(forKey: id)
            return true
        }
        if removed {
            waiter.resolve(.failure(CancellationError()))
        }
    }

    private func cancelCountObserver(id: UUID, waiter: Waiter) {
        let removed = state.withLock { state -> Bool in
            guard state.countObservers[id]?.waiter === waiter else {
                return false
            }
            state.countObservers.removeValue(forKey: id)
            return true
        }
        if removed {
            waiter.resolve(.failure(CancellationError()))
        }
    }
}

/// A Codex app-server test runtime backed by an in-memory transport.
///
/// This type does not launch `codex` or any external process. Tests enqueue
/// responses and emit notifications through ``transport`` while exercising the
/// same public ``CodexAppServer`` API that production code uses.
public struct CodexAppServerTestRuntime: Sendable {
    /// The app-server domain container under test.
    public let server: CodexAppServer

    /// The in-memory transport used by ``server``.
    public let transport: CodexAppServerTestTransport

    /// Typed current-v2 notification controls for the in-memory server.
    public let notificationEmitter: CodexAppServerTestNotificationEmitter

    /// The authoritative thread store, when this runtime was started in store mode.
    public let threadStore: CodexAppServerTestThreadStore?

    /// The manually controlled deadline clock, when one was supplied at startup.
    public let deadlineClock: CodexAppServerTestDeadlineClock?

    /// Creates a runtime from an already initialized app-server container and transport.
    package init(
        server: CodexAppServer,
        transport: CodexAppServerTestTransport,
        threadStore: CodexAppServerTestThreadStore? = nil,
        deadlineClock: CodexAppServerTestDeadlineClock? = nil
    ) {
        self.server = server
        self.transport = transport
        self.threadStore = threadStore
        self.deadlineClock = deadlineClock
        self.notificationEmitter = CodexAppServerTestNotificationEmitter(transport: transport)
    }

    /// Closes the app-server connection and drains the in-memory transport.
    public func close() async {
        await server.close()
        await transport.close()
        deadlineClock?.close()
    }

    /// Creates a test runtime without launching a real app-server process.
    ///
    /// The runtime automatically enqueues the `initialize` response required by
    /// ``CodexAppServer`` startup.
    ///
    /// - Parameters:
    ///   - transport: The in-memory transport to use.
    ///   - configuration: The same connection configuration used by production.
    ///   - deadlineClock: An optional manually advanced monotonic deadline clock.
    /// - Returns: A started test runtime.
    public static func start(
        transport: CodexAppServerTestTransport = CodexAppServerTestTransport(),
        configuration: CodexAppServer.Configuration = .init(),
        deadlineClock: CodexAppServerTestDeadlineClock? = nil
    ) async throws -> CodexAppServerTestRuntime {
        try await transport.enqueueInitialize(
            codexHome: configuration.localProcess.codexHomeURL.path,
            userAgent: nil
        )
        let harness = await CodexAppServerTestConnectionHarness.start(
            transport: transport,
            clock: configuration.clock,
            deadlines: configuration.deadlines,
            deadlineClock: deadlineClock?.codexDeadlineClock ?? configuration.deadlineClock,
            handler: configuration.serverRequestHandler
        )
        do {
            _ = try await harness.client.initialize(
                clientName: configuration.clientName,
                clientVersion: configuration.clientVersion
            )
        } catch {
            await harness.close()
            await transport.close()
            deadlineClock?.close()
            throw error
        }
        return .init(
            server: harness.server,
            transport: transport,
            deadlineClock: deadlineClock
        )
    }

    /// Creates a test runtime whose app-server thread APIs are backed by a mutable store.
    ///
    /// The returned runtime still exercises the public ``CodexAppServer`` API,
    /// while callers can mutate `threadStore` after startup:
    ///
    /// ```swift
    /// let store = CodexAppServerTestThreadStore(threads: threads)
    /// let runtime = try await CodexAppServerTestRuntime.start(threadStore: store)
    /// await store.upsert(updatedThread)
    /// ```
    public static func start(
        threadStore: CodexAppServerTestThreadStore,
        transport: CodexAppServerTestTransport = CodexAppServerTestTransport(),
        configuration: CodexAppServer.Configuration = .init(),
        deadlineClock: CodexAppServerTestDeadlineClock? = nil
    ) async throws -> CodexAppServerTestRuntime {
        try await transport.stubThreads(threadStore)
        let runtime = try await start(
            transport: transport,
            configuration: configuration,
            deadlineClock: deadlineClock
        )
        return .init(
            server: runtime.server,
            transport: runtime.transport,
            threadStore: threadStore,
            deadlineClock: runtime.deadlineClock
        )
    }

    /// Creates a test runtime whose thread APIs are backed by validated opaque fixtures.
    ///
    /// The returned runtime still exercises the public ``CodexAppServer`` API.
    /// Higher-level code can build its normal data container from ``server``:
    ///
    /// ```swift
    /// let runtime = try await CodexAppServerTestRuntime.start(threads: threads)
    /// let container = CodexModelContainer(appServer: runtime.server)
    /// ```
    public static func start(
        threads: [CodexAppServerTestStoredThread],
        transport: CodexAppServerTestTransport = CodexAppServerTestTransport(),
        configuration: CodexAppServer.Configuration = .init(),
        deadlineClock: CodexAppServerTestDeadlineClock? = nil
    ) async throws -> CodexAppServerTestRuntime {
        let threadStore = try CodexAppServerTestThreadStore(threads: threads)
        return try await start(
            threadStore: threadStore,
            transport: transport,
            configuration: configuration,
            deadlineClock: deadlineClock
        )
    }
}

public enum CodexAppServerTestOperation: Equatable, Sendable {
    case initialize
    case threadStart
    case threadResume
    case threadFork
    case threadList
    case threadRead
    case threadTurnsList
    case threadArchive
    case threadUnarchive
    case threadDelete
    case threadRename
    case threadCompact
    case threadRollback
    case turnStart
    case turnInterrupt
    case reviewStart
    case modelList
    case accountRead
    case accountRateLimitsRead
    case accountLoginStart
    case accountLoginCancel
    case accountLogout
    case configurationRead
    case configurationUpdate

    package var method: String {
        switch self {
        case .initialize: "initialize"
        case .threadStart: "thread/start"
        case .threadResume: "thread/resume"
        case .threadFork: "thread/fork"
        case .threadList: "thread/list"
        case .threadRead: "thread/read"
        case .threadTurnsList: "thread/turns/list"
        case .threadArchive: "thread/archive"
        case .threadUnarchive: "thread/unarchive"
        case .threadDelete: "thread/delete"
        case .threadRename: "thread/name/set"
        case .threadCompact: "thread/compact/start"
        case .threadRollback: "thread/rollback"
        case .turnStart: "turn/start"
        case .turnInterrupt: "turn/interrupt"
        case .reviewStart: "review/start"
        case .modelList: "model/list"
        case .accountRead: "account/read"
        case .accountRateLimitsRead: "account/rateLimits/read"
        case .accountLoginStart: "account/login/start"
        case .accountLoginCancel: "account/login/cancel"
        case .accountLogout: "account/logout"
        case .configurationRead: "config/read"
        case .configurationUpdate: "config/batchWrite"
        }
    }

    package init?(method: String) {
        guard let operation = Self.allCasesByMethod[method] else {
            return nil
        }
        self = operation
    }

    private static let allCasesByMethod: [String: Self] = [
        "initialize": .initialize,
        "thread/start": .threadStart,
        "thread/resume": .threadResume,
        "thread/fork": .threadFork,
        "thread/list": .threadList,
        "thread/read": .threadRead,
        "thread/turns/list": .threadTurnsList,
        "thread/archive": .threadArchive,
        "thread/unarchive": .threadUnarchive,
        "thread/delete": .threadDelete,
        "thread/name/set": .threadRename,
        "thread/compact/start": .threadCompact,
        "thread/rollback": .threadRollback,
        "turn/start": .turnStart,
        "turn/interrupt": .turnInterrupt,
        "review/start": .reviewStart,
        "model/list": .modelList,
        "account/read": .accountRead,
        "account/rateLimits/read": .accountRateLimitsRead,
        "account/login/start": .accountLoginStart,
        "account/login/cancel": .accountLoginCancel,
        "account/logout": .accountLogout,
        "config/read": .configurationRead,
        "config/batchWrite": .configurationUpdate,
    ]
}

public enum CodexAppServerTestRequest: Equatable, Sendable {
    case initialize
    case threadStart(
        workspace: URL,
        instructions: CodexInstructions?,
        options: CodexThread.Options
    )
    case threadResume(id: CodexThreadID, options: CodexThread.ResumeOptions)
    case threadFork(id: CodexThreadID, options: CodexThread.Options)
    case threadList(CodexThreadQuery)
    case threadRead(id: CodexThreadID, includeTurns: Bool)
    case threadTurnsList(threadID: CodexThreadID, query: CodexTurnQuery)
    case threadArchive(CodexThreadID)
    case threadUnarchive(CodexThreadID)
    case threadDelete(CodexThreadID)
    case threadRename(id: CodexThreadID, name: String)
    case threadCompact(CodexThreadID)
    case threadRollback(id: CodexThreadID, numberOfTurns: Int)
    case turnStart(
        threadID: CodexThreadID,
        prompt: CodexPrompt,
        options: CodexGenerationOptions
    )
    case turnInterrupt(threadID: CodexThreadID, turnID: CodexTurnID)
    case reviewStart(
        threadID: CodexThreadID,
        target: CodexReviewTarget,
        delivery: CodexReviewDelivery
    )
    case modelList(includeHidden: Bool)
    case accountRead(refreshToken: Bool)
    case accountRateLimitsRead
    case accountLoginStart
    case accountLoginCancel(CodexLoginHandle.ID)
    case accountLogout
    case configurationRead
    case configurationUpdate(CodexConfigurationPatch)

    public var operation: CodexAppServerTestOperation {
        switch self {
        case .initialize: .initialize
        case .threadStart: .threadStart
        case .threadResume: .threadResume
        case .threadFork: .threadFork
        case .threadList: .threadList
        case .threadRead: .threadRead
        case .threadTurnsList: .threadTurnsList
        case .threadArchive: .threadArchive
        case .threadUnarchive: .threadUnarchive
        case .threadDelete: .threadDelete
        case .threadRename: .threadRename
        case .threadCompact: .threadCompact
        case .threadRollback: .threadRollback
        case .turnStart: .turnStart
        case .turnInterrupt: .turnInterrupt
        case .reviewStart: .reviewStart
        case .modelList: .modelList
        case .accountRead: .accountRead
        case .accountRateLimitsRead: .accountRateLimitsRead
        case .accountLoginStart: .accountLoginStart
        case .accountLoginCancel: .accountLoginCancel
        case .accountLogout: .accountLogout
        case .configurationRead: .configurationRead
        case .configurationUpdate: .configurationUpdate
        }
    }
}

/// A semantic request recorded at the Testing transport boundary.
public struct CodexAppServerRecordedRequest: Equatable, Sendable {
    public let sequence: UInt64
    public let requestID: Int
    public let request: CodexAppServerTestRequest

    package let method: String
    package let params: Data

    package init(
        sequence: UInt64,
        requestID: Int,
        request: CodexAppServerTestRequest,
        method: String,
        params: Data
    ) {
        self.sequence = sequence
        self.requestID = requestID
        self.request = request
        self.method = method
        self.params = params
    }

    package var id: Int { requestID }

    package func decodeParams<Value: Decodable>(
        _ type: Value.Type = Value.self
    ) throws -> Value {
        try JSONDecoder().decode(type, from: params)
    }
}

package struct CodexAppServerRecordedRawRequest: Equatable, Sendable {
    package let sequence: UInt64
    package let requestID: Int
    package let method: String
    package let params: Data

    package var id: Int { requestID }

    package func decodeParams<Value: Decodable>(
        _ type: Value.Type = Value.self
    ) throws -> Value {
        try JSONDecoder().decode(type, from: params)
    }
}

package struct CodexAppServerRecordedNotification: Equatable, Sendable {
    package var method: String
    package var params: Data

    package init(method: String, params: Data) {
        self.method = method
        self.params = params
    }

    package func decodeParams<Value: Decodable>(
        _ type: Value.Type = Value.self
    ) throws -> Value {
        try JSONDecoder().decode(type, from: params)
    }
}

/// A typed `turn/interrupt` request observed by a Testing runtime handler.
public struct CodexAppServerTestTurnInterruptRequest: Equatable, Sendable {
    public var threadID: CodexThreadID
    public var turnID: CodexTurnID

    public init(threadID: CodexThreadID, turnID: CodexTurnID) {
        self.threadID = threadID
        self.turnID = turnID
    }
}

public enum CodexAppServerTestRequestFailure: Equatable, Sendable {
    case response(code: Int, message: String)

    fileprivate var jsonRPCError: JSONRPC.Error {
        switch self {
        case .response(let code, let message):
            .responseError(.init(code: code, message: message))
        }
    }
}

public enum CodexAppServerTestLoginCancellationStatus: Equatable, Sendable {
    case canceled
    case notFound

    fileprivate var wireValue: String {
        switch self {
        case .canceled: "canceled"
        case .notFound: "notFound"
        }
    }
}

/// A deterministic gate for app-server concurrency tests.
///
/// Use this to hold a request at a known point and release it explicitly,
/// instead of depending on sleeps or repeated `Task.yield()` calls.
public final class CodexAppServerTestGate: Sendable {
    private enum WaitRegistration {
        case ready
        case closed
        case waiting
    }

    private final class Waiter: Sendable {
        private enum State: Sendable {
            case pending(CheckedContinuation<Result<Void, CancellationError>, Never>?)
            case resolved(Result<Void, CancellationError>)
        }

        private let state = Mutex<State>(.pending(nil))

        func wait() async throws {
            let result = await withCheckedContinuation { continuation in
                let resolved = state.withLock {
                    state -> Result<Void, CancellationError>? in
                    switch state {
                    case .pending(nil):
                        state = .pending(continuation)
                        return nil
                    case .pending(.some):
                        preconditionFailure("A test gate waiter can suspend exactly once.")
                    case .resolved(let result):
                        return result
                    }
                }
                if let resolved {
                    continuation.resume(returning: resolved)
                }
            }
            try result.get()
        }

        @discardableResult
        func resolve(_ result: Result<Void, CancellationError>) -> Bool {
            let continuation = state.withLock {
                state -> CheckedContinuation<Result<Void, CancellationError>, Never>? in
                switch state {
                case .pending(let continuation):
                    state = .resolved(result)
                    return continuation
                case .resolved:
                    return nil
                }
            }
            continuation?.resume(returning: result)
            return continuation != nil
        }
    }

    private struct State: Sendable {
        var isOpen = false
        var isClosed = false
        var waiters: [UUID: Waiter] = [:]
        var blockedObservers: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Creates a closed gate.
    public init() {}

    /// Suspends until the gate opens, or until the waiting task is cancelled.
    public func wait() async throws {
        try Task.checkCancellation()
        let waiterID = UUID()
        let waiter = Waiter()
        let registration = state.withLock { state -> WaitRegistration in
            if state.isOpen {
                return .ready
            }
            if state.isClosed {
                return .closed
            }
            state.waiters[waiterID] = waiter
            resumeBlockedObservers(in: &state)
            return .waiting
        }
        switch registration {
        case .ready:
            return
        case .closed:
            throw CancellationError()
        case .waiting:
            break
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await waiter.wait()
        } onCancel: {
            self.cancelWaiter(id: waiterID, waiter: waiter)
        }
    }

    /// Suspends until the gate opens, ignoring task cancellation while waiting.
    public func waitIgnoringCancellation() async {
        let waiterID = UUID()
        let waiter = Waiter()
        let shouldWait = state.withLock { state in
            guard state.isOpen == false, state.isClosed == false else {
                return false
            }
            state.waiters[waiterID] = waiter
            resumeBlockedObservers(in: &state)
            return true
        }
        guard shouldWait else {
            return
        }
        try? await waiter.wait()
    }

    /// Suspends until at least one task is waiting at this gate.
    public func waitUntilBlocked() async {
        let shouldWait = state.withLock { state in
            state.isOpen == false && state.isClosed == false && state.waiters.isEmpty
        }
        guard shouldWait else {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                if state.isOpen || state.isClosed || state.waiters.isEmpty == false {
                    return true
                }
                state.blockedObservers.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    /// Opens the gate and resumes all suspended waiters.
    public func open() async {
        let waiters = state.withLock { state -> [Waiter] in
            guard state.isOpen == false, state.isClosed == false else {
                return []
            }
            state.isOpen = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            resumeBlockedObservers(in: &state)
            return waiters
        }
        for waiter in waiters {
            waiter.resolve(.success(()))
        }
    }

    /// Closes the gate and drains every waiter without opening it for future waits.
    public func close() async {
        let waiters = state.withLock { state -> [Waiter] in
            guard state.isClosed == false else {
                return []
            }
            state.isClosed = true
            let waiters = Array(state.waiters.values)
            state.waiters.removeAll(keepingCapacity: false)
            resumeBlockedObservers(in: &state)
            return waiters
        }
        for waiter in waiters {
            waiter.resolve(.failure(CancellationError()))
        }
    }

    private func resumeBlockedObservers(in state: inout State) {
        guard state.waiters.isEmpty == false || state.isOpen || state.isClosed else {
            return
        }
        let observers = state.blockedObservers
        state.blockedObservers.removeAll(keepingCapacity: false)
        for observer in observers {
            observer.resume()
        }
    }

    private func cancelWaiter(id: UUID, waiter: Waiter) {
        let removed = state.withLock { state -> Bool in
            guard state.waiters[id] === waiter else {
                return false
            }
            state.waiters.removeValue(forKey: id)
            return true
        }
        if removed {
            waiter.resolve(.failure(CancellationError()))
        }
    }

}

/// An in-memory app-server transport for tests.
public actor CodexAppServerTestTransport {
    private enum ThreadRuntimeMode: Sendable {
        case queuedResponses
        case authoritativeThreadStore(CodexAppServerTestThreadStore)
    }

    package nonisolated let connectionEventHub = ConnectionEventHub()
    private struct RequestGate: Sendable {
        var gate: CodexAppServerTestGate
        var ignoresCancellation: Bool

        func wait() async throws {
            if ignoresCancellation {
                await gate.waitIgnoringCancellation()
            } else {
                try await gate.wait()
            }
        }
    }

    private enum QueuedResponse: Sendable {
        case success(Data)
        case failure(JSONRPC.Error)
    }

    private typealias ResponseHandler = @Sendable (Data) async throws -> Data

    private var responses: [String: [QueuedResponse]] = [:]
    private var responseHandlers: [String: ResponseHandler] = [:]
    private var requests: [JSONRPC.Request] = []
    private var notifications: [JSONRPC.Notification] = []
    private let mailbox = JSONRPCInboundFrameMailbox()
    private var pendingResponses: [Int: JSONRPCResponseWaiter] = [:]
    private var serverRequestResponses: [CodexAppServerTestServerResponse] = []
    private var serverRequestResponseWaiters:
        [CodexServerRequestID: [CheckedContinuation<CodexServerRequestResponse?, Never>]] = [:]
    private var activeByMethod: [String: Int] = [:]
    private var maxActiveByMethod: [String: Int] = [:]
    private var gatesByMethod: [String: RequestGate] = [:]
    private var oneShotGatesByMethod: [String: [RequestGate]] = [:]
    private var activeRequestGatesByRequestID: [Int: RequestGate] = [:]
    private var requestCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var requestMethodWaiters: [(String, Int, CheckedContinuation<Void, Never>)] = []
    private var notificationStreamCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var inboundEventDeliveryGate: CodexAppServerTestGate?
    private var isHoldingInboundEventDelivery = false
    private var inboundEventDeliveryHeldWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasInboundConsumer = false
    private var inboundTerminalObserved = false
    private var closed = false
    private var closeStarted = false
    private var threadRuntimeMode: ThreadRuntimeMode?

    /// Creates an in-memory app-server transport.
    public init() {}

    package init(responses: [String: [Data]]) {
        self.responses = responses.mapValues { $0.map(QueuedResponse.success) }
    }

    /// Package-only raw response seam for codec and malformed-protocol tests.
    package func enqueue<Response: Encodable & Sendable>(
        _ response: Response,
        for method: String
    ) throws {
        try registerQueuedThreadResponse(for: method)
        responses[method, default: []].append(.success(try JSONEncoder().encode(response)))
    }

    /// Package-only reusable raw handler seam for protocol tests.
    package func handle(
        method: String,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws {
        try registerQueuedThreadResponse(for: method)
        responseHandlers[method] = handler
    }

    package func clearHandler(method: String) {
        responseHandlers[method] = nil
    }

    /// Handles repeated turn-interrupt requests through their canonical typed contract.
    public func handleTurnInterrupt(
        _ handler: @escaping @Sendable (CodexAppServerTestTurnInterruptRequest) async throws -> Void
    ) throws {
        try handle(method: AppServerAPI.Turn.Interrupt.Request.method) { params in
            let request = try JSONDecoder().decode(
                AppServerAPI.Turn.Interrupt.Params.self,
                from: params
            )
            try await handler(.init(
                threadID: .init(rawValue: request.threadID),
                turnID: .init(rawValue: request.turnID)
            ))
            return try JSONEncoder().encode(EmptyResponse())
        }
    }

    /// Package-only reusable raw response seam for protocol tests.
    package func stub<Response: Encodable & Sendable>(
        _ response: Response,
        for method: String
    ) throws {
        let encoded = try JSONEncoder().encode(response)
        try handle(method: method) { _ in encoded }
    }

    /// Package-only malformed/future-schema response seam.
    package func enqueueJSON(_ json: String, for method: String) throws {
        try registerQueuedThreadResponse(for: method)
        responses[method, default: []].append(.success(Data(json.utf8)))
    }

    /// Package-only reusable malformed/future-schema response seam.
    package func stubJSON(_ json: String, for method: String) throws {
        let encoded = Data(json.utf8)
        try handle(method: method) { _ in encoded }
    }

    /// Package-only failure seam for request error tests.
    package func enqueueFailure(code: Int, message: String, for method: String) {
        responses[method, default: []].append(.failure(.responseError(.init(
            code: code,
            message: message
        ))))
    }

    package func enqueueFailure(_ error: JSONRPC.Error, for method: String) {
        responses[method, default: []].append(.failure(error))
    }

    /// Enqueues a response failure for one supported public Testing operation.
    public func enqueueFailure(
        _ failure: CodexAppServerTestRequestFailure,
        for operation: CodexAppServerTestOperation
    ) throws {
        try registerQueuedThreadResponse(for: operation.method)
        responses[operation.method, default: []].append(.failure(failure.jsonRPCError))
    }

    /// Enqueues a pinned empty-object success response.
    public func enqueueSuccess(for operation: CodexAppServerTestOperation) throws {
        switch operation {
        case .threadArchive, .threadDelete, .threadRename, .threadCompact,
            .turnInterrupt, .accountLogout:
            try enqueue(EmptyResponse(), for: operation.method)
        case .initialize, .threadStart, .threadResume, .threadFork, .threadList,
            .threadRead, .threadTurnsList, .threadUnarchive, .threadRollback,
            .turnStart, .reviewStart, .modelList, .accountRead,
            .accountRateLimitsRead, .accountLoginStart, .accountLoginCancel,
            .configurationRead, .configurationUpdate:
            throw CodexAppServerTestError.invalidFixture(
                "\(operation.method) requires its typed Testing response."
            )
        }
    }

    /// Package-only empty response seam for pinned codec tests.
    package func enqueueEmpty(for method: String) throws {
        try enqueue(EmptyResponse(), for: method)
    }

    /// Enqueues a thread-start response from its complete canonical fixture.
    public func enqueueThreadStart(
        _ thread: CodexAppServerTestStoredThread
    ) throws {
        try enqueue(thread.runtimeResponseWireValue(includingTurns: false), for: "thread/start")
    }

    /// Enqueues a thread-resume response from its complete canonical fixture.
    public func enqueueThreadResume(
        _ thread: CodexAppServerTestStoredThread,
        initialTurnsPage: CodexAppServerTestTurnPage? = nil
    ) throws {
        try enqueue(
            thread.runtimeResponseWireValue(
                includingTurns: true,
                initialTurnsPage: initialTurnsPage
            ),
            for: "thread/resume"
        )
    }

    /// Enqueues a thread-fork response from its complete canonical fixture.
    public func enqueueThreadFork(
        _ thread: CodexAppServerTestStoredThread
    ) throws {
        try enqueue(thread.runtimeResponseWireValue(includingTurns: true), for: "thread/fork")
    }

    /// Enqueues a thread-list response from validated stored fixtures.
    public func enqueueThreadList(_ page: CodexAppServerTestThreadPage) throws {
        try enqueue(page.wireValue, for: "thread/list")
    }

    /// Enqueues a thread-read response from its complete canonical fixture.
    public func enqueueThreadRead(
        _ thread: CodexAppServerTestStoredThread
    ) throws {
        try enqueue(
            CodexJSONValue.object(["thread": thread.wireValue(includingTurns: true)]),
            for: "thread/read"
        )
    }

    /// Enqueues a thread-turns-list response from validated turn fixtures.
    public func enqueueThreadTurns(_ page: CodexAppServerTestTurnPage) throws {
        try enqueue(page.wireValue, for: "thread/turns/list")
    }

    /// Stubs thread operations from validated opaque fixtures.
    ///
    /// This is useful for UI previews and tests that should exercise the same
    /// app-server/DataKit path repeatedly without launching a real app-server.
    public func stubThreads(
        _ threads: [CodexAppServerTestStoredThread]
    ) throws {
        let store = try CodexAppServerTestThreadStore(threads: threads)
        try stubThreads(store)
    }

    /// Stubs thread requests from an in-memory store that callers can mutate later.
    ///
    /// The store remains the authoritative source for `thread/list`,
    /// `thread/read`, `thread/resume`, and `thread/start` responses.
    public func stubThreads(_ store: CodexAppServerTestThreadStore) throws {
        try configureAuthoritativeThreadStore(store)
        try handleAuthoritativeThreadMethod(method: "thread/start") { params in
            try await store.startThreadResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/fork") { params in
            try await store.forkThreadResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/list") { params in
            try await store.listThreadResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/resume") { params in
            try await store.resumeThreadResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/read") { params in
            try await store.readThreadResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/turns/list") { params in
            try await store.listThreadTurnsResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/archive") { params in
            try await store.archiveThreadResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/unarchive") { params in
            try await store.unarchiveThreadResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/delete") { params in
            try await store.deleteThreadResponse(for: params)
        }
        try handleAuthoritativeThreadMethod(method: "thread/name/set") { params in
            try await store.setThreadNameResponse(for: params)
        }
    }

    private func handleAuthoritativeThreadMethod(
        method: String,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws {
        guard case .authoritativeThreadStore = threadRuntimeMode else {
            throw CodexAppServerTestError.invalidFixture(
                "Authoritative thread handlers require thread-store mode."
            )
        }
        responseHandlers[method] = handler
    }

    private func configureAuthoritativeThreadStore(
        _ store: CodexAppServerTestThreadStore
    ) throws {
        switch threadRuntimeMode {
        case nil:
            threadRuntimeMode = .authoritativeThreadStore(store)
        case .authoritativeThreadStore(let existing) where existing === store:
            return
        case .authoritativeThreadStore:
            throw CodexAppServerTestError.invalidFixture(
                "A test transport can bind exactly one authoritative thread store."
            )
        case .queuedResponses:
            throw CodexAppServerTestError.invalidFixture(
                "Queued thread responses and an authoritative thread store are mutually exclusive."
            )
        }
    }

    private func registerQueuedThreadResponse(for method: String) throws {
        guard Self.threadOwnedMethods.contains(method) else {
            return
        }
        switch threadRuntimeMode {
        case nil:
            threadRuntimeMode = .queuedResponses
        case .queuedResponses:
            return
        case .authoritativeThreadStore:
            throw CodexAppServerTestError.invalidFixture(
                "Cannot enqueue \(method) while an authoritative thread store owns thread state."
            )
        }
    }

    private static let threadOwnedMethods: Set<String> = [
        "thread/start",
        "thread/fork",
        "thread/list",
        "thread/read",
        "thread/resume",
        "thread/turns/list",
        "thread/archive",
        "thread/unarchive",
        "thread/delete",
        "thread/name/set",
    ]

    /// Enqueues a thread-unarchive response from its canonical fixture.
    public func enqueueThreadUnarchive(
        _ thread: CodexAppServerTestStoredThread
    ) throws {
        try enqueue(
            CodexJSONValue.object(["thread": thread.wireValue(includingTurns: false)]),
            for: "thread/unarchive"
        )
    }

    /// Enqueues a thread-rollback response from its canonical fixture.
    public func enqueueThreadRollback(
        _ thread: CodexAppServerTestStoredThread
    ) throws {
        try enqueue(
            CodexJSONValue.object(["thread": thread.wireValue(includingTurns: true)]),
            for: "thread/rollback"
        )
    }

    /// Enqueues a turn-start response from its canonical fixture.
    public func enqueueTurnStart(_ turn: CodexAppServerTestTurn) throws {
        try enqueue(CodexJSONValue.object(["turn": turn.wireValue]), for: "turn/start")
    }

    /// Enqueues a review-start response from its canonical fixture.
    public func enqueueReviewStart(
        _ turn: CodexAppServerTestTurn,
        reviewThreadID: CodexThreadID
    ) throws {
        try enqueue(
            CodexJSONValue.object([
                "turn": turn.wireValue,
                "reviewThreadId": .string(reviewThreadID.rawValue),
            ]),
            for: "review/start"
        )
    }

    /// Enqueues a model-list response from its opaque canonical fixture.
    public func enqueueModels(_ page: CodexAppServerTestModelPage) throws {
        try enqueue(page.wireValue, for: CodexAppServerTestOperation.modelList.method)
    }

    package func enqueueModels(_ models: [CodexModel], nextCursor: String? = nil) throws {
        try enqueue(
            AppServerAPI.Model.List.Response(data: models, nextCursor: nextCursor),
            for: "model/list"
        )
    }

    /// Enqueues an account-read response from its opaque canonical fixture.
    public func enqueueAccount(
        _ account: CodexAppServerTestAccount?,
        requiresOpenAIAuth: Bool
    ) throws {
        try enqueue(
            CodexJSONValue.object([
                "account": account?.wireValue ?? .null,
                "requiresOpenaiAuth": .bool(requiresOpenAIAuth),
            ]),
            for: CodexAppServerTestOperation.accountRead.method
        )
    }

    /// Enqueues a config-read response from its opaque canonical fixture.
    public func enqueueConfiguration(
        _ result: CodexAppServerTestConfigurationReadResult
    ) throws {
        try enqueue(
            result.wireValue,
            for: CodexAppServerTestOperation.configurationRead.method
        )
    }

    package func enqueueConfiguration(_ configuration: CodexConfiguration) throws {
        try enqueue(
            AppServerAPI.Config.Read.Response(config: .init(
                model: configuration.model,
                reviewModel: configuration.reviewModel,
                modelReasoningEffort: configuration.reasoningEffort?.rawValue,
                serviceTier: configuration.serviceTier
            )),
            for: "config/read"
        )
    }

    /// Enqueues a config-write response from its opaque canonical fixture.
    public func enqueueConfigurationWrite(
        _ result: CodexAppServerTestConfigurationWriteResult
    ) throws {
        try enqueue(
            result.wireValue,
            for: CodexAppServerTestOperation.configurationUpdate.method
        )
    }

    /// Enqueues an account rate-limit response from its opaque canonical fixture.
    public func enqueueRateLimits(_ response: CodexAppServerTestRateLimitsResponse) throws {
        try enqueue(
            response.wireValue,
            for: CodexAppServerTestOperation.accountRateLimitsRead.method
        )
    }

    package func enqueueRateLimits(_ rateLimits: CodexRateLimits) throws {
        let windows = rateLimits.windows
        let primary = windows.first.map(Self.window)
        let secondary = windows.dropFirst().first.map(Self.window)
        try enqueue(
            AppServerAPI.Account.RateLimits.Response(rateLimits: .init(
                limitID: "codex",
                primary: primary,
                secondary: secondary,
                planType: rateLimits.planType
            )),
            for: "account/rateLimits/read"
        )
    }

    fileprivate static func filteredThreadSnapshots(
        _ snapshots: [CodexThreadSnapshot],
        for request: AppServerAPI.Thread.List.Params
    ) -> [CodexThreadSnapshot] {
        enum SourceFilter {
            case interactiveDefaults
            case explicit([CodexThreadSourceKind])

            init(_ rawKinds: [String]?) {
                guard let rawKinds, rawKinds.isEmpty == false else {
                    self = .interactiveDefaults
                    return
                }
                self = .explicit(rawKinds.map(CodexThreadSourceKind.init(rawValue:)))
            }

            func includes(_ source: CodexThreadSessionSource) -> Bool {
                switch self {
                case .interactiveDefaults:
                    switch source {
                    case .cli, .vscode, .custom("atlas"), .custom("chatgpt"):
                        true
                    case .exec, .appServer, .custom, .subAgent, .unknown:
                        false
                    }
                case .explicit(let kinds):
                    kinds.contains(where: source.matches(sourceKind:))
                }
            }
        }

        let workspacePaths: Set<String>?
        switch request.cwd {
        case .paths(let paths):
            workspacePaths = Set(paths)
        case nil:
            workspacePaths = nil
        }
        let sourceFilter = SourceFilter(request.sourceKinds)

        return snapshots.filter { snapshot in
            if let workspacePaths {
                guard let path = snapshot.workspace?.path,
                    workspacePaths.contains(path)
                else {
                    return false
                }
            }
            if let modelProviders = request.modelProviders,
                modelProviders.isEmpty == false,
                modelProviders.contains(snapshot.modelProvider ?? "") == false
            {
                return false
            }
            guard let source = snapshot.source else {
                preconditionFailure("A stored-thread fixture must have an exact session source.")
            }
            guard sourceFilter.includes(source) else {
                return false
            }
            if let searchTerm = request.searchTerm?.lowercased(),
                searchTerm.isEmpty == false
            {
                let haystack = [
                    snapshot.name,
                    snapshot.preview,
                    snapshot.workspace?.lastPathComponent,
                ]
                .compactMap { $0?.lowercased() }
                .joined(separator: "\n")
                guard haystack.contains(searchTerm) else {
                    return false
                }
            }
            return true
        }
    }

    fileprivate static func sortedThreadSnapshots(
        _ snapshots: [CodexThreadSnapshot],
        sortKey: String?,
        sortDirection: String?
    ) throws -> [CodexThreadSnapshot] {
        let rawKey = sortKey ?? CodexThreadSortKey.createdAt.rawValue
        guard let key = CodexThreadSortKey(rawValue: rawKey) else {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "Unsupported test thread sort key \(rawKey)."
            ))
        }
        let rawDirection = sortDirection ?? CodexSortDirection.descending.rawValue
        guard let direction = CodexSortDirection(rawValue: rawDirection) else {
            throw JSONRPC.Error.responseError(.init(
                code: -32602,
                message: "Unsupported test thread sort direction \(rawDirection)."
            ))
        }
        let indexed = snapshots.enumerated().map { (offset: $0.offset, snapshot: $0.element) }
        return indexed.sorted { lhs, rhs in
            let lhsDate = threadSortDate(lhs.snapshot, key: key)
            let rhsDate = threadSortDate(rhs.snapshot, key: key)
            if lhsDate == rhsDate {
                if key == .recencyAt {
                    switch direction {
                    case .ascending:
                        return lhs.snapshot.id.rawValue < rhs.snapshot.id.rawValue
                    case .descending:
                        return lhs.snapshot.id.rawValue > rhs.snapshot.id.rawValue
                    }
                }
                return lhs.offset < rhs.offset
            }
            switch direction {
            case .ascending:
                return compareOptionalDate(lhsDate, rhsDate, ascending: true)
            case .descending:
                return compareOptionalDate(lhsDate, rhsDate, ascending: false)
            }
        }.map(\.snapshot)
    }

    private static func threadSortDate(
        _ snapshot: CodexThreadSnapshot,
        key: CodexThreadSortKey
    ) -> Date? {
        switch key {
        case .createdAt:
            snapshot.createdAt
        case .updatedAt:
            snapshot.updatedAt
        case .recencyAt:
            snapshot.recencyAt
        }
    }

    private static func compareOptionalDate(
        _ lhs: Date?,
        _ rhs: Date?,
        ascending: Bool
    ) -> Bool {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            return ascending ? lhs < rhs : lhs > rhs
        case (nil, .some):
            return ascending
        case (.some, nil):
            return ascending == false
        case (nil, nil):
            return false
        }
    }

    /// Enqueues a ChatGPT browser login response.
    public func enqueueChatGPTLogin(
        loginID: String,
        authenticationURL: URL
    ) throws {
        try enqueue(
            AppServerAPI.Account.Login.Response.chatgpt(
                loginID: loginID,
                authURL: authenticationURL.absoluteString
            ),
            for: "account/login/start"
        )
    }

    public func enqueueChatGPTLoginCancellation(
        _ status: CodexAppServerTestLoginCancellationStatus
    ) throws {
        try enqueue(
            AppServerAPI.Account.Login.Cancel.Response(status: status.wireValue),
            for: CodexAppServerTestOperation.accountLoginCancel.method
        )
    }

    /// Enqueues a ChatGPT device-code login response.
    public func enqueueChatGPTDeviceCodeLogin(
        loginID: String,
        verificationURL: URL,
        userCode: String
    ) throws {
        try enqueue(
            AppServerAPI.Account.Login.Response.chatgptDeviceCode(
                loginID: loginID,
                verificationURL: verificationURL.absoluteString,
                userCode: userCode
            ),
            for: "account/login/start"
        )
    }

    /// Enqueues an API-key login response.
    public func enqueueAPIKeyLogin() throws {
        try enqueue(AppServerAPI.Account.Login.Response.apiKey, for: "account/login/start")
    }

    private static func semanticRequest(
        from raw: JSONRPC.Request
    ) throws -> CodexAppServerTestRequest {
        let decoder = JSONDecoder()
        guard let operation = CodexAppServerTestOperation(method: raw.method) else {
            throw CodexAppServerTestError.invalidFixture(
                "Unsupported semantic Testing request method \(raw.method)."
            )
        }
        switch operation {
        case .initialize:
            return .initialize
        case .threadStart:
            let params = try decoder.decode(AppServerAPI.Thread.Start.Params.self, from: raw.params)
            guard let cwd = params.cwd else {
                throw CodexAppServerTestError.invalidFixture(
                    "A recorded thread/start request requires cwd."
                )
            }
            return .threadStart(
                workspace: URL(fileURLWithPath: cwd, isDirectory: true),
                instructions: instructions(from: params),
                options: threadOptions(from: params)
            )
        case .threadResume:
            let params = try decoder.decode(AppServerAPI.Thread.Resume.Params.self, from: raw.params)
            guard let threadID = params.threadID else {
                throw CodexAppServerTestError.invalidFixture(
                    "A recorded thread/resume request requires threadId."
                )
            }
            return .threadResume(
                id: .init(rawValue: threadID),
                options: threadOptions(from: params)
            )
        case .threadFork:
            let params = try decoder.decode(AppServerAPI.Thread.Fork.Params.self, from: raw.params)
            guard let threadID = params.threadID else {
                throw CodexAppServerTestError.invalidFixture(
                    "A recorded thread/fork request requires threadId."
                )
            }
            return .threadFork(
                id: .init(rawValue: threadID),
                options: threadOptions(from: params)
            )
        case .threadList:
            let params = try decoder.decode(AppServerAPI.Thread.List.Params.self, from: raw.params)
            let workspaces: [URL]?
            switch params.cwd {
            case .paths(let paths):
                workspaces = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            case nil:
                workspaces = nil
            }
            return .threadList(.init(
                archived: params.archived,
                cursor: params.cursor,
                workspaces: workspaces,
                limit: params.limit,
                searchTerm: params.searchTerm,
                modelProviders: params.modelProviders,
                sortDirection: params.sortDirection.flatMap(CodexSortDirection.init(rawValue:)),
                sortKey: params.sortKey.flatMap(CodexThreadSortKey.init(rawValue:)),
                sourceKinds: params.sourceKinds?.map(CodexThreadSourceKind.init(rawValue:)),
                useStateDBOnly: params.useStateDbOnly
            ))
        case .threadRead:
            let params = try decoder.decode(AppServerAPI.Thread.Read.Params.self, from: raw.params)
            return .threadRead(
                id: .init(rawValue: params.threadID),
                includeTurns: params.includeTurns ?? false
            )
        case .threadTurnsList:
            let params = try decoder.decode(
                AppServerAPI.Thread.Turns.List.Params.self,
                from: raw.params
            )
            return .threadTurnsList(
                threadID: .init(rawValue: params.threadID),
                query: .init(
                    cursor: params.cursor,
                    limit: params.limit,
                    sortDirection: params.sortDirection,
                    itemsLoadState: params.itemsLoadState
                )
            )
        case .threadArchive:
            let params = try decoder.decode(AppServerAPI.Thread.Archive.Params.self, from: raw.params)
            return .threadArchive(.init(rawValue: params.threadID))
        case .threadUnarchive:
            let params = try decoder.decode(
                AppServerAPI.Thread.Unarchive.Params.self,
                from: raw.params
            )
            return .threadUnarchive(.init(rawValue: params.threadID))
        case .threadDelete:
            let params = try decoder.decode(AppServerAPI.Thread.Delete.Params.self, from: raw.params)
            return .threadDelete(.init(rawValue: params.threadID))
        case .threadRename:
            let params = try decoder.decode(AppServerAPI.Thread.Name.Set.Params.self, from: raw.params)
            return .threadRename(id: .init(rawValue: params.threadID), name: params.name)
        case .threadCompact:
            let params = try decoder.decode(
                AppServerAPI.Thread.Compact.Start.Params.self,
                from: raw.params
            )
            return .threadCompact(.init(rawValue: params.threadID))
        case .threadRollback:
            let params = try decoder.decode(AppServerAPI.Thread.Rollback.Params.self, from: raw.params)
            return .threadRollback(
                id: .init(rawValue: params.threadID),
                numberOfTurns: params.numTurns
            )
        case .turnStart:
            let params = try decoder.decode(AppServerAPI.Turn.Start.Params.self, from: raw.params)
            return .turnStart(
                threadID: .init(rawValue: params.threadID),
                prompt: prompt(from: params.input),
                options: generationOptions(from: params)
            )
        case .turnInterrupt:
            let params = try decoder.decode(AppServerAPI.Turn.Interrupt.Params.self, from: raw.params)
            return .turnInterrupt(
                threadID: .init(rawValue: params.threadID),
                turnID: .init(rawValue: params.turnID)
            )
        case .reviewStart:
            let params = try decoder.decode(AppServerAPI.Review.Start.Params.self, from: raw.params)
            return .reviewStart(
                threadID: .init(rawValue: params.threadID),
                target: params.target,
                delivery: params.delivery
            )
        case .modelList:
            let params = try decoder.decode(AppServerAPI.Model.List.Params.self, from: raw.params)
            return .modelList(includeHidden: params.includeHidden ?? false)
        case .accountRead:
            let params = try decoder.decode(AppServerAPI.Account.Read.Params.self, from: raw.params)
            return .accountRead(refreshToken: params.refreshToken)
        case .accountRateLimitsRead:
            return .accountRateLimitsRead
        case .accountLoginStart:
            return .accountLoginStart
        case .accountLoginCancel:
            let params = try decoder.decode(AppServerAPI.Account.Login.Cancel.Params.self, from: raw.params)
            return .accountLoginCancel(.init(rawValue: params.loginID))
        case .accountLogout:
            return .accountLogout
        case .configurationRead:
            return .configurationRead
        case .configurationUpdate:
            return .configurationUpdate(try configurationPatch(from: raw.params))
        }
    }

    private static func instructions(
        from params: AppServerAPI.Thread.Start.Params
    ) -> CodexInstructions? {
        guard params.baseInstructions != nil || params.developerInstructions != nil else {
            return nil
        }
        return .init(
            base: params.baseInstructions,
            developer: params.developerInstructions
        )
    }

    private static func threadOptions(
        from params: AppServerAPI.Thread.Start.Params
    ) -> CodexThread.Options {
        let permissions: CodexThreadPermissions?
        switch params.permissions {
        case .profileID(let id):
            permissions = .profile(id: id)
        case .profileSelection(let selection):
            permissions = .profileSelection(id: selection.id)
        case nil:
            permissions = nil
        }
        return .init(
            model: params.model,
            modelProvider: params.modelProvider,
            approvalMode: approvalMode(
                policy: params.approvalPolicy,
                reviewer: params.approvalsReviewer
            ),
            sandbox: params.sandbox.flatMap(sandbox(from:)),
            permissions: permissions,
            serviceTier: params.serviceTier,
            ephemeral: params.ephemeral,
            config: params.config?.mapValues { codexJSONValue(from: $0) },
            personality: params.personality.map(CodexPersonality.init(rawValue:)),
            serviceName: params.serviceName,
            sessionStartSource: params.sessionStartSource.map {
                switch $0 {
                case .startup: .startup
                case .clear: .clear
                }
            },
            threadSource: params.threadSource.map {
                CodexThreadSource(rawValue: $0.rawValue)
            }
        )
    }

    private static func generationOptions(
        from params: AppServerAPI.Turn.Start.Params
    ) -> CodexGenerationOptions {
        .init(
            model: params.model,
            approvalMode: approvalMode(
                policy: params.approvalPolicy,
                reviewer: params.approvalsReviewer
            ),
            sandbox: params.sandboxPolicy.map(sandbox(from:)),
            cwd: params.cwd.map { URL(fileURLWithPath: $0, isDirectory: true) },
            effort: params.effort.map(CodexReasoningEffort.init(rawValue:)),
            serviceTier: params.serviceTier,
            summary: params.summary.map(CodexReasoningSummary.init(rawValue:)),
            outputSchema: params.outputSchema.map(codexJSONValue(from:)),
            personality: params.personality.map(CodexPersonality.init(rawValue:)),
            clientUserMessageID: params.clientUserMessageID
        )
    }

    private static func codexJSONValue(
        from value: AppServerJSONValue
    ) -> CodexJSONValue {
        switch value {
        case .string(let value):
            .string(value)
        case .int(let value):
            .int(value)
        case .double(let value):
            .double(value)
        case .bool(let value):
            .bool(value)
        case .array(let values):
            .array(values.map { codexJSONValue(from: $0) })
        case .object(let values):
            .object(values.mapValues { codexJSONValue(from: $0) })
        case .null:
            .null
        }
    }

    private static func approvalMode(
        policy: String?,
        reviewer: String?
    ) -> CodexApprovalMode? {
        if policy == "never" {
            return .denyAll
        }
        if policy == "on-request", reviewer == "auto_review" {
            return .autoReview
        }
        return nil
    }

    private static func sandbox(from value: String) -> CodexSandbox? {
        switch value {
        case "read-only": .readOnly
        case "workspace-write": .workspaceWrite
        case "danger-full-access": .fullAccess
        default: nil
        }
    }

    private static func sandbox(
        from value: AppServerAPI.Turn.SandboxPolicy
    ) -> CodexSandbox {
        switch value {
        case .readOnly: .readOnly
        case .workspaceWrite: .workspaceWrite
        case .dangerFullAccess: .fullAccess
        }
    }

    private static func prompt(from input: [AppServerAPI.UserInput]) -> CodexPrompt {
        .init(parts: input.compactMap { input -> CodexPrompt.Part? in
            switch input {
            case .text(let value):
                .text(value)
            case .image(let value):
                URL(string: value).map(CodexPrompt.Part.imageURL)
            case .localImage(let value):
                .localImage(URL(fileURLWithPath: value))
            case .skill(let name, let path):
                .skill(name: name, path: URL(fileURLWithPath: path))
            case .mention(let name, let path):
                .mention(name: name, path: URL(fileURLWithPath: path))
            }
        })
    }

    private struct RecordedConfigurationEdit: Decodable {
        var keyPath: String
        var value: CodexJSONValue
    }

    private struct RecordedConfigurationUpdate: Decodable {
        var edits: [RecordedConfigurationEdit]
    }

    private static func configurationPatch(from data: Data) throws -> CodexConfigurationPatch {
        let update = try JSONDecoder().decode(RecordedConfigurationUpdate.self, from: data)
        var patch = CodexConfigurationPatch()
        for edit in update.edits {
            let value: String?
            switch edit.value {
            case .string(let string):
                value = string
            case .null:
                value = nil
            case .int, .double, .bool, .array, .object:
                throw CodexAppServerTestError.invalidFixture(
                    "Unsupported recorded config value for \(edit.keyPath)."
                )
            }
            switch edit.keyPath {
            case "review_model":
                patch.setReviewModel(value)
            case "model_reasoning_effort":
                patch.setReasoningEffort(value.map(CodexReasoningEffort.init(rawValue:)))
            case "service_tier":
                patch.setServiceTier(value)
            default:
                throw CodexAppServerTestError.invalidFixture(
                    "Unsupported recorded config key \(edit.keyPath)."
                )
            }
        }
        return patch
    }

    /// Holds every request for `method` until `gate` opens.
    package func hold(method: String, gate: CodexAppServerTestGate) {
        gatesByMethod[method] = .init(gate: gate, ignoresCancellation: false)
    }

    /// Holds the next request for `method` until `gate` opens.
    package func holdNext(method: String, gate: CodexAppServerTestGate) {
        oneShotGatesByMethod[method, default: []].append(.init(
            gate: gate,
            ignoresCancellation: false
        ))
    }

    /// Holds the next request for `method` and ignores task cancellation while waiting.
    package func holdNextIgnoringCancellation(method: String, gate: CodexAppServerTestGate) {
        oneShotGatesByMethod[method, default: []].append(.init(
            gate: gate,
            ignoresCancellation: true
        ))
    }

    /// Returns all requests sent so far.
    public func holdNext(
        _ operation: CodexAppServerTestOperation,
        gate: CodexAppServerTestGate
    ) {
        holdNext(method: operation.method, gate: gate)
    }

    public func holdNextIgnoringCancellation(
        _ operation: CodexAppServerTestOperation,
        gate: CodexAppServerTestGate
    ) {
        holdNextIgnoringCancellation(method: operation.method, gate: gate)
    }

    public func recordedRequests() -> [CodexAppServerRecordedRequest] {
        requests.enumerated().compactMap { offset, raw in
            guard let request = try? Self.semanticRequest(from: raw) else {
                return nil
            }
            return .init(
                sequence: UInt64(offset + 1),
                requestID: raw.id,
                request: request,
                method: raw.method,
                params: raw.params
            )
        }
    }

    /// Returns all requests sent so far for `method`.
    package func recordedRequests(method: String) -> [CodexAppServerRecordedRawRequest] {
        requests.enumerated().compactMap { offset, raw in
            guard raw.method == method else {
                return nil
            }
            return .init(
                sequence: UInt64(offset + 1),
                requestID: raw.id,
                method: raw.method,
                params: raw.params
            )
        }
    }

    public func recordedRequests(
        for operation: CodexAppServerTestOperation
    ) -> [CodexAppServerRecordedRequest] {
        recordedRequests().filter { $0.request.operation == operation }
    }

    /// Returns all client notifications sent so far.
    package func recordedNotifications() -> [CodexAppServerRecordedNotification] {
        notifications.map { .init(method: $0.method, params: $0.params) }
    }

    /// Suspends until at least `count` requests have been sent.
    public func waitForRequestCount(_ count: Int) async {
        if requests.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if requests.count >= count {
                continuation.resume()
            } else {
                requestCountWaiters.append((count, continuation))
            }
        }
    }

    /// Suspends until at least `count` requests for `method` have been sent.
    package func waitForRequest(method: String, count: Int = 1) async {
        if requests.filter({ $0.method == method }).count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            if requests.filter({ $0.method == method }).count >= count {
                continuation.resume()
            } else {
                requestMethodWaiters.append((method, count, continuation))
            }
        }
    }

    public func waitForRequest(
        _ operation: CodexAppServerTestOperation,
        count: Int = 1
    ) async {
        await waitForRequest(method: operation.method, count: count)
    }

    /// Suspends until at least `count` notification stream consumers are attached.
    public func waitForNotificationStreamCount(_ count: Int) async {
        let consumerCount = hasInboundConsumer ? 1 : 0
        if consumerCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            let consumerCount = hasInboundConsumer ? 1 : 0
            if consumerCount >= count {
                continuation.resume()
            } else {
                notificationStreamCountWaiters.append((count, continuation))
            }
        }
    }

    /// Returns the maximum number of in-flight requests observed for `method`.
    package func maxActiveCount(for method: String) -> Int {
        maxActiveByMethod[method] ?? 0
    }

    public func maxActiveCount(for operation: CodexAppServerTestOperation) -> Int {
        maxActiveCount(for: operation.method)
    }

    package func notificationStreamCount() -> Int {
        hasInboundConsumer ? 1 : 0
    }

    package func isClosedForTesting() -> Bool {
        closed
    }

    /// Emits a server notification to all attached app-server notification streams.
    package func emitServerNotification<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws {
        let notification = JSONRPC.Notification(
            method: method,
            params: try JSONEncoder().encode(params)
        )
        try await mailbox.send(JSONRPC.notificationFrame(notification))
    }

    /// Emits a server notification from a raw JSON object string.
    package func emitServerNotificationJSON(method: String, json: String) async throws {
        let notification = JSONRPC.Notification(
            method: method,
            params: Data(json.utf8)
        )
        try await mailbox.send(JSONRPC.notificationFrame(notification))
    }

    package func emitServerNotification(method: String, params: Data) async throws {
        try await mailbox.send(JSONRPC.notificationFrame(.init(
            method: method,
            params: params
        )))
    }

    package func emitServerRequest(
        id: CodexServerRequestID,
        method: String,
        params: Data
    ) async throws {
        try await mailbox.send(JSONRPC.serverRequestFrame(
            id: id,
            method: method,
            params: params
        ))
    }

    package func emitRawInboundFrame(_ frame: Data) async throws {
        try await mailbox.send(frame)
    }

    package func inboundMailboxSnapshot() async -> JSONRPCInboundFrameMailbox.Snapshot {
        await mailbox.snapshot()
    }

    package func holdNextInboundEventDelivery(at gate: CodexAppServerTestGate) {
        precondition(
            inboundEventDeliveryGate == nil,
            "Only one inbound event delivery can be held at a time."
        )
        inboundEventDeliveryGate = gate
    }

    package func waitUntilInboundEventDeliveryIsHeld() async {
        guard isHoldingInboundEventDelivery == false else {
            return
        }
        await withCheckedContinuation { continuation in
            inboundEventDeliveryHeldWaiters.append(continuation)
        }
    }

    package func recordedServerRequestResponses() -> [CodexAppServerTestServerResponse] {
        serverRequestResponses
    }

    package func serverRequestResponse(
        for id: CodexServerRequestID
    ) async -> CodexServerRequestResponse? {
        if let response = serverRequestResponses.last(where: { $0.requestID == id }) {
            return response.response
        }
        return await withCheckedContinuation { continuation in
            serverRequestResponseWaiters[id, default: []].append(continuation)
        }
    }

    package func finishServerRequestWithoutResponse(_ id: CodexServerRequestID) {
        let waiters = serverRequestResponseWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    package func finishAllServerRequestsWithoutResponse() {
        let waiters = serverRequestResponseWaiters.values.flatMap { $0 }
        serverRequestResponseWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    /// Finishes all attached notification streams with `error`.
    package func finishNotificationStreams(throwing error: any Error) async {
        let failure = (error as? CodexTransportFailure) ?? .io(
            errno: (error as? POSIXError)?.code.rawValue,
            message: error.localizedDescription
        )
        await mailbox.finish(throwing: failure)
    }

    public func failConnection(_ failure: CodexTransportFailure) async {
        await mailbox.finish(throwing: failure)
    }

    package func enqueueInitialize(codexHome: String?, userAgent: String?) throws {
        try enqueue(
            AppServerAPI.Initialize.Response(codexHome: codexHome, userAgent: userAgent),
            for: "initialize"
        )
    }

    private func dequeueResponse(for method: String) -> QueuedResponse? {
        guard var queued = responses[method], queued.isEmpty == false else {
            return nil
        }
        let response = queued.removeFirst()
        responses[method] = queued
        return response
    }

    private func dequeueOneShotGate(for method: String) -> RequestGate? {
        guard var gates = oneShotGatesByMethod[method], gates.isEmpty == false else {
            return nil
        }
        let gate = gates.removeFirst()
        oneShotGatesByMethod[method] = gates
        return gate
    }

    private func resumeRequestCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestCountWaiters {
            if requests.count >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestCountWaiters = remaining
    }

    private func resumeRequestMethodWaiters() {
        var remaining: [(String, Int, CheckedContinuation<Void, Never>)] = []
        for waiter in requestMethodWaiters {
            let count = requests.filter { $0.method == waiter.0 }.count
            if count >= waiter.1 {
                waiter.2.resume()
            } else {
                remaining.append(waiter)
            }
        }
        requestMethodWaiters = remaining
    }

    private func resumeNotificationStreamCountWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in notificationStreamCountWaiters {
            if (hasInboundConsumer ? 1 : 0) >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        notificationStreamCountWaiters = remaining
    }

    private static func window(
        from window: CodexRateLimitWindow
    ) -> AppServerAPI.Account.RateLimits.Window {
        .init(
            usedPercent: window.usedPercent,
            windowDurationMins: window.windowDurationMinutes,
            resetsAt: window.resetsAt.map { Int64($0.timeIntervalSince1970) }
        )
    }
}

extension CodexAppServerTestTransport: JSONRPC.Transport {
    package func send(
        _ request: JSONRPC.Request,
        acceptWrite: @Sendable () throws -> Void
    ) async throws -> Data {
        try Task.checkCancellation()
        guard closed == false else {
            throw JSONRPC.Error.closed
        }
        try acceptWrite()

        let responseWaiter = JSONRPCResponseWaiter()
        pendingResponses[request.id] = responseWaiter
        requests.append(request)
        resumeRequestCountWaiters()
        resumeRequestMethodWaiters()
        activeByMethod[request.method, default: 0] += 1
        maxActiveByMethod[request.method] = max(
            maxActiveByMethod[request.method] ?? 0,
            activeByMethod[request.method] ?? 0
        )
        let queuedResponse = dequeueResponse(for: request.method)
        if let gate = dequeueOneShotGate(for: request.method) ?? gatesByMethod[request.method] {
            activeRequestGatesByRequestID[request.id] = gate
            try await gate.wait()
            activeRequestGatesByRequestID.removeValue(forKey: request.id)
        }
        activeByMethod[request.method, default: 1] -= 1

        let result: Result<Data, JSONRPC.Error>
        do {
            guard closed == false else {
                return try await responseWaiter.wait()
            }
            if let queuedResponse {
                switch queuedResponse {
                case .success(let data):
                    result = .success(data)
                case .failure(let error):
                    result = .failure(error)
                }
            } else if let responseHandler = responseHandlers[request.method] {
                do {
                    result = .success(try await responseHandler(request.params))
                } catch let error as JSONRPC.Error {
                    result = .failure(error)
                }
            } else {
                pendingResponses.removeValue(forKey: request.id)
                throw CodexTransportFailure.contractViolation(
                    message: "No test response is configured for \(request.method)."
                )
            }
            let frame = try JSONRPC.responseFrame(id: request.id, result: result)
            try await mailbox.send(frame)
        } catch is CancellationError {
            pendingResponses.removeValue(forKey: request.id)
            throw CancellationError()
        } catch let failure as CodexTransportFailure {
            if case .contractViolation = failure {
                pendingResponses.removeValue(forKey: request.id)
                throw failure
            }
            await claimTerminal(failure)
        } catch {
            await claimTerminal(.io(
                errno: (error as? POSIXError)?.code.rawValue,
                message: error.localizedDescription
            ))
        }
        return try await responseWaiter.wait()
    }

    package func notify(_ notification: JSONRPC.Notification) async throws {
        guard closed == false else {
            throw JSONRPC.Error.closed
        }
        notifications.append(notification)
    }

    package func nextInboundEvent() async throws -> JSONRPC.InboundEvent? {
        if hasInboundConsumer == false {
            hasInboundConsumer = true
            resumeNotificationStreamCountWaiters()
        }
        while true {
            let frame: Data
            do {
                guard let next = try await mailbox.next() else {
                    inboundTerminalObserved = true
                    return nil
                }
                frame = next
            } catch {
                let snapshot = await mailbox.snapshot()
                if snapshot.isTerminal, snapshot.acceptedFrameCount == 0 {
                    inboundTerminalObserved = true
                }
                throw error
            }
            if let gate = inboundEventDeliveryGate {
                isHoldingInboundEventDelivery = true
                let waiters = inboundEventDeliveryHeldWaiters
                inboundEventDeliveryHeldWaiters.removeAll(keepingCapacity: false)
                for waiter in waiters {
                    waiter.resume()
                }
                await gate.waitIgnoringCancellation()
                inboundEventDeliveryGate = nil
                isHoldingInboundEventDelivery = false
            }
            switch try JSONRPC.decodeInboundEnvelope(frame) {
            case .response(let id, let result):
                guard let waiter = pendingResponses.removeValue(forKey: id) else {
                    if closed {
                        connectionEventHub.yield(.warning(
                            ConnectionDiagnosticFactory.lateResponse(requestID: id)
                        ))
                        continue
                    }
                    let failure = CodexTransportFailure.protocolViolation(
                        message: "Received a JSON-RPC response for unknown request id \(id).",
                        rawData: frame
                    )
                    await claimTerminal(failure)
                    throw failure
                }
                waiter.resolve(result)
            case .event(let event):
                return event
            }
        }
    }

    package func respond(
        to requestID: CodexServerRequestID,
        with response: CodexServerRequestResponse
    ) throws {
        guard closed == false else {
            throw JSONRPC.Error.closed
        }
        serverRequestResponses.append(.init(requestID: requestID, response: response))
        let waiters = serverRequestResponseWaiters.removeValue(forKey: requestID) ?? []
        for waiter in waiters {
            waiter.resume(returning: response)
        }
    }

    package func beginClose() async -> JSONRPC.ProcessExitObservation? {
        guard closeStarted == false else {
            return nil
        }
        closeStarted = true
        closed = true
        let requestGates = Array(activeRequestGatesByRequestID.values)
            + Array(gatesByMethod.values)
            + oneShotGatesByMethod.values.flatMap { $0 }
        let inboundEventDeliveryGate = inboundEventDeliveryGate
        activeRequestGatesByRequestID.removeAll(keepingCapacity: false)
        gatesByMethod.removeAll(keepingCapacity: false)
        oneShotGatesByMethod.removeAll(keepingCapacity: false)
        for requestGate in requestGates {
            await requestGate.gate.close()
        }
        await inboundEventDeliveryGate?.close()
        await mailbox.finish()
        finishAllServerRequestsWithoutResponse()
        return nil
    }

    package func finishPendingResponsesAfterInboundDrain(
        _ failure: CodexTransportFailure
    ) {
        precondition(inboundTerminalObserved)
        let responseFailure: JSONRPC.Error = switch failure {
        case .closed: .closed
        case .io, .framing, .protocolViolation, .contractViolation:
            .invalidMessage(failure.localizedDescription)
        }
        let waiters = pendingResponses.values
        pendingResponses.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resolve(.failure(responseFailure))
        }
    }

    package func waitForProcessExit() async -> JSONRPC.ProcessExitObservation {
        .unavailable
    }

    package func waitUntilClosed() async {}

    package func reapProcess() async {}

    private func claimTerminal(_ failure: CodexTransportFailure) async {
        closed = true
        await mailbox.finish(throwing: failure)
    }

    public func close() async {
        _ = await beginClose()
    }
}
