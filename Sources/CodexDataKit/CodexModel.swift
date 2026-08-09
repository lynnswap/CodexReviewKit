import CodexAppServerKit
import Foundation
import Observation

public protocol CodexPersistentModel: AnyObject, Observable, Hashable, Identifiable, SendableMetatype
where ID: Hashable & Sendable {
    nonisolated var id: ID { get }

    var modelContext: CodexModelContext? { get }
}

extension CodexPersistentModel {
    public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

public struct CodexWorkspaceID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}

private extension Array where Element == CodexChatMutation {
    mutating func appendIfPresent(_ change: CodexChatMutation?) {
        if let change {
            append(change)
        }
    }

    var containsTurnItemMutation: Bool {
        contains { $0.affectedTurnID != nil }
    }
}

private extension CodexThreadItem {
    var isReviewModeMarker: Bool {
        switch kind {
        case .enteredReviewMode, .exitedReviewMode:
            true
        default:
            false
        }
    }

    var isExitedReviewModeMarker: Bool {
        kind == .exitedReviewMode
    }

    var isReviewNarrativeBoundary: Bool {
        switch kind {
        case .userMessage, .agentMessage, .enteredReviewMode, .exitedReviewMode:
            true
        default:
            false
        }
    }

    var command: CodexCommand? {
        guard case .command(let command) = content else {
            return nil
        }
        return command
    }
}

public struct CodexWorkspaceGroupID: RawRepresentable, Hashable, Sendable, Codable,
    CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String {
        rawValue
    }
}

public struct CodexChatItemID: Hashable, Sendable, Codable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(rawItemID: String, turnID: CodexTurnID?) {
        self.rawValue = Self.scopedRawValue(rawItemID, turnID: turnID)
    }

    package init(rawItemID: String, turnID: CodexTurnID?, chatID: CodexThreadID) {
        self.rawValue = Self.scopedRawValue(rawItemID, turnID: turnID, chatID: chatID)
    }

    public var description: String {
        rawValue
    }

    fileprivate static func scopedRawValue(
        _ value: String,
        turnID: CodexTurnID?,
        chatID: CodexThreadID? = nil
    ) -> String {
        if let turnID {
            return "\(turnID.rawValue):\(value)"
        }
        if let chatID {
            return "chat:\(chatID.rawValue):\(value)"
        }
        return value
    }
}

public struct CodexChatInput: Sendable {
    public var instructions: CodexInstructions?
    public var options: CodexThread.Options

    public init(
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init()
    ) {
        self.instructions = instructions
        self.options = options
    }
}

public struct CodexReviewInput: Sendable {
    public var target: CodexReviewTarget
    public var instructions: CodexInstructions?
    public var options: CodexThread.Options
    public var delivery: CodexReviewDelivery

    public init(
        target: CodexReviewTarget,
        instructions: CodexInstructions? = nil,
        options: CodexThread.Options = .init(),
        delivery: CodexReviewDelivery = .inline
    ) {
        self.target = target
        self.instructions = instructions
        self.options = options
        self.delivery = delivery
    }
}

public struct CodexStartedReview {
    public let chat: CodexChat
    public let session: CodexReviewSession

    public init(chat: CodexChat, session: CodexReviewSession) {
        self.chat = chat
        self.session = session
    }
}

public struct CodexChatMessageInput: Sendable {
    public var prompt: CodexPrompt
    public var options: CodexGenerationOptions

    public init(
        _ text: String,
        options: CodexGenerationOptions = .init()
    ) {
        self.prompt = CodexPrompt(text)
        self.options = options
    }

    public init(
        prompt: CodexPrompt,
        options: CodexGenerationOptions = .init()
    ) {
        self.prompt = prompt
        self.options = options
    }
}

@Observable
public final class CodexWorkspaceGroup: CodexPersistentModel {
    public let id: CodexWorkspaceGroupID
    public private(set) var name: String
    public private(set) var workspaces: [CodexWorkspace]

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    package init(
        id: CodexWorkspaceGroupID,
        name: String,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.name = name
        self.workspaces = []
        self.modelContext = modelContext
    }

    package func applyContextSnapshot(name: String) {
        self.name = name
    }

    package func replaceContextWorkspaces(_ workspaces: [CodexWorkspace]) {
        self.workspaces = workspaces
    }

}

private extension CodexTurnStatus {
    var isTerminal: Bool {
        switch self {
        case .inProgress, .unknown:
            false
        case .completed, .failed, .interrupted:
            true
        }
    }
}

@Observable
public final class CodexWorkspace: CodexPersistentModel {
    public let id: CodexWorkspaceID
    public private(set) var url: URL
    public private(set) var name: String
    public private(set) var chats: [CodexChat]

    public private(set) weak var workspaceGroup: CodexWorkspaceGroup?

    public var workspaceGroupID: CodexWorkspaceGroupID? {
        workspaceGroup?.id
    }

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    package init(
        id: CodexWorkspaceID,
        url: URL,
        name: String,
        workspaceGroup: CodexWorkspaceGroup?,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.url = url
        self.name = name
        self.workspaceGroup = workspaceGroup
        self.chats = []
        self.modelContext = modelContext
    }

    package func applyContextSnapshot(
        url: URL,
        name: String,
        workspaceGroup: CodexWorkspaceGroup?
    ) {
        self.url = url
        self.name = name
        self.workspaceGroup = workspaceGroup
    }

    package func replaceContextChats(_ chats: [CodexChat]) {
        self.chats = chats
    }

    package func attachContextChatIfNeeded(_ chat: CodexChat) {
        guard chats.contains(where: { $0 === chat }) == false else {
            return
        }
        chats.append(chat)
    }

    package func moveContextChatToFront(_ chat: CodexChat) {
        chats.removeAll { $0 === chat }
        chats.insert(chat, at: 0)
    }

    @discardableResult
    public nonisolated(nonsending) func startChat(
        _ input: CodexChatInput = .init()
    ) async throws -> CodexChat {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.startChat(in: self, input: input)
    }

    @discardableResult
    public nonisolated(nonsending) func startReview(
        _ input: CodexReviewInput
    ) async throws -> CodexStartedReview {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.startReview(in: self, input: input)
    }
}

@Observable
public final class CodexTurn: CodexPersistentModel {
    public let id: CodexTurnID
    public var state: CodexTurnSnapshot.State?
    public var status: CodexTurnStatus? {
        switch state {
        case .inProgress: .inProgress
        case .completed: .completed
        case .interrupted: .interrupted
        case .failed: .failed
        case .unknown(let rawValue, _): .unknown(rawValue: rawValue)
        case nil: nil
        }
    }
    public var error: CodexTurnError? {
        switch state {
        case .failed(let error), .unknown(_, let error?): error
        case .inProgress, .completed, .interrupted, .unknown(_, nil), nil: nil
        }
    }
    public var itemsLoadState: CodexTurnItemsLoadState
    public var usage: CodexTokenUsage?
    public private(set) var items: [CodexItem]

    public private(set) weak var chat: CodexChat?

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    package init(
        id: CodexTurnID,
        chat: CodexChat,
        modelContext: CodexModelContext,
        state: CodexTurnSnapshot.State? = nil,
        itemsLoadState: CodexTurnItemsLoadState? = nil,
        usage: CodexTokenUsage? = nil
    ) {
        self.id = id
        self.chat = chat
        self.modelContext = modelContext
        self.state = state
        self.itemsLoadState = itemsLoadState ?? .notLoaded
        self.usage = usage
        self.items = []
    }

    package func applyContextChat(_ chat: CodexChat) {
        self.chat = chat
    }

    package func replaceContextItems(_ items: [CodexItem]) {
        self.items = items
    }

    package func attachContextItemIfNeeded(_ item: CodexItem) {
        guard items.contains(where: { $0 === item }) == false else {
            return
        }
        items.append(item)
    }

    package func detachContextItem(_ item: CodexItem) {
        items.removeAll { $0 === item }
    }

    package func detachFromContext() {
        chat = nil
        modelContext = nil
        items = []
    }
}

@Observable
public final class CodexItem: CodexPersistentModel {
    public let id: CodexChatItemID
    public private(set) var itemID: String
    public fileprivate(set) var itemsLoadState: CodexTurnItemsLoadState
    public var kind: CodexThreadItem.Kind
    public var content: CodexThreadItem.Content
    public private(set) var origin: CodexThreadItem.Origin
    public private(set) var semanticRelation: CodexThreadItem.SemanticRelation?
    public var rawPayload: Data?

    public private(set) weak var chat: CodexChat?
    public private(set) weak var turn: CodexTurn?

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    public var turnID: CodexTurnID? {
        turn?.id
    }

    public var text: String? {
        threadItem.text
    }

    public var message: CodexMessage? {
        threadItem.message
    }

    public var reasoning: CodexReasoning? {
        if case .reasoning(let reasoning) = content {
            return reasoning
        }
        return nil
    }

    fileprivate var threadItem: CodexThreadItem {
        CodexThreadItem(
            id: itemID,
            kind: kind,
            content: content,
            origin: origin,
            semanticRelation: semanticRelation,
            rawPayload: rawPayload
        )
    }

    fileprivate var mergeKey: CodexChatItemKey {
        .init(id: itemID, kind: kind, turnID: turnID)
    }

    fileprivate var isExitedReviewModeMarker: Bool {
        threadItem.isExitedReviewModeMarker
    }

    package init(
        threadItem: CodexThreadItem,
        chat: CodexChat,
        turn: CodexTurn?,
        modelContext: CodexModelContext,
        itemsLoadState: CodexTurnItemsLoadState
    ) {
        self.id = CodexChatItemKey(threadItem: threadItem, turnID: turn?.id).modelID(in: chat.id)
        self.itemID = threadItem.id
        self.chat = chat
        self.turn = turn
        self.modelContext = modelContext
        self.itemsLoadState = itemsLoadState
        self.kind = threadItem.kind
        self.content = threadItem.content
        self.origin = threadItem.origin
        self.semanticRelation = threadItem.semanticRelation
        self.rawPayload = threadItem.rawPayload
    }

    package func applyContextOwners(chat: CodexChat, turn: CodexTurn?) {
        self.chat = chat
        self.turn = turn
    }

    package func detachFromContext() {
        chat = nil
        turn = nil
        modelContext = nil
    }

    fileprivate func update(
        from threadItem: CodexThreadItem,
        itemsLoadState: CodexTurnItemsLoadState
    ) {
        itemID = threadItem.id
        self.itemsLoadState = itemsLoadState
        kind = threadItem.kind
        content = threadItem.content
        origin = threadItem.origin
        semanticRelation = threadItem.semanticRelation
        rawPayload = threadItem.rawPayload
    }
}

package struct CodexChatItemKey: Hashable {
    var id: String
    var kind: CodexThreadItem.Kind?
    var semanticID: String
    var turnID: CodexTurnID?

    init(id: String, kind: CodexThreadItem.Kind? = nil, turnID: CodexTurnID?) {
        self.id = id
        self.kind = kind
        self.semanticID = Self.semanticID(rawItemID: id, kind: kind)
        self.turnID = turnID
    }

    init(threadItem: CodexThreadItem, turnID: CodexTurnID?) {
        self.init(id: threadItem.id, kind: threadItem.kind, turnID: turnID)
    }

    var modelID: CodexChatItemID {
        CodexChatItemID(rawItemID: semanticID, turnID: turnID)
    }

    func modelID(in chatID: CodexThreadID) -> CodexChatItemID {
        CodexChatItemID(rawItemID: semanticID, turnID: turnID, chatID: chatID)
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind
            && lhs.semanticID == rhs.semanticID
            && lhs.turnID == rhs.turnID
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(semanticID)
        hasher.combine(turnID)
    }

    private static func semanticID(
        rawItemID: String,
        kind: CodexThreadItem.Kind?
    ) -> String {
        switch kind {
        case .some(let kind):
            "\(kind.rawValue):\(rawItemID)"
        default:
            rawItemID
        }
    }
}

package enum CodexThreadListSourcePossibility: Hashable, Sendable {
    case kind(CodexThreadSourceKind)
    case supportedCustomInteractive

    package var projectedSourceKind: CodexThreadSourceKind? {
        switch self {
        case .kind(let sourceKind):
            sourceKind
        case .supportedCustomInteractive:
            nil
        }
    }
}

package struct CodexThreadListSourceProvenance: Hashable, Sendable {
    package let possibilities: Set<CodexThreadListSourcePossibility>

    package init(sourceKinds: [CodexThreadSourceKind]?) {
        let possibilities: Set<CodexThreadListSourcePossibility>
        if let sourceKinds, sourceKinds.isEmpty == false {
            possibilities = Set(sourceKinds.flatMap { sourceKind -> [CodexThreadListSourcePossibility] in
                if sourceKind == .subAgent {
                    return [
                        .kind(.subAgent),
                        .kind(.subAgentReview),
                        .kind(.subAgentCompact),
                        .kind(.subAgentThreadSpawn),
                        .kind(.subAgentOther),
                    ]
                }
                return [.kind(sourceKind)]
            })
        } else {
            possibilities = [
                .kind(.cli),
                .kind(.vscode),
                .supportedCustomInteractive,
            ]
        }
        precondition(
            possibilities.isEmpty == false,
            "A thread-list source provenance must contain at least one possibility."
        )
        self.possibilities = possibilities
    }

    package func intersecting(_ other: Self) -> Self {
        let intersection = possibilities.intersection(other.possibilities)
        precondition(
            intersection.isEmpty == false,
            "A thread cannot belong to disjoint thread-list source partitions."
        )
        return Self(possibilities: intersection)
    }

    private init(possibilities: Set<CodexThreadListSourcePossibility>) {
        precondition(
            possibilities.isEmpty == false,
            "A thread-list source provenance must contain at least one possibility."
        )
        self.possibilities = possibilities
    }
}

package enum CodexThreadSourceResolution: Hashable, Sendable {
    case unresolved
    case partitionProven(CodexThreadListSourceProvenance)
    case exact(CodexThreadSessionSource)
    case kindOnly(CodexThreadSourceKind)
    case knownNull

    package var source: CodexThreadSessionSource? {
        guard case .exact(let source) = self else {
            return nil
        }
        return source
    }

    package var sourceKind: CodexThreadSourceKind? {
        switch self {
        case .exact(let source):
            source.sourceKind
        case .kindOnly(let sourceKind):
            sourceKind
        case .unresolved, .partitionProven, .knownNull:
            nil
        }
    }

    package var partitionProvenance: CodexThreadListSourceProvenance? {
        guard case .partitionProven(let provenance) = self else {
            return nil
        }
        return provenance
    }

    package mutating func apply(
        _ snapshot: CodexThreadSnapshot,
        partitionProvenance: CodexThreadListSourceProvenance?
    ) {
        if snapshot.hasField(.source) {
            self = snapshot.source.map(Self.exact) ?? .knownNull
            return
        }
        if snapshot.hasField(.sourceKind) {
            let sourceKind = snapshot.sourceKind
            if case .exact(let source) = self, source.sourceKind == sourceKind {
                return
            }
            self = sourceKind.map(Self.kindOnly) ?? .knownNull
            return
        }
        guard let partitionProvenance else {
            return
        }
        switch self {
        case .unresolved:
            self = .partitionProven(partitionProvenance)
        case .partitionProven(let existing):
            self = .partitionProven(existing.intersecting(partitionProvenance))
        case .exact, .kindOnly, .knownNull:
            break
        }
    }
}

@Observable
public final class CodexChat: CodexPersistentModel {
    public let id: CodexThreadID
    public private(set) var name: String?
    public private(set) var preview: String?
    public private(set) var modelProvider: String?
    /// The app-server session identifier, when present in the latest snapshot.
    public private(set) var sessionID: String?
    /// The direct parent thread identifier reported by the app-server.
    public private(set) var parentThreadID: CodexThreadID?
    private var sourceResolution: CodexThreadSourceResolution
    /// The exact thread session origin reported by the app-server.
    public var source: CodexThreadSessionSource? {
        sourceResolution.source
    }
    /// A coarse source projection retained for source-kind filtering compatibility.
    ///
    /// Exact custom sources project to `nil`. Fetch predicates must narrow this
    /// property to a finite set of non-`nil` kinds; an unbounded `nil` or non-`nil`
    /// comparison cannot be represented by the app-server and fails validation.
    public var sourceKind: CodexThreadSourceKind? {
        sourceResolution.sourceKind
    }
    package var threadListSourceProvenance: CodexThreadListSourceProvenance? {
        sourceResolution.partitionProvenance
    }
    package var threadSourceResolution: CodexThreadSourceResolution {
        sourceResolution
    }
    /// Git repository metadata captured for this thread by the app-server.
    public private(set) var gitInfo: CodexThreadGitInfo?
    public private(set) var isArchived: Bool
    public private(set) var createdAt: Date?
    public private(set) var updatedAt: Date?
    public private(set) var recencyAt: Date?
    public private(set) var status: CodexThreadStatus?
    public private(set) var ephemeral: Bool?
    public private(set) var turns: [CodexTurn]
    public private(set) var items: [CodexItem]
    public private(set) var phase: CodexChatPhase = .idle

    public private(set) weak var workspace: CodexWorkspace?

    public var workspaceID: CodexWorkspaceID? {
        workspace?.id
    }

    public var workspaceGroupID: CodexWorkspaceGroupID? {
        workspace?.workspaceGroupID
    }

    @ObservationIgnored
    private var liveMergeState = LiveMergeState()
    @ObservationIgnored
    private var hasAppliedLiveTurnItemUpdates = false
    @ObservationIgnored
    private var preservesSeededMetadataUntilAuthoritativeSnapshot = false
    @ObservationIgnored
    private var turnsByID: [CodexTurnID: CodexTurn] = [:]
    @ObservationIgnored
    private var itemsByMergeKey: [CodexChatItemKey: CodexItem] = [:]
    @ObservationIgnored
    private var itemsByTurnID: [CodexTurnID: [CodexItem]] = [:]
    @ObservationIgnored
    private var provisionalSeedTurnID: CodexTurnID?
    // Unlike provisionalSeedTurnID (single-shot, consumed by the first live
    // event), this survives for the whole review turn so authoritative
    // records with fully synthesized identities can still be adopted into it.
    @ObservationIgnored
    private var seededReviewTurnID: CodexTurnID?

    @ObservationIgnored
    public private(set) weak var modelContext: CodexModelContext?

    public var title: String {
        if let name, name.isEmpty == false {
            return name
        }
        if let preview, preview.isEmpty == false {
            return preview
        }
        if let workspace {
            return workspace.name
        }
        return id.rawValue
    }

    public var transcript: CodexTranscript {
        .init(items: items.map(\.threadItem))
    }

    public var searchableText: String {
        [
            name,
            preview,
            workspace?.name,
            title,
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    public func turn(id: CodexTurnID) -> CodexTurn? {
        // Keep Observation dependency tracking on the ordered current value while
        // serving the lookup from the ignored index.
        _ = turns
        return turnsByID[id]
    }

    public func items(in turnID: CodexTurnID) -> [CodexItem] {
        // Keep Observation dependency tracking on the ordered current value while
        // serving the scoped lookup from the ignored index.
        _ = items
        return itemsByTurnID[turnID] ?? []
    }

    /// Returns the context-owned transcript projection for one loaded turn.
    public func transcript(in turnID: CodexTurnID) -> CodexTranscript {
        .init(items: items(in: turnID).map(\.threadItem))
    }

    package init(
        id: CodexThreadID,
        modelContext: CodexModelContext
    ) {
        self.id = id
        self.turns = []
        self.items = []
        self.sourceResolution = .unresolved
        self.isArchived = false
        self.modelContext = modelContext
    }

    package func apply(
        _ snapshot: CodexThreadSnapshot,
        workspace: CodexWorkspace?,
        sourceProvenance: CodexThreadListSourceProvenance? = nil,
        preservesExistingTurnItems: Bool = false
    ) {
        if snapshot.hasField(.workspace) {
            self.workspace = workspace
        }
        let receivedAuthoritativeTitleMetadata =
            (snapshot.hasField(.name) && snapshot.name?.isEmpty == false)
            || (snapshot.hasField(.preview) && snapshot.preview?.isEmpty == false)
        if snapshot.hasField(.name), shouldApplyOptionalMetadata(snapshot.name, existing: name) {
            name = snapshot.name
        }
        if snapshot.hasField(.preview), shouldApplyOptionalMetadata(snapshot.preview, existing: preview) {
            preview = snapshot.preview
        }
        if snapshot.hasField(.modelProvider),
            shouldApplyOptionalMetadata(snapshot.modelProvider, existing: modelProvider)
        {
            modelProvider = snapshot.modelProvider
        }
        if snapshot.hasField(.sessionID) {
            sessionID = snapshot.sessionID
        }
        if snapshot.hasField(.parentThreadID) {
            parentThreadID = snapshot.parentThreadID
        }
        sourceResolution.apply(snapshot, partitionProvenance: sourceProvenance)
        if snapshot.hasField(.gitInfo) {
            gitInfo = snapshot.gitInfo
        }
        if receivedAuthoritativeTitleMetadata {
            preservesSeededMetadataUntilAuthoritativeSnapshot = false
        }
        if snapshot.hasField(.createdAt) {
            createdAt = snapshot.createdAt
        }
        if snapshot.hasField(.updatedAt) {
            updatedAt = snapshot.updatedAt
        }
        if snapshot.hasField(.recencyAt) {
            recencyAt = snapshot.recencyAt
        }
        if snapshot.hasField(.status) {
            status = snapshot.status
        }
        if snapshot.hasField(.ephemeral) {
            ephemeral = snapshot.ephemeral
        }
        if let turns = snapshot.turns {
            let preservesSeededReviewTurnItems = shouldPreserveSeededReviewTurnItemsWhenReconcilingSnapshot
            let replacesTurnItems = snapshot.turnItemsAreAuthoritative
                && preservesExistingTurnItems == false
                && preservesSeededReviewTurnItems == false
            let turns = normalizedIncomingTurnRecords(
                turns,
                usesLoadedReviewHistory: replacesTurnItems == false
            )
            if replacesTurnItems {
                replaceTurns(with: turns)
                replaceItems(with: turns)
                hasAppliedLiveTurnItemUpdates = false
            } else {
                mergeTurns(with: turns)
                mergeItems(
                    from: turns,
                    preservesSeededReviewTurnItems: preservesSeededReviewTurnItems
                )
            }
            for turn in turns {
                if turn.status.isTerminal {
                    _ = terminalizeActiveItems(
                        in: turn.id,
                        status: turn.status
                    )
                }
            }
        }
    }

    package func applyContextArchived(_ isArchived: Bool) {
        self.isArchived = isArchived
    }

    package func preserveSeededMetadataUntilAuthoritativeSnapshot() {
        preservesSeededMetadataUntilAuthoritativeSnapshot = true
    }

    package func markProvisionalSeedTurn(_ turnID: CodexTurnID?) {
        provisionalSeedTurnID = turnID
        if let turnID {
            seededReviewTurnID = turnID
        }
    }

    package func detachFromContext() {
        for item in items {
            item.detachFromContext()
        }
        for turn in turns {
            for item in turn.items {
                item.detachFromContext()
            }
            turn.detachFromContext()
        }
        turns = []
        items = []
        turnsByID = [:]
        itemsByMergeKey = [:]
        itemsByTurnID = [:]
        liveMergeState = LiveMergeState()
        provisionalSeedTurnID = nil
        seededReviewTurnID = nil
        workspace = nil
        modelContext = nil
    }

    package func detachFromWorkspace(_ workspace: CodexWorkspace) {
        if self.workspace === workspace {
            self.workspace = nil
        }
    }

    public func observe(
        includeTurns: Bool = true,
        isolation: isolated any Actor = #isolation
    ) async throws -> CodexChatObservation {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        return try await modelContext.observe(
            self,
            includeTurns: includeTurns,
            isolation: isolation
        )
    }

    private func shouldApplyOptionalMetadata<Value>(_ incoming: Value?, existing: Value?) -> Bool {
        incoming != nil || preservesSeededMetadataUntilAuthoritativeSnapshot == false || existing == nil
    }

    @discardableResult
    public nonisolated(nonsending) func send(
        _ input: CodexChatMessageInput
    ) async throws -> CodexTurnOutcome {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        let stablePhase = phase
        phase = .loading
        do {
            let response = try await modelContext.send(input, in: self)
            await modelContext.syncPhaseAfterSend(in: self)
            return response
        } catch is CancellationError {
            restorePhaseIfLoading(stablePhase)
            throw CancellationError()
        } catch {
            fail(with: error)
            throw error
        }
    }

    @discardableResult
    public nonisolated(nonsending) func send(
        _ text: String,
        options: CodexGenerationOptions = .init()
    ) async throws -> CodexTurnOutcome {
        try await send(.init(text, options: options))
    }

    public nonisolated(nonsending) func cancel() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.cancelActiveTurn(in: self)
    }

    public nonisolated(nonsending) func archive() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.archive(self)
    }

    public nonisolated(nonsending) func unarchive() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.unarchive(self)
    }

    public nonisolated(nonsending) func delete() async throws {
        guard let modelContext else {
            throw CodexModelContextError.modelIsDetached
        }
        try await modelContext.delete(self)
    }

    private func contextTurn(
        id: CodexTurnID,
        state: CodexTurnSnapshot.State? = nil,
        itemsLoadState: CodexTurnItemsLoadState? = nil,
        usage: CodexTokenUsage? = nil
    ) -> CodexTurn {
        guard let modelContext else {
            preconditionFailure("CodexChat is detached from its CodexModelContext.")
        }
        return modelContext.turn(
            id: id,
            in: self,
            state: state,
            itemsLoadState: itemsLoadState,
            usage: usage
        )
    }

    private func contextItem(
        threadItem: CodexThreadItem,
        turnID: CodexTurnID?,
        itemsLoadState: CodexTurnItemsLoadState
    ) -> CodexItem {
        guard let modelContext else {
            preconditionFailure("CodexChat is detached from its CodexModelContext.")
        }
        return modelContext.item(
            threadItem: threadItem,
            turnID: turnID,
            in: self,
            itemsLoadState: itemsLoadState
        )
    }

    private func replaceTurns(with records: [CodexTurnSnapshot]) {
        provisionalSeedTurnID = nil
        let existingByID = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0) })
        turns = records.map { record in
            let turn = existingByID[record.id] ?? contextTurn(id: record.id)
            turn.state = record.state
            turn.itemsLoadState = record.itemsLoadState
            return turn
        }
        rebuildTurnIndex()
    }

    private func normalizedIncomingTurnRecords(
        _ records: [CodexTurnSnapshot],
        usesLoadedReviewHistory: Bool
    ) -> [CodexTurnSnapshot] {
        let normalized = recordsByRemovingReplacedProvisionalSeed(records).map { record in
            var record = record
            if let liveTurnID = liveTurnID(adopting: record) {
                record.id = liveTurnID
            }
            return record
        }
        var recordsByID: [CodexTurnID: Int] = [:]
        var coalesced: [CodexTurnSnapshot] = []
        coalesced.reserveCapacity(normalized.count)
        for record in normalized {
            guard let index = recordsByID[record.id] else {
                recordsByID[record.id] = coalesced.count
                coalesced.append(record)
                continue
            }
            coalesced[index] = coalescing(coalesced[index], with: record)
        }
        return normalizingReviewRolloutCompanions(
            coalesced.map(normalizingLifecycleFromItemOrder),
            usesLoadedReviewHistory: usesLoadedReviewHistory
        )
    }

    private func normalizingReviewRolloutCompanions(
        _ records: [CodexTurnSnapshot],
        usesLoadedReviewHistory: Bool
    ) -> [CodexTurnSnapshot] {
        var normalized = records
        let supersededTurnIDs = Set(
            records.lazy.filter(\.itemsAreAuthoritative).map(\.id)
        )
        for candidateIndex in normalized.indices {
            normalized[candidateIndex] = normalizingReviewRolloutCompanion(
                normalized[candidateIndex],
                hasPrecedingReviewExit: hasPrecedingReviewExit(
                    before: candidateIndex,
                    in: normalized,
                    usesLoadedReviewHistory: usesLoadedReviewHistory,
                    supersededTurnIDs: supersededTurnIDs
                )
            )
        }
        return normalized
    }

    private func normalizingReviewRolloutCompanion(
        _ record: CodexTurnSnapshot,
        hasPrecedingReviewExit: Bool
    ) -> CodexTurnSnapshot {
        var normalized = record
        if let agentIndex = sameTurnReviewCompanionAgentIndex(in: normalized) {
            normalized.items[agentIndex] = reviewRolloutCompanion(
                normalized.items[agentIndex]
            )
        } else if let agentIndex = persistedReviewCompanionAgentIndex(in: normalized),
            hasPrecedingReviewExit
        {
            normalized.items[agentIndex] = reviewRolloutCompanion(
                normalized.items[agentIndex]
            )
        }
        return normalized
    }

    private func sameTurnReviewCompanionAgentIndex(
        in record: CodexTurnSnapshot
    ) -> Int? {
        guard record.itemsLoadState == .full else {
            return nil
        }
        for index in record.items.indices
        where record.items[index].kind == .agentMessage
            && record.items[index].semanticRelation == nil
        {
            let precedingNarrativeItems = record.items[..<index].filter {
                $0.isReviewNarrativeBoundary
            }
            guard let reviewMarkerIndex = precedingNarrativeItems.lastIndex(where: {
                $0.isReviewModeMarker
            }), precedingNarrativeItems[reviewMarkerIndex].isExitedReviewModeMarker else {
                continue
            }
            let afterReviewMarker = precedingNarrativeItems.index(after: reviewMarkerIndex)
            let trailingNarrativeItems = precedingNarrativeItems[afterReviewMarker...]
            if trailingNarrativeItems.isEmpty {
                return index
            }
            guard trailingNarrativeItems.count == 2,
                trailingNarrativeItems.allSatisfy({ $0.kind == .userMessage }),
                trailingNarrativeItems.allSatisfy({ normalizedMessageText($0) != nil }),
                Set(trailingNarrativeItems.compactMap(normalizedMessageText)).count == 1
            else {
                continue
            }
            return index
        }
        return nil
    }

    private func persistedReviewCompanionAgentIndex(
        in record: CodexTurnSnapshot
    ) -> Int? {
        guard record.status.isTerminal,
            record.itemsLoadState == .full
        else {
            return nil
        }
        let userMessages = record.items.filter { $0.kind == .userMessage }
        let agentIndices = record.items.indices.filter {
            record.items[$0].kind == .agentMessage
        }
        guard userMessages.count == 2,
            agentIndices.count == 1,
            userMessages.allSatisfy({ normalizedMessageText($0) != nil }),
            Set(userMessages.compactMap(normalizedMessageText)).count == 1,
            normalizedMessageText(record.items[agentIndices[0]]) != nil,
            record.items.contains(where: \.isReviewModeMarker) == false
        else {
            return nil
        }
        return agentIndices[0]
    }

    private func hasPrecedingReviewExit(
        before candidateIndex: Int,
        in records: [CodexTurnSnapshot],
        usesLoadedReviewHistory: Bool,
        supersededTurnIDs: Set<CodexTurnID>
    ) -> Bool {
        if candidateIndex > records.startIndex {
            for record in records[..<candidateIndex].reversed() {
                let boundary: CodexThreadItem?
                if record.itemsLoadState == .full {
                    boundary = record.items.last(where: \.isReviewNarrativeBoundary)
                } else if usesLoadedReviewHistory,
                          turnsByID[record.id]?.itemsLoadState == .full
                {
                    boundary = (itemsByTurnID[record.id] ?? [])
                        .map(\.threadItem)
                        .last(where: \.isReviewNarrativeBoundary)
                } else {
                    return false
                }
                if let boundary {
                    return boundary.isExitedReviewModeMarker
                }
            }
        }
        guard usesLoadedReviewHistory else {
            return false
        }
        return hasPrecedingReviewExit(
            before: records[candidateIndex].id,
            excluding: supersededTurnIDs
        )
    }

    private func normalizedMessageText(_ item: CodexThreadItem) -> String? {
        guard let text = item.message?.text.trimmingCharacters(in: .whitespacesAndNewlines),
            text.isEmpty == false
        else {
            return nil
        }
        return text
    }

    private func reviewRolloutCompanion(_ item: CodexThreadItem) -> CodexThreadItem {
        CodexThreadItem(
            id: item.id,
            kind: item.kind,
            content: item.content,
            origin: .reviewRolloutAssistant,
            semanticRelation: .companionOf(.exitedReviewMode),
            rawPayload: item.rawPayload
        )
    }

    private func normalizingLifecycleFromItemOrder(
        _ record: CodexTurnSnapshot
    ) -> CodexTurnSnapshot {
        var record = record
        var normalizedItems: [CodexThreadItem] = []
        normalizedItems.reserveCapacity(record.items.count)
        let inferredStatus = record.status.isTerminal ? record.status : .completed
        var activeLifecycleItemIndex: Int?
        for incomingItem in record.items {
            if let activeLifecycleItemIndex {
                normalizedItems[activeLifecycleItemIndex] = itemByApplyingTerminalLifecycleStatus(
                    inferredStatus,
                    to: normalizedItems[activeLifecycleItemIndex]
                )
            }
            normalizedItems.append(incomingItem)
            activeLifecycleItemIndex = hasActiveLifecycleStatus(incomingItem)
                ? normalizedItems.index(before: normalizedItems.endIndex)
                : nil
        }
        record.items = normalizedItems
        return record
    }

    private func coalescing(
        _ existing: CodexTurnSnapshot,
        with incoming: CodexTurnSnapshot
    ) -> CodexTurnSnapshot {
        precondition(existing.id == incoming.id)
        return CodexTurnSnapshot(
            id: existing.id,
            state: incoming.state,
            itemsLoadState: mostCompleteItemsLoadState(
                existing.itemsLoadState,
                incoming.itemsLoadState
            ),
            items: coalescingItems(existing.items, with: incoming.items, turnID: existing.id),
            startedAt: earliest(existing.startedAt, incoming.startedAt),
            completedAt: latest(existing.completedAt, incoming.completedAt),
            duration: incoming.duration ?? existing.duration
        )
    }

    private func coalescingItems(
        _ existing: [CodexThreadItem],
        with incoming: [CodexThreadItem],
        turnID: CodexTurnID
    ) -> [CodexThreadItem] {
        var items: [CodexThreadItem] = []
        var itemIndexByKey: [CodexChatItemKey: Int] = [:]
        for item in existing + incoming {
            let key = CodexChatItemKey(threadItem: item, turnID: turnID)
            if let index = itemIndexByKey[key] {
                items[index] = item
            } else {
                itemIndexByKey[key] = items.count
                items.append(item)
            }
        }
        return items
    }

    private func mostCompleteItemsLoadState(
        _ lhs: CodexTurnItemsLoadState,
        _ rhs: CodexTurnItemsLoadState
    ) -> CodexTurnItemsLoadState {
        switch (lhs, rhs) {
        case (.full, _), (_, .full):
            .full
        case (.summary, _), (_, .summary):
            .summary
        case (.notLoaded, .notLoaded):
            .notLoaded
        }
    }

    private func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            min(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)):
            value
        case (.none, .none):
            nil
        }
    }

    private func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let lhs), .some(let rhs)):
            max(lhs, rhs)
        case (.some(let value), .none), (.none, .some(let value)):
            value
        case (.none, .none):
            nil
        }
    }

    // Review turns have no persisted turn boundary in the app-server rollout,
    // so an authoritative snapshot can return a turn this chat already tracks
    // under its live turn id using a synthesized id. Fold such records into
    // the live turn by shared item identity so one logical turn never splits
    // into two turn ids; live events keep routing to the live id.
    private func liveTurnID(adopting record: CodexTurnSnapshot) -> CodexTurnID? {
        guard turnsByID[record.id] == nil else {
            return nil
        }
        // A terminal reviewer record is an authoritative turn boundary. Its
        // index-based narrative ids can collide with the still-open seed, so
        // only a record carrying a review marker may anchor back to that seed.
        let rejectsSeedMatch = record.status.isTerminal
            && record.items.contains(where: \.isReviewModeMarker) == false
            && seededReviewTurnID.flatMap { turnsByID[$0]?.status?.isTerminal } == false
        for incomingItem in record.items {
            guard let match = items.first(where: { item in
                item.turnID != nil
                    && item.turnID != record.id
                    && item.kind == incomingItem.kind
                    && item.itemID == incomingItem.id
            }) else {
                continue
            }
            if rejectsSeedMatch, match.turnID == seededReviewTurnID {
                continue
            }
            return match.turnID
        }
        return liveSeededReviewTurnID(adopting: record)
    }

    // The rollout materializes a running review turn with fully synthesized
    // identities: the turn id is regenerated per read and narrative items get
    // index-based ids, so the record can share nothing with the seeded/live
    // turn. While the seeded review turn is non-terminal, adopt never-seen
    // records into it. Records carrying an exitedReviewMode item are prior
    // reviews' turns and stay separate; their re-reads are stabilized by the
    // shared-item fold above.
    private func liveSeededReviewTurnID(adopting record: CodexTurnSnapshot) -> CodexTurnID? {
        guard let reviewTurnID = seededReviewTurnID,
            reviewTurnID != record.id,
            let reviewTurn = turnsByID[reviewTurnID],
            reviewTurn.status?.isTerminal != true,
            record.status.isTerminal == false,
            record.items.contains(where: { $0.kind == .exitedReviewMode }) == false
        else {
            return nil
        }
        return reviewTurnID
    }

    private func recordsByRemovingReplacedProvisionalSeed(
        _ records: [CodexTurnSnapshot]
    ) -> [CodexTurnSnapshot] {
        guard let provisionalTurnID = provisionalSeedTurnID else {
            return records
        }
        guard records.contains(where: { record in
            record.id != provisionalTurnID && record.items.contains(where: \.isReviewModeMarker)
        }) else {
            return records
        }
        _ = removeProvisionalSeedTurn(provisionalTurnID)
        return records.filter { $0.id != provisionalTurnID }
    }

    private func mergeTurns(with records: [CodexTurnSnapshot]) {
        for record in records {
            upsertTurn(
                id: record.id,
                state: record.state,
                itemsLoadState: record.itemsLoadState,
                preservesExistingUsage: true
            )
        }
    }

    private func replaceItems(with records: [CodexTurnSnapshot]) {
        let existingByKey = itemsByMergeKey
        let previousItems = items
        var reusedItems = Set<ObjectIdentifier>()
        items = records.flatMap { record in
            record.items.map { incomingItem in
                let incomingKey = CodexChatItemKey(
                    threadItem: incomingItem,
                    turnID: record.id
                )
                let turn = contextTurn(id: record.id)
                if let existing = existingByKey[incomingKey] {
                    let identifier = ObjectIdentifier(existing)
                    guard reusedItems.insert(identifier).inserted else {
                        return contextItem(
                            threadItem: incomingItem,
                            turnID: record.id,
                            itemsLoadState: record.itemsLoadState
                        )
                    }
                    let previousMergeKey = existing.mergeKey
                    existing.applyContextOwners(chat: self, turn: turn)
                    existing.update(
                        from: incomingItem,
                        itemsLoadState: record.itemsLoadState
                    )
                    migrateItemIdentity(existing, from: previousMergeKey)
                    return existing
                }
                return contextItem(
                    threadItem: incomingItem,
                    turnID: record.id,
                    itemsLoadState: record.itemsLoadState
                )
            }
        }
        let retainedItems = Set(items.map(ObjectIdentifier.init))
        let removedItems = previousItems.filter {
            retainedItems.contains(ObjectIdentifier($0)) == false
        }
        unregisterItemsFromContext(removedItems)
        rebuildItemIndexes()
    }

    private func mergeItems(
        from records: [CodexTurnSnapshot],
        preservesSeededReviewTurnItems: Bool = false
    ) {
        for record in records {
            if record.itemsAreAuthoritative {
                removeItemsOmittedFromAuthoritativeSnapshot(
                    record.items,
                    turnID: record.id,
                    preservesOmittedSeededReviewLogItems: shouldPreserveOmittedSeededReviewLogItems(
                        in: record,
                        enabled: preservesSeededReviewTurnItems
                    )
                )
            }
            guard record.items.isEmpty == false else {
                continue
            }
            mergeItems(
                record.items,
                turnID: record.id,
                reviewCompanionEvidence: .snapshotBatch,
                itemsLoadState: record.itemsLoadState
            )
        }
    }

    private func shouldPreserveOmittedSeededReviewLogItems(
        in record: CodexTurnSnapshot,
        enabled: Bool
    ) -> Bool {
        guard enabled,
            let seededReviewTurnID,
            record.id == seededReviewTurnID
        else {
            return false
        }
        return true
    }

    @discardableResult
    private func upsertTurn(
        id: CodexTurnID,
        state: CodexTurnSnapshot.State?,
        itemsLoadState: CodexTurnItemsLoadState? = nil,
        usage: CodexTokenUsage? = nil,
        preservesExistingUsage: Bool = false
    ) -> CodexChatMutation? {
        if let turn = turnsByID[id] {
            let previousState = turn.state
            let previousUsage = turn.usage
            let previousItemsLoadState = turn.itemsLoadState
            turn.state = state
            if let itemsLoadState {
                turn.itemsLoadState = itemsLoadState
            }
            if preservesExistingUsage == false || usage != nil {
                turn.usage = usage
            }
            guard turn.state != previousState
                || turn.usage != previousUsage
                || turn.itemsLoadState != previousItemsLoadState
            else {
                return nil
            }
            return .turnUpdated(id: turn.id)
        } else {
            let turn = contextTurn(
                id: id,
                state: state,
                itemsLoadState: itemsLoadState,
                usage: usage
            )
            turns.append(turn)
            turnsByID[turn.id] = turn
            return .turnInserted(id: turn.id)
        }
    }

    @discardableResult
    package func apply(_ outcome: CodexTurnOutcome) -> [CodexChatMutation] {
        let previousPhase = phase
        var changes: [CodexChatMutation] = []
        let response = outcome.response
        let state: CodexTurnSnapshot.State
        switch outcome {
        case .completed:
            state = .completed
        case .interrupted:
            state = .interrupted
        case .failed(let failedTurn):
            state = .failed(failedTurn.error)
        case .invalidTerminalStatus(let rawStatus, let error, _):
            state = .unknown(rawValue: rawStatus, error: error)
        }
        if let completedAt = response.completedAt,
            updatedAt.map({ completedAt > $0 }) ?? true
        {
            updatedAt = completedAt
        }
        let terminalItemsLoadState = mostCompleteItemsLoadState(
            turnsByID[response.turnID]?.itemsLoadState ?? .notLoaded,
            response.transcriptItemsLoadState
        )
        changes.appendIfPresent(upsertTurn(
            id: response.turnID,
            state: state,
            itemsLoadState: terminalItemsLoadState,
            usage: response.usage,
            preservesExistingUsage: true
        ))
        if response.transcriptItemsLoadState == .full {
            changes.append(contentsOf: removeItemsOmittedFromAuthoritativeSnapshot(
                response.transcript.items,
                turnID: response.turnID
            ))
        }
        changes.append(contentsOf: mergeItems(
            response.transcript.items,
            turnID: response.turnID,
            reviewCompanionEvidence: .orderedItems,
            itemsLoadState: response.transcriptItemsLoadState
        ))
        changes.append(contentsOf: normalizeReviewRolloutCompanion(
            in: response.turnID
        ))
        if let terminalStatus = turnsByID[response.turnID]?.status {
            changes.append(contentsOf: terminalizeActiveItems(
                in: response.turnID,
                status: terminalStatus
            ))
        }
        changes.appendIfPresent(markIdleIfActive())
        phase = .terminal(
            turnID: response.turnID,
            disposition: outcome.chatTerminalDisposition
        )
        appendPhaseChange(to: &changes, previousPhase: previousPhase)
        markAppliedLiveTurnItemUpdatesIfNeeded(changes)
        return changes
    }

    @discardableResult
    package func apply(_ event: CodexThreadEvent) -> [CodexChatMutation] {
        let previousPhase = phase
        var changes: [CodexChatMutation] = []
        switch event {
        case .turnStarted(let turnID):
            removeProvisionalSeedTurnIfNeeded(for: turnID, into: &changes)
            changes.appendIfPresent(upsertTurn(
                id: turnID,
                state: .inProgress,
                preservesExistingUsage: true
            ))
            changes.appendIfPresent(markRunningIfNeeded(turnID: turnID))
        case .snapshot(let incomingSnapshot):
            changes.appendIfPresent(upsertTurn(
                id: incomingSnapshot.id,
                state: incomingSnapshot.state,
                itemsLoadState: incomingSnapshot.itemsLoadState,
                preservesExistingUsage: true
            ))
            let snapshot = normalizingReviewRolloutCompanion(
                incomingSnapshot,
                hasPrecedingReviewExit: hasPrecedingReviewExit(
                    before: incomingSnapshot.id
                )
            )
            if snapshot.itemsAreAuthoritative {
                changes.append(contentsOf: removeItemsOmittedFromAuthoritativeSnapshot(
                    snapshot.items,
                    turnID: snapshot.id
                ))
            }
            changes.append(contentsOf: mergeItems(
                snapshot.items,
                turnID: snapshot.id,
                reviewCompanionEvidence: .snapshotBatch,
                itemsLoadState: snapshot.itemsLoadState
            ))
            switch snapshot.state {
            case .inProgress:
                changes.appendIfPresent(markRunningIfNeeded(turnID: snapshot.id))
            case .completed:
                changes.appendIfPresent(markIdleIfActive())
                phase = .terminal(turnID: snapshot.id, disposition: .completed)
            case .interrupted:
                changes.appendIfPresent(markIdleIfActive())
                phase = .terminal(turnID: snapshot.id, disposition: .interrupted)
            case .failed:
                changes.appendIfPresent(markIdleIfActive())
                phase = .terminal(turnID: snapshot.id, disposition: .failed)
            case .unknown(let rawValue, _):
                changes.appendIfPresent(markIdleIfActive())
                phase = .terminal(
                    turnID: snapshot.id,
                    disposition: .invalid(rawStatus: rawValue)
                )
            }
        case .terminal(let outcome):
            changes.append(contentsOf: apply(outcome))
            changes.appendIfPresent(markIdleIfActive())
        case .itemStarted(let item, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: mergeItems([
                itemByApplyingLifecycleStatus(.inProgress, to: item),
            ], turnID: turnID, reviewCompanionEvidence: .orderedItems))
            changes.appendIfPresent(markRunningIfNeeded(turnID: turnID))
        case .itemCompleted(let item, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: mergeItems([
                itemByApplyingLifecycleStatus(.completed, to: item),
            ], turnID: turnID, reviewCompanionEvidence: .orderedItems))
        case .itemUpdated(let item, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: mergeItems(
                [item],
                turnID: turnID,
                reviewCompanionEvidence: .orderedItems,
                accumulatesOutputDeltas: isOutputDeltaUpdate(item)
            ))
            changes.appendIfPresent(markRunningIfNeeded(turnID: turnID))
        case .message(let message, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            let item = CodexThreadItem(
                id: message.id,
                kind: message.role == .user ? .userMessage : .agentMessage,
                content: .message(message)
            )
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: mergeItems(
                [item],
                turnID: turnID,
                reviewCompanionEvidence: .orderedItems
            ))
            changes.appendIfPresent(markRunningIfNeeded(turnID: turnID))
        case .messageDelta(let delta, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                incomingKey: CodexChatItemKey(
                    id: delta.itemID,
                    kind: .agentMessage,
                    turnID: turnID
                ),
                turnID: turnID
            ))
            changes.append(contentsOf: merge(delta, turnID: turnID))
            changes.appendIfPresent(markRunningIfNeeded(turnID: turnID))
        case .reasoningSummaryPartAdded(let part, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            let item = CodexThreadItem(id: part.id, kind: .reasoning, content: .reasoning(.empty))
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                item,
                turnID: turnID
            ))
            changes.append(contentsOf: start(part, turnID: turnID))
            changes.appendIfPresent(markRunningIfNeeded(turnID: turnID))
        case .reasoningDelta(let delta, let turnID):
            insertRunningTurnIfMissing(turnID, into: &changes)
            changes.append(contentsOf: terminalizeActiveItemsBeforeAppending(
                incomingKey: reasoningMergeKey(for: delta, turnID: turnID),
                turnID: turnID
            ))
            changes.append(contentsOf: merge(delta, turnID: turnID))
            changes.appendIfPresent(markRunningIfNeeded(turnID: turnID))
        case .diagnostic:
            break
        case .tokenUsageUpdated(let usage, let turnID):
            if let turnID {
                changes.appendIfPresent(setUsage(usage, for: turnID))
            }
        case .statusChanged(let status):
            switch status {
            case .active, .unknown:
                changes.appendIfPresent(setStatus(status))
                changes.appendIfPresent(markRunningIfNeeded(turnID: nil))
            case .notLoaded, .idle, .systemError:
                changes.appendIfPresent(setStatus(status))
                markInactiveWithoutTerminalizingTurn()
            }
        case .closed:
            changes.appendIfPresent(setStatus(.notLoaded))
            markInactiveWithoutTerminalizingTurn()
        case .unknown:
            break
        }
        appendPhaseChange(to: &changes, previousPhase: previousPhase)
        markAppliedLiveTurnItemUpdatesIfNeeded(changes)
        return changes
    }

    package var shouldPreserveTurnItemsWhenReconcilingSnapshot: Bool {
        hasAppliedLiveTurnItemUpdates
    }

    private var shouldPreserveSeededReviewTurnItemsWhenReconcilingSnapshot: Bool {
        guard let seededReviewTurnID,
            hasAppliedLiveTurnItemUpdates,
            let seededReviewTurnItems = itemsByTurnID[seededReviewTurnID],
            seededReviewTurnItems.isEmpty == false
        else {
            return false
        }
        guard turnsByID[seededReviewTurnID]?.status?.isTerminal == true else {
            return true
        }
        return seededReviewTurnItems.contains(where: \.isExitedReviewModeMarker) == false
    }

    private func markAppliedLiveTurnItemUpdatesIfNeeded(_ changes: [CodexChatMutation]) {
        guard changes.containsTurnItemMutation else {
            return
        }
        hasAppliedLiveTurnItemUpdates = true
    }

    private enum ReviewCompanionEvidence {
        case snapshotBatch
        case orderedItems
    }

    @discardableResult
    private func mergeItems(
        _ incomingItems: [CodexThreadItem],
        turnID: CodexTurnID?,
        reviewCompanionEvidence: ReviewCompanionEvidence,
        itemsLoadState: CodexTurnItemsLoadState = .full,
        accumulatesOutputDeltas: Bool = false
    ) -> [CodexChatMutation] {
        guard incomingItems.isEmpty == false else {
            return []
        }
        var changes: [CodexChatMutation] = []
        for rawIncomingItem in incomingItems {
            let incomingItem = normalizingReviewRolloutCompanion(
                rawIncomingItem,
                turnID: turnID,
                evidence: reviewCompanionEvidence
            )
            if incomingItem.kind == .reasoning && incomingItem.id.contains(":summary:") == false
                && incomingItem.id.contains(":content:") == false
            {
                changes.append(contentsOf: removeReasoningParts(
                    parentItemID: incomingItem.id,
                    turnID: turnID
                ))
            }
            let incomingKey = CodexChatItemKey(
                threadItem: incomingItem,
                turnID: turnID
            )
            let indexedItem = itemsByMergeKey[incomingKey]
            let replayItem = indexedItem == nil
                ? commandReplayItem(matching: incomingItem, turnID: turnID)
                : nil
            let existingItem = indexedItem ?? replayItem
            if let existing = existingItem
            {
                let previousItem = existing.threadItem
                let previousMergeKey = existing.mergeKey
                let previousTurnID = existing.turnID
                let incomingItem = itemByPreservingExistingLifecycle(
                    from: incomingItem,
                    existing: previousItem
                )
                let movesAcrossTurns = previousTurnID != turnID
                if movesAcrossTurns {
                    let replacementItem: CodexThreadItem
                    if accumulatesOutputDeltas,
                        mergeOutputDelta(incomingItem, into: existing, key: previousMergeKey)
                    {
                        replacementItem = existing.threadItem
                    } else {
                        replacementItem = incomingItem
                    }
                    let replacement = replaceItemAcrossTurns(
                        existing,
                        with: replacementItem,
                        turnID: turnID,
                        itemsLoadState: itemsLoadState
                    )
                    changes.append(.itemRemoved(
                        locator: .init(
                            item: previousItem,
                            turnID: requiredObservationTurnID(previousTurnID)
                        ),
                        modelID: existing.id
                    ))
                    changes.append(.itemInserted(id: replacement.id, turnID: replacement.turnID))
                    continue
                }
                let updateChange: CodexChatMutation?
                if accumulatesOutputDeltas,
                    mergeOutputDelta(incomingItem, into: existing, key: previousMergeKey)
                {
                    updateChange = changeForUpdatedItem(
                        existing,
                        previousItem: previousItem
                    )
                } else {
                    if shouldPreserveExistingFullItem(existing, incomingLoadState: itemsLoadState) {
                        continue
                    }
                    existing.update(
                        from: incomingItem,
                        itemsLoadState: itemsLoadState
                    )
                    updateChange = changeForUpdatedItem(
                        existing,
                        previousItem: previousItem
                    )
                }
                if existing.mergeKey != previousMergeKey {
                    migrateItemIdentity(existing, from: previousMergeKey)
                    rebuildItemIndexes()
                    changes.appendIfPresent(updateChange)
                } else {
                    changes.appendIfPresent(updateChange)
                }
            } else {
                if accumulatesOutputDeltas {
                    seedOutputDeltaStateIfNeeded(incomingItem, key: incomingKey)
                }
                let item = contextItem(
                    threadItem: incomingItem,
                    turnID: turnID,
                    itemsLoadState: itemsLoadState
                )
                appendItem(item)
                changes.append(.itemInserted(id: item.id, turnID: item.turnID))
            }
        }
        return changes
    }

    private func normalizingReviewRolloutCompanion(
        _ item: CodexThreadItem,
        turnID: CodexTurnID?,
        evidence: ReviewCompanionEvidence
    ) -> CodexThreadItem {
        guard item.kind == .agentMessage,
            item.semanticRelation == nil,
            let turnID
        else {
            return item
        }
        guard case .orderedItems = evidence else {
            return item
        }
        let currentTurnItems = (itemsByTurnID[turnID] ?? []).map(\.threadItem)
        let existingIndex = currentTurnItems.firstIndex {
            $0.kind == item.kind && $0.id == item.id
        }
        let precedingItems = existingIndex.map {
            currentTurnItems[..<$0]
        } ?? currentTurnItems[...]
        let precedingNarrativeItem = precedingItems.last {
            $0.isReviewNarrativeBoundary
        }
        if precedingNarrativeItem?.isExitedReviewModeMarker == true {
            return reviewRolloutCompanion(item)
        }

        var candidateItems = currentTurnItems
        if let existingIndex = candidateItems.firstIndex(where: {
            $0.kind == item.kind && $0.id == item.id
        }) {
            candidateItems[existingIndex] = item
        } else {
            candidateItems.append(item)
        }
        let candidateRecord = CodexTurnSnapshot(
            id: turnID,
            state: turnsByID[turnID]?.state ?? .inProgress,
            itemsLoadState: turnsByID[turnID]?.itemsLoadState ?? .notLoaded,
            items: candidateItems
        )
        if let agentIndex = sameTurnReviewCompanionAgentIndex(in: candidateRecord),
            candidateItems[agentIndex].id == item.id,
            candidateItems[agentIndex].kind == item.kind
        {
            return reviewRolloutCompanion(item)
        }
        guard persistedReviewCompanionAgentIndex(in: candidateRecord) != nil,
            hasPrecedingReviewExit(before: turnID)
        else {
            return item
        }
        return reviewRolloutCompanion(item)
    }

    private func normalizeReviewRolloutCompanion(
        in turnID: CodexTurnID
    ) -> [CodexChatMutation] {
        guard let turn = turnsByID[turnID],
            let state = turn.state,
            let turnItems = itemsByTurnID[turnID]
        else {
            return []
        }
        let record = CodexTurnSnapshot(
            id: turnID,
            state: state,
            itemsLoadState: turn.itemsLoadState,
            items: turnItems.map(\.threadItem)
        )
        let agentIndex: Int
        if let sameTurnAgentIndex = sameTurnReviewCompanionAgentIndex(in: record) {
            agentIndex = sameTurnAgentIndex
        } else if let persistedAgentIndex = persistedReviewCompanionAgentIndex(in: record),
            hasPrecedingReviewExit(before: turnID)
        {
            agentIndex = persistedAgentIndex
        } else {
            return []
        }
        guard turnItems[agentIndex].semanticRelation == nil else {
            return []
        }
        return mergeItems(
            [reviewRolloutCompanion(turnItems[agentIndex].threadItem)],
            turnID: turnID,
            reviewCompanionEvidence: .snapshotBatch,
            itemsLoadState: turnItems[agentIndex].itemsLoadState
        )
    }

    private func hasPrecedingReviewExit(
        before turnID: CodexTurnID,
        excluding excludedTurnIDs: Set<CodexTurnID> = []
    ) -> Bool {
        let candidateIndex = turns.firstIndex(where: { $0.id == turnID })
            ?? turns.endIndex
        guard candidateIndex > turns.startIndex else {
            return false
        }
        for turn in turns[..<candidateIndex].reversed()
        where excludedTurnIDs.contains(turn.id) == false {
            guard turn.itemsLoadState == .full else {
                return false
            }
            let boundary = (itemsByTurnID[turn.id] ?? []).last {
                $0.threadItem.isReviewNarrativeBoundary
            }
            if let boundary {
                return boundary.isExitedReviewModeMarker
            }
        }
        return false
    }

    private func shouldPreserveExistingFullItem(
        _ existing: CodexItem,
        incomingLoadState: CodexTurnItemsLoadState
    ) -> Bool {
        existing.itemsLoadState == .full && incomingLoadState != .full
    }

    private func commandReplayItem(
        matching incomingItem: CodexThreadItem,
        turnID: CodexTurnID?
    ) -> CodexItem? {
        guard let incomingCommand = incomingItem.command else {
            return nil
        }
        let sameTurnCandidates: [CodexItem]
        if let turnID {
            sameTurnCandidates = itemsByTurnID[turnID] ?? []
        } else {
            sameTurnCandidates = items.filter { $0.turnID == nil }
        }
        if let sameTurnReplay = sameTurnCandidates.first(where: { item in
            guard let existingCommand = item.threadItem.command else {
                return false
            }
            guard existingCommand.status?.isTerminal != true else {
                return false
            }
            return commandsMatchForReplay(existingCommand, incomingCommand)
        }) {
            return sameTurnReplay
        }
        return items.first { item in
            guard item.turnID != turnID else {
                return false
            }
            guard let existingCommand = item.threadItem.command else {
                return false
            }
            guard existingCommand.status?.isTerminal != true else {
                return false
            }
            guard commandsMatchForReplay(existingCommand, incomingCommand) else {
                return false
            }
            return commandsShareReplayIdentity(
                existingItemID: item.itemID,
                existingCommand: existingCommand,
                incomingItemID: incomingItem.id,
                incomingCommand: incomingCommand
            )
        }
    }

    private func commandsMatchForReplay(
        _ existingCommand: CodexCommand,
        _ incomingCommand: CodexCommand
    ) -> Bool {
        guard existingCommand.command == incomingCommand.command else {
            return false
        }
        if let existingCWD = existingCommand.cwd,
            let incomingCWD = incomingCommand.cwd,
            existingCWD != incomingCWD
        {
            return false
        }
        if let existingProcessID = existingCommand.processID,
            let incomingProcessID = incomingCommand.processID,
            existingProcessID != incomingProcessID
        {
            return false
        }
        return existingCommand.source == incomingCommand.source
            || existingCommand.source == nil
            || incomingCommand.source == nil
    }

    private func commandsShareReplayIdentity(
        existingItemID: String,
        existingCommand: CodexCommand,
        incomingItemID: String,
        incomingCommand: CodexCommand
    ) -> Bool {
        if existingItemID == incomingItemID {
            return true
        }
        if let existingProcessID = existingCommand.processID,
            let incomingProcessID = incomingCommand.processID,
            existingProcessID == incomingProcessID
        {
            return true
        }
        return false
    }

    private func itemByApplyingLifecycleStatus(
        _ status: CodexTurnStatus,
        to item: CodexThreadItem
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch item.content {
        case .command(var command):
            if status.isTerminal {
                command.status = lifecycleStatus(for: command, fallback: status)
            } else {
                command.status = command.status ?? lifecycleStatus(for: command, fallback: status)
            }
            content = .command(command)
        case .fileChange(var fileChange):
            fileChange.status = status.isTerminal ? status : fileChange.status ?? status
            content = .fileChange(fileChange)
        case .toolCall(var toolCall):
            toolCall.status = status.isTerminal ? status : toolCall.status ?? status
            content = .toolCall(toolCall)
        default:
            return item
        }
        return itemByReplacingContent(in: item, with: content)
    }

    private func itemByPreservingExistingLifecycle(
        from incomingItem: CodexThreadItem,
        existing existingItem: CodexThreadItem
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch (incomingItem.content, existingItem.content) {
        case (.command(var incomingCommand), .command(let existingCommand)):
            incomingCommand.status = mergedLifecycleStatus(
                incoming: incomingCommand.status,
                existing: existingCommand.status
            )
            incomingCommand.startedAt = incomingCommand.startedAt ?? existingCommand.startedAt
            incomingCommand.completedAt = incomingCommand.completedAt ?? existingCommand.completedAt
            incomingCommand.duration = incomingCommand.duration ?? existingCommand.duration
            incomingCommand.cwd = incomingCommand.cwd ?? existingCommand.cwd
            incomingCommand.processID = incomingCommand.processID ?? existingCommand.processID
            incomingCommand.source = incomingCommand.source ?? existingCommand.source
            if incomingCommand.commandActions.isEmpty {
                incomingCommand.commandActions = existingCommand.commandActions
            }
            content = .command(incomingCommand)
        case (.fileChange(var incomingFileChange), .fileChange(let existingFileChange)):
            incomingFileChange.status = mergedLifecycleStatus(
                incoming: incomingFileChange.status,
                existing: existingFileChange.status
            )
            if isOutputDeltaUpdate(incomingItem) == false {
                incomingFileChange.path = incomingFileChange.path ?? existingFileChange.path
                incomingFileChange.output = incomingFileChange.output ?? existingFileChange.output
            }
            content = .fileChange(incomingFileChange)
        case (.toolCall(var incomingToolCall), .toolCall(let existingToolCall)):
            incomingToolCall.namespace = incomingToolCall.namespace ?? existingToolCall.namespace
            incomingToolCall.server = incomingToolCall.server ?? existingToolCall.server
            incomingToolCall.name = incomingToolCall.name ?? existingToolCall.name
            incomingToolCall.arguments = incomingToolCall.arguments ?? existingToolCall.arguments
            incomingToolCall.result = incomingToolCall.result ?? existingToolCall.result
            incomingToolCall.error = incomingToolCall.error ?? existingToolCall.error
            incomingToolCall.status = mergedLifecycleStatus(
                incoming: incomingToolCall.status,
                existing: existingToolCall.status
            )
            content = .toolCall(incomingToolCall)
        default:
            return incomingItem
        }
        return itemByReplacingContent(
            in: incomingItem,
            with: content,
            preservingSemanticMetadataFrom: existingItem
        )
    }

    private func mergedLifecycleStatus(
        incoming: CodexTurnStatus?,
        existing: CodexTurnStatus?
    ) -> CodexTurnStatus? {
        guard let incoming else {
            return existing
        }
        if existing?.isTerminal == true, incoming.isTerminal == false {
            return existing
        }
        return incoming
    }

    private func terminalizeActiveItems(
        in turnID: CodexTurnID,
        status: CodexTurnStatus
    ) -> [CodexChatMutation] {
        guard status.isTerminal else {
            return []
        }
        var changes: [CodexChatMutation] = []
        for item in itemsByTurnID[turnID] ?? [] {
            let previousItem = item.threadItem
            let terminalItem = itemByApplyingTerminalLifecycleStatus(
                status,
                to: previousItem
            )
            guard terminalItem != previousItem else {
                continue
            }
            item.update(from: terminalItem, itemsLoadState: item.itemsLoadState)
            changes.appendIfPresent(changeForUpdatedItem(item, previousItem: previousItem))
        }
        return changes
    }

    private func itemByApplyingTerminalLifecycleStatus(
        _ status: CodexTurnStatus,
        to item: CodexThreadItem
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch item.content {
        case .command(var command):
            guard shouldTerminalizeLifecycleStatus(command.status) else {
                return item
            }
            command.status = lifecycleStatus(for: command, fallback: status)
            content = .command(command)
        case .fileChange(var fileChange):
            guard shouldTerminalizeLifecycleStatus(fileChange.status) else {
                return item
            }
            fileChange.status = status
            content = .fileChange(fileChange)
        case .toolCall(var toolCall):
            guard shouldTerminalizeLifecycleStatus(toolCall.status) else {
                return item
            }
            toolCall.status = status
            content = .toolCall(toolCall)
        default:
            return item
        }
        return itemByReplacingContent(in: item, with: content)
    }

    private func shouldTerminalizeLifecycleStatus(_ status: CodexTurnStatus?) -> Bool {
        guard let status else {
            return true
        }
        return status.isTerminal == false
    }

    private func lifecycleStatus(
        for command: CodexCommand,
        fallback status: CodexTurnStatus
    ) -> CodexTurnStatus {
        guard status == .completed, let exitCode = command.exitCode else {
            return status
        }
        return exitCode == 0 ? .completed : .failed
    }

    private func itemByReplacingContent(
        in item: CodexThreadItem,
        with content: CodexThreadItem.Content,
        preservingSemanticMetadataFrom metadataSource: CodexThreadItem? = nil
    ) -> CodexThreadItem {
        let metadataSource = metadataSource ?? item
        return CodexThreadItem(
            id: item.id,
            kind: item.kind,
            content: content,
            origin: metadataSource.origin,
            semanticRelation: metadataSource.semanticRelation,
            rawPayload: item.rawPayload
        )
    }

    private func seedOutputDeltaStateIfNeeded(
        _ item: CodexThreadItem,
        key: CodexChatItemKey
    ) {
        guard let delta = outputDeltaText(from: item) else {
            return
        }
        liveMergeState.outputDeltaTextByItemKey[key] = delta
    }

    @discardableResult
    private func mergeOutputDelta(
        _ incomingItem: CodexThreadItem,
        into existing: CodexItem,
        key: CodexChatItemKey
    ) -> Bool {
        guard existing.kind == incomingItem.kind,
            let delta = outputDeltaText(from: incomingItem)
        else {
            return false
        }

        let previousAccumulatedText = liveMergeState.outputDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta
        let merge = mergedDeltaText(
            existingText: outputText(from: existing.threadItem),
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta
        )
        liveMergeState.outputDeltaTextByItemKey[key] = merge.accumulatedText
        existing.update(
            from: itemByReplacingOutput(
                in: existing.threadItem,
                with: merge.text,
                using: incomingItem
            ),
            itemsLoadState: .full
        )
        return true
    }

    private func insertRunningTurnIfMissing(
        _ turnID: CodexTurnID?,
        into changes: inout [CodexChatMutation]
    ) {
        removeProvisionalSeedTurnIfNeeded(for: turnID, into: &changes)
        guard let turnID, turnsByID[turnID] == nil else {
            return
        }
        changes.appendIfPresent(upsertTurn(
            id: turnID,
            state: .inProgress,
            preservesExistingUsage: true
        ))
    }

    private func isOutputDeltaUpdate(_ item: CodexThreadItem) -> Bool {
        guard let rawPayload = item.rawPayload,
              let payload = try? JSONDecoder().decode(ItemProgressPayload.self, from: rawPayload)
        else {
            return false
        }
        return payload.delta != nil
    }

    private func outputDeltaText(from item: CodexThreadItem) -> String? {
        switch item.content {
        case .command(let command)
            where command.command.isEmpty && command.cwd == nil && command.exitCode == nil:
            command.output
        case .fileChange(let fileChange)
            where fileChange.path == nil:
            fileChange.output
        case .toolCall(let toolCall)
            where toolCall.namespace == nil && toolCall.server == nil && toolCall.name == nil
                && toolCall.arguments == nil && toolCall.error == nil:
            toolCall.result
        default:
            nil
        }
    }

    private func outputText(from item: CodexThreadItem) -> String? {
        switch item.content {
        case .command(let command):
            command.output
        case .fileChange(let fileChange):
            fileChange.output
        case .toolCall(let toolCall):
            toolCall.result
        default:
            nil
        }
    }

    private func itemByReplacingOutput(
        in existingItem: CodexThreadItem,
        with output: String,
        using incomingItem: CodexThreadItem
    ) -> CodexThreadItem {
        let content: CodexThreadItem.Content
        switch existingItem.content {
        case .command(var command):
            if case .command(let incomingCommand) = incomingItem.content,
                let status = incomingCommand.status
            {
                command.status = status
            }
            command.output = output
            content = .command(command)
        case .fileChange(var fileChange):
            if case .fileChange(let incomingFileChange) = incomingItem.content,
                let status = incomingFileChange.status
            {
                fileChange.status = status
            }
            fileChange.output = output
            content = .fileChange(fileChange)
        case .toolCall(var toolCall):
            if case .toolCall(let incomingToolCall) = incomingItem.content,
                let status = incomingToolCall.status
            {
                toolCall.status = status
            }
            toolCall.result = output
            content = .toolCall(toolCall)
        default:
            content = existingItem.content
        }
        return CodexThreadItem(
            id: existingItem.id,
            kind: existingItem.kind,
            content: content,
            origin: existingItem.origin,
            semanticRelation: existingItem.semanticRelation,
            rawPayload: incomingItem.rawPayload ?? existingItem.rawPayload
        )
    }

    private func merge(_ delta: CodexMessageDelta, turnID: CodexTurnID?) -> [CodexChatMutation] {
        let key = CodexChatItemKey(
            id: delta.itemID,
            kind: .agentMessage,
            turnID: turnID
        )
        let itemID = key.id
        let existingItem = item(for: key)
        let previousAccumulatedText = liveMergeState.messageDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta.text

        let existingMessage = existingItem?.message
        let merge = mergedDeltaText(
            existingText: existingMessage?.text,
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta.text
        )
        liveMergeState.messageDeltaTextByItemKey[key] = merge.accumulatedText
        let message = CodexMessage(
            id: itemID,
            role: existingMessage?.role ?? .assistant,
            phase: delta.phase ?? existingMessage?.phase,
            text: merge.text
        )
        let item = CodexThreadItem(id: itemID, kind: .agentMessage, content: .message(message))
        return mergeItems(
            [item],
            turnID: turnID,
            reviewCompanionEvidence: .orderedItems
        )
    }

    private func start(_ part: CodexReasoningPart, turnID: CodexTurnID?) -> [CodexChatMutation] {
        let key = CodexChatItemKey(id: part.id, kind: .reasoning, turnID: turnID)
        guard item(for: key) == nil else {
            return []
        }
        return mergeItems([
            .init(id: part.id, kind: .reasoning, content: .reasoning(.empty)),
        ], turnID: turnID, reviewCompanionEvidence: .orderedItems)
    }

    private func merge(_ delta: CodexReasoningDelta, turnID: CodexTurnID?) -> [CodexChatMutation] {
        let key = reasoningMergeKey(for: delta, turnID: turnID)
        if let currentItem = delta.currentItem {
            return mergeItems(
                [currentItem],
                turnID: turnID,
                reviewCompanionEvidence: .orderedItems
            )
        }
        let previousAccumulatedText = liveMergeState.reasoningDeltaTextByItemKey[key] ?? ""
        let accumulatedText = previousAccumulatedText + delta.delta

        let existingReasoning = item(for: key)?.reasoning
        let existingText: String?
        switch delta.part.kind {
        case .summary:
            existingText = existingReasoning?.summary.joined(separator: "\n")
        case .text:
            existingText = existingReasoning?.content.joined(separator: "\n")
        }
        let merge = mergedDeltaText(
            existingText: existingText,
            previousAccumulatedText: previousAccumulatedText,
            accumulatedText: accumulatedText,
            deltaText: delta.delta
        )
        liveMergeState.reasoningDeltaTextByItemKey[key] = merge.accumulatedText
        let reasoning: CodexReasoning
        switch delta.part.kind {
        case .summary:
            reasoning = .init(summary: merge.text)
        case .text:
            reasoning = .init(content: merge.text)
        }
        return mergeItems([
            .init(id: key.id, kind: .reasoning, content: .reasoning(reasoning)),
        ], turnID: turnID, reviewCompanionEvidence: .orderedItems)
    }

    private func reasoningMergeKey(
        for delta: CodexReasoningDelta,
        turnID: CodexTurnID?
    ) -> CodexChatItemKey {
        let parentKey = CodexChatItemKey(
            id: delta.part.itemID,
            kind: .reasoning,
            turnID: turnID
        )
        if item(for: parentKey)?.reasoning != nil {
            return parentKey
        }
        return CodexChatItemKey(id: delta.id, kind: .reasoning, turnID: turnID)
    }

    private func mergedDeltaText(
        existingText: String?,
        previousAccumulatedText: String,
        accumulatedText: String,
        deltaText: String
    ) -> DeltaTextMerge {
        guard let existingText, existingText.isEmpty == false else {
            return .init(text: accumulatedText, accumulatedText: accumulatedText)
        }
        if existingText.hasPrefix(accumulatedText) {
            return .init(text: existingText, accumulatedText: accumulatedText)
        }
        if existingText.hasSuffix(accumulatedText) {
            return .init(text: existingText, accumulatedText: existingText)
        }
        if accumulatedText.hasPrefix(existingText) {
            return .init(text: accumulatedText, accumulatedText: accumulatedText)
        }
        if previousAccumulatedText.isEmpty,
            deltaText.isEmpty == false,
            (existingText.hasPrefix(deltaText) || existingText.hasSuffix(deltaText))
        {
            return .init(text: existingText, accumulatedText: existingText)
        }
        if previousAccumulatedText.isEmpty {
            let mergedText = existingText + deltaText
            return .init(text: mergedText, accumulatedText: mergedText)
        }
        if existingText.hasSuffix(previousAccumulatedText) {
            let mergedText = existingText + deltaText
            return .init(text: mergedText, accumulatedText: mergedText)
        }
        if existingText == previousAccumulatedText {
            return .init(text: accumulatedText, accumulatedText: accumulatedText)
        }
        return .init(text: existingText + deltaText, accumulatedText: accumulatedText)
    }

    private func changeForUpdatedItem(
        _ item: CodexItem,
        previousItem: CodexThreadItem
    ) -> CodexChatMutation? {
        let currentItem = item.threadItem
        guard currentItem != previousItem else {
            return nil
        }
        if let delta = appendedText(
            from: previousItem,
            to: currentItem
        ) {
            return .itemTextAppended(
                id: item.id,
                turnID: item.turnID,
                delta: delta
            )
        }
        return .itemUpdated(id: item.id, turnID: item.turnID)
    }

    private func appendedText(
        from previousItem: CodexThreadItem,
        to currentItem: CodexThreadItem
    ) -> String? {
        guard previousItem.id == currentItem.id,
              previousItem.kind == currentItem.kind else {
            return nil
        }
        switch (previousItem.content, currentItem.content) {
        case (.message(let previous), .message(var current)):
            current.text = previous.text
            guard current == previous else { return nil }
        case (.plan, .plan):
            break
        case (.reasoning(let previous), .reasoning(let current)):
            guard reasoningHasOnlyAppendedText(from: previous, to: current) else {
                return nil
            }
        case (.command(let previous), .command(var current)):
            current.output = previous.output
            guard current == previous else { return nil }
        case (.fileChange(let previous), .fileChange(var current)):
            current.output = previous.output
            guard current == previous else { return nil }
        case (.toolCall(let previous), .toolCall(var current)):
            current.result = previous.result
            guard current == previous else { return nil }
        case (.contextCompaction, .contextCompaction),
            (.diagnostic, .diagnostic),
            (.log, .log):
            break
        case (.unknown(let previous), .unknown(var current)):
            current.text = previous.text
            guard current == previous else { return nil }
        default:
            return nil
        }
        return appendedText(
            previousText: previousItem.text,
            currentText: currentItem.text
        )
    }

    private func reasoningHasOnlyAppendedText(
        from previous: CodexReasoning,
        to current: CodexReasoning
    ) -> Bool {
        if previous.summary.isEmpty == false || current.summary.isEmpty == false {
            return previous.content == current.content
                && fragmentsHaveOnlyAppendedText(from: previous.summary, to: current.summary)
        }
        return fragmentsHaveOnlyAppendedText(from: previous.content, to: current.content)
    }

    private func fragmentsHaveOnlyAppendedText(
        from previous: [String],
        to current: [String]
    ) -> Bool {
        if previous.isEmpty {
            return current.count == 1 && current[0].isEmpty == false
        }
        if current.count == previous.count + 1,
           current.dropLast().elementsEqual(previous),
           current.last?.isEmpty == false {
            return true
        }
        guard previous.count == current.count,
              previous.dropLast().elementsEqual(current.dropLast()),
              let previousLast = previous.last,
              let currentLast = current.last else {
            return false
        }
        return currentLast.hasPrefix(previousLast) && currentLast.count > previousLast.count
    }

    private func appendedText(previousText: String?, currentText: String?) -> String? {
        guard let currentText else {
            return nil
        }
        let previousText = previousText ?? ""
        guard currentText.hasPrefix(previousText), currentText.count > previousText.count else {
            return nil
        }
        return String(currentText.dropFirst(previousText.count))
    }

    private func setUsage(_ usage: CodexTokenUsage, for turnID: CodexTurnID) -> CodexChatMutation? {
        if let turn = turnsByID[turnID] {
            let previousUsage = turn.usage
            turn.usage = usage
            return turn.usage == previousUsage ? nil : .turnUpdated(id: turn.id)
        } else {
            let turn = contextTurn(id: turnID, usage: usage)
            turns.append(turn)
            turnsByID[turn.id] = turn
            return .turnInserted(id: turn.id)
        }
    }

    private func item(for key: CodexChatItemKey) -> CodexItem? {
        itemsByMergeKey[key]
    }

    private func removeProvisionalSeedTurn(_ provisionalTurnID: CodexTurnID) -> [CodexChatMutation] {
        provisionalSeedTurnID = nil
        guard let provisionalTurn = turnsByID[provisionalTurnID] else {
            return []
        }

        let removedItems = items.filter { $0.turnID == provisionalTurnID }
        let removedChanges = removedItems.map { item in
            CodexChatMutation.itemRemoved(
                locator: .init(
                    item: item.threadItem,
                    turnID: requiredObservationTurnID(item.turnID)
                ),
                modelID: item.id
            )
        }
        let removedKeys = Set(removedItems.map(\.mergeKey))
        if removedKeys.isEmpty == false {
            items.removeAll { item in
                removedKeys.contains(item.mergeKey)
            }
            for item in removedItems {
                removeItemFromIndexes(item)
            }
            unregisterItemsFromContext(removedItems)
        }

        turns.removeAll { $0 === provisionalTurn }
        turnsByID.removeValue(forKey: provisionalTurnID)
        itemsByTurnID.removeValue(forKey: provisionalTurnID)
        provisionalTurn.replaceContextItems([])
        return removedChanges + [.turnRemoved(id: provisionalTurnID)]
    }

    @discardableResult
    private func removeProvisionalSeedTurnIfNeeded(
        for liveTurnID: CodexTurnID?,
        into changes: inout [CodexChatMutation]
    ) -> Bool {
        guard let provisionalTurnID = provisionalSeedTurnID,
            let liveTurnID
        else {
            return false
        }
        guard provisionalTurnID != liveTurnID,
            turnsByID[provisionalTurnID] != nil
        else {
            provisionalSeedTurnID = nil
            return false
        }

        changes.append(contentsOf: removeProvisionalSeedTurn(provisionalTurnID))
        changes.append(.turnUpdated(id: provisionalTurnID))
        return true
    }

    private func terminalizeActiveItemsBeforeAppending(
        _ incomingItem: CodexThreadItem,
        turnID: CodexTurnID?
    ) -> [CodexChatMutation] {
        terminalizeActiveItemsBeforeAppending(
            incomingKey: CodexChatItemKey(threadItem: incomingItem, turnID: turnID),
            turnID: turnID
        )
    }

    private func terminalizeActiveItemsBeforeAppending(
        incomingKey: CodexChatItemKey,
        turnID: CodexTurnID?
    ) -> [CodexChatMutation] {
        guard let turnID else {
            return []
        }
        if let existingItem = item(for: incomingKey),
            isLifecycleTrackedItem(existingItem.threadItem)
        {
            return []
        }
        var changes: [CodexChatMutation] = []
        for item in itemsByTurnID[turnID] ?? [] where item.mergeKey != incomingKey {
            let previousItem = item.threadItem
            let terminalItem = itemByApplyingTerminalLifecycleStatus(
                .completed,
                to: previousItem
            )
            guard terminalItem != previousItem else {
                continue
            }
            item.update(from: terminalItem, itemsLoadState: item.itemsLoadState)
            changes.appendIfPresent(changeForUpdatedItem(item, previousItem: previousItem))
        }
        return changes
    }

    private func isLifecycleTrackedItem(_ item: CodexThreadItem) -> Bool {
        switch item.content {
        case .command, .fileChange, .toolCall:
            true
        default:
            false
        }
    }

    private func hasActiveLifecycleStatus(_ item: CodexThreadItem) -> Bool {
        switch item.content {
        case .command(let command):
            shouldTerminalizeLifecycleStatus(command.status)
        case .fileChange(let fileChange):
            shouldTerminalizeLifecycleStatus(fileChange.status)
        case .toolCall(let toolCall):
            shouldTerminalizeLifecycleStatus(toolCall.status)
        default:
            false
        }
    }

    private func removeReasoningParts(
        parentItemID: String,
        turnID: CodexTurnID?
    ) -> [CodexChatMutation] {
        let prefixes = ["\(parentItemID):summary:", "\(parentItemID):content:"]
        let removedItems = items.filter { item in
            item.turnID == turnID && prefixes.contains { item.itemID.hasPrefix($0) }
        }
        guard removedItems.isEmpty == false else {
            return []
        }
        let removedChanges = removedItems.map { item in
            CodexChatMutation.itemRemoved(
                locator: .init(
                    item: item.threadItem,
                    turnID: requiredObservationTurnID(item.turnID)
                ),
                modelID: item.id
            )
        }
        let removedKeys = Set(removedItems.map(\.mergeKey))
        items.removeAll { item in
            removedKeys.contains(item.mergeKey)
        }
        for item in removedItems {
            removeItemFromIndexes(item)
        }
        unregisterItemsFromContext(removedItems)
        liveMergeState.reasoningDeltaTextByItemKey = liveMergeState.reasoningDeltaTextByItemKey
            .filter { key, _ in
                key.turnID != turnID || prefixes.contains { key.id.hasPrefix($0) } == false
            }
        return removedChanges
    }

    @discardableResult
    private func removeItemsOmittedFromAuthoritativeSnapshot(
        _ incomingItems: [CodexThreadItem],
        turnID: CodexTurnID,
        preservesOmittedSeededReviewLogItems: Bool = false
    ) -> [CodexChatMutation] {
        var retainedItems = Set<ObjectIdentifier>()
        for incomingItem in incomingItems {
            let incomingKey = CodexChatItemKey(
                threadItem: incomingItem,
                turnID: turnID
            )
            if let item = item(for: incomingKey) {
                retainedItems.insert(ObjectIdentifier(item))
            }
            if let item = commandReplayItem(matching: incomingItem, turnID: turnID) {
                retainedItems.insert(ObjectIdentifier(item))
            }
        }
        if preservesOmittedSeededReviewLogItems {
            for item in itemsByTurnID[turnID] ?? [] where item.kind.isSeededReviewLogItem {
                retainedItems.insert(ObjectIdentifier(item))
            }
        }
        let removedItems = items.filter { item in
            item.turnID == turnID && retainedItems.contains(ObjectIdentifier(item)) == false
        }
        guard removedItems.isEmpty == false else {
            return []
        }
        let removedChanges = removedItems.map { item in
            CodexChatMutation.itemRemoved(
                locator: .init(
                    item: item.threadItem,
                    turnID: requiredObservationTurnID(item.turnID)
                ),
                modelID: item.id
            )
        }
        let removedKeys = Set(removedItems.map(\.mergeKey))
        items.removeAll { item in
            removedKeys.contains(item.mergeKey)
        }
        for item in removedItems {
            removeItemFromIndexes(item)
        }
        unregisterItemsFromContext(removedItems)
        return removedChanges
    }

    private func markRunningIfNeeded(turnID: CodexTurnID?) -> CodexChatMutation? {
        let statusChange: CodexChatMutation?
        if status?.isActive != true {
            statusChange = setStatus(.active(activeFlags: []))
        } else {
            statusChange = nil
        }
        if let turnID {
            phase = .running(turnID: turnID)
        } else if case .running = phase {
            // A thread-scoped status update cannot replace known turn identity.
        } else {
            phase = .loading
        }
        return statusChange
    }

    private func setStatus(_ status: CodexThreadStatus?) -> CodexChatMutation? {
        let previousStatus = self.status
        self.status = status
        return previousStatus == status ? nil : .statusChanged(status)
    }

    private func markInactiveWithoutTerminalizingTurn() {
        switch phase {
        case .idle, .loading:
            phase = .idle
        case .running, .terminal, .failed:
            break
        }
    }

    private func markIdleIfActive() -> CodexChatMutation? {
        guard status?.isActive == true else {
            return nil
        }
        return setStatus(.idle)
    }

    package func syncPhaseAfterRefresh(includeTurns: Bool) {
        if includeTurns {
            syncPhaseWithTurnsAfterRefresh()
        } else {
            syncPhaseWithStatusAfterMetadataRefresh()
        }
    }

    package func beginLoading() {
        phase = .loading
    }

    package func restorePhaseIfLoading(_ phase: CodexChatPhase) {
        guard self.phase == .loading else {
            return
        }
        self.phase = phase
    }

    package func observationSnapshot() -> CodexThreadSnapshot {
        precondition(
            items.allSatisfy { $0.turnID != nil },
            "Current-v2 chat snapshots require every item to have a turn ID."
        )
        return CodexThreadSnapshot(
            id: id,
            workspace: workspace?.url,
            name: name,
            preview: preview,
            modelProvider: modelProvider,
            sessionID: sessionID,
            parentThreadID: parentThreadID,
            source: source,
            sourceKind: source == nil ? sourceKind : nil,
            gitInfo: gitInfo,
            createdAt: createdAt,
            updatedAt: updatedAt,
            recencyAt: recencyAt,
            status: status,
            ephemeral: ephemeral,
            turns: turns.map(observationSnapshot(for:))
        )
    }

    package func observationUpdates(
        for mutations: [CodexChatMutation]
    ) -> [CodexChatUpdate] {
        let replacingTurnIDs = Set(mutations.compactMap { mutation -> CodexTurnID? in
            switch mutation {
            case .turnInserted(let id), .turnRemoved(let id):
                id
            default:
                nil
            }
        })
        let removedTurnIDs = Set(mutations.compactMap { mutation -> CodexTurnID? in
            if case .turnRemoved(let id) = mutation { return id }
            return nil
        })
        var deferredTurnUpdateIDs: [CodexTurnID] = []
        var updates = mutations.compactMap { mutation -> CodexChatUpdate? in
            switch mutation {
            case .turnInserted(let id):
                if removedTurnIDs.contains(id) { return nil }
                return observationTurnUpdate(id: id, inserted: true)
            case .turnUpdated(let id):
                if removedTurnIDs.contains(id) { return nil }
                if deferredTurnUpdateIDs.contains(id) == false {
                    deferredTurnUpdateIDs.append(id)
                }
                return nil
            case .turnRemoved(let id):
                return .turnRemoved(id: id)
            case .itemInserted(let id, let turnID):
                if turnID.map(replacingTurnIDs.contains) == true { return nil }
                return observationItemUpdate(id: id, turnID: turnID, inserted: true)
            case .itemUpdated(let id, let turnID):
                if turnID.map(replacingTurnIDs.contains) == true { return nil }
                return observationItemUpdate(id: id, turnID: turnID, inserted: false)
            case .itemRemoved(let locator, _):
                if replacingTurnIDs.contains(locator.turnID) { return nil }
                return .itemRemoved(locator)
            case .itemTextAppended(let id, let turnID, let delta):
                if turnID.map(replacingTurnIDs.contains) == true { return nil }
                let turnID = requiredObservationTurnID(turnID)
                let (item, _) = observationItem(id: id, turnID: turnID)
                return .itemTextAppended(
                    .init(item: item.threadItem, turnID: turnID),
                    delta: delta
                )
            case .statusChanged(let status):
                return .statusChanged(status)
            case .phaseChanged(let phase):
                return .phaseChanged(phase)
            }
        }
        updates.append(contentsOf: deferredTurnUpdateIDs.map {
            observationTurnUpdate(id: $0, inserted: false)
        })
        return updates
    }

    private func observationSnapshot(for turn: CodexTurn) -> CodexTurnSnapshot {
        guard let state = turn.state else {
            preconditionFailure("Observed turn \(turn.id.rawValue) has no state.")
        }
        return CodexTurnSnapshot(
            id: turn.id,
            state: state,
            itemsLoadState: turn.itemsLoadState,
            items: turn.items.map(\.threadItem)
        )
    }

    private func observationTurnUpdate(
        id: CodexTurnID,
        inserted: Bool
    ) -> CodexChatUpdate {
        guard let index = turns.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("Observed turn mutation targets missing turn \(id.rawValue).")
        }
        let snapshot = observationSnapshot(for: turns[index])
        return inserted
            ? .turnInserted(snapshot, index: index)
            : .turnUpdated(snapshot, index: index)
    }

    private func observationItemUpdate(
        id: CodexChatItemID,
        turnID: CodexTurnID?,
        inserted: Bool
    ) -> CodexChatUpdate {
        let turnID = requiredObservationTurnID(turnID)
        let (model, index) = observationItem(id: id, turnID: turnID)
        let item = model.threadItem
        return inserted
            ? .itemInserted(item: item, turnID: turnID, index: index)
            : .itemUpdated(item: item, turnID: turnID, index: index)
    }

    private func observationItem(
        id: CodexChatItemID,
        turnID: CodexTurnID
    ) -> (CodexItem, Int) {
        let turnItems = items(in: turnID)
        guard let index = turnItems.firstIndex(where: { $0.id == id }) else {
            preconditionFailure("Observed item mutation targets missing item \(id).")
        }
        return (turnItems[index], index)
    }

    private func requiredObservationTurnID(_ turnID: CodexTurnID?) -> CodexTurnID {
        guard let turnID else {
            preconditionFailure("Current-v2 observed item mutations require a turn ID.")
        }
        return turnID
    }

    @discardableResult
    package func syncPhaseWithTurnsAfterRefresh() -> CodexChatMutation? {
        let previousPhase = phase
        guard let latestTurn = turns.last else {
            phase = status?.isActive == true ? .loading : .idle
            return phase == previousPhase ? nil : .phaseChanged(phase)
        }
        switch latestTurn.state {
        case .inProgress:
            phase = .running(turnID: latestTurn.id)
        case .completed:
            phase = .terminal(turnID: latestTurn.id, disposition: .completed)
        case .interrupted:
            phase = .terminal(turnID: latestTurn.id, disposition: .interrupted)
        case .failed:
            phase = .terminal(turnID: latestTurn.id, disposition: .failed)
        case .unknown(let rawValue, _):
            phase = .terminal(
                turnID: latestTurn.id,
                disposition: .invalid(rawStatus: rawValue)
            )
        case nil:
            phase = status?.isActive == true ? .loading : .idle
        }
        return phase == previousPhase ? nil : .phaseChanged(phase)
    }

    private func syncPhaseWithStatusAfterMetadataRefresh() {
        switch status {
        case .active:
            if case .running = phase {
                return
            }
            phase = .loading
        case .notLoaded, .idle, .systemError, .unknown, .none:
            switch phase {
            case .terminal, .failed:
                break
            case .idle, .loading, .running:
                phase = .idle
            }
        }
    }

    private func appendPhaseChange(
        to changes: inout [CodexChatMutation],
        previousPhase: CodexChatPhase
    ) {
        if phase != previousPhase {
            changes.append(.phaseChanged(phase))
        }
    }

    package func fail(with error: any Error) {
        if let failure = error as? CodexFetchFailure {
            phase = .failed(failure)
            return
        }
        if let appServerError = error as? CodexAppServerError {
            phase = .failed(.appServer(appServerError))
            return
        }
        preconditionFailure("Unexpected CodexChat load failure: \(error)")
    }

    package func resetLiveMergeStateFromCurrentItems() {
        liveMergeState = LiveMergeState()
    }

    private func rebuildTurnIndex() {
        turnsByID = Dictionary(
            turns.map { ($0.id, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    private func rebuildItemIndexes() {
        itemsByMergeKey.removeAll(keepingCapacity: true)
        itemsByTurnID.removeAll(keepingCapacity: true)
        for turn in turns {
            turn.replaceContextItems([])
        }
        var coalescedItems: [CodexItem] = []
        coalescedItems.reserveCapacity(items.count)
        for item in items where itemsByMergeKey[item.mergeKey] == nil {
            coalescedItems.append(item)
            addItemToIndexes(item)
        }
        if coalescedItems.count != items.count {
            items = coalescedItems
        }
    }

    private func appendItem(_ item: CodexItem) {
        items.append(item)
        addItemToIndexes(item)
    }

    private func replaceItemAcrossTurns(
        _ existing: CodexItem,
        with incomingItem: CodexThreadItem,
        turnID: CodexTurnID?,
        itemsLoadState: CodexTurnItemsLoadState
    ) -> CodexItem {
        let replacementIndex = items.firstIndex { $0 === existing }
        let previousMergeKey = existing.mergeKey
        removeItemFromIndexes(existing)
        unregisterItemsFromContext([existing])
        let replacement = contextItem(
            threadItem: incomingItem,
            turnID: turnID,
            itemsLoadState: itemsLoadState
        )
        if let replacementIndex {
            items[replacementIndex] = replacement
        } else {
            items.append(replacement)
        }
        addItemToIndexes(replacement)
        if let outputDeltaText = liveMergeState.outputDeltaTextByItemKey.removeValue(
            forKey: previousMergeKey
        ) {
            liveMergeState.outputDeltaTextByItemKey[replacement.mergeKey] = outputDeltaText
        }
        return replacement
    }

    // Single boundary for identity changes: whenever an existing item's merge
    // key changes, live merge state and the context-level item registration
    // must move together, or lagging references to the old key resurrect it.
    private func migrateItemIdentity(
        _ item: CodexItem,
        from previousKey: CodexChatItemKey
    ) {
        migrateLiveMergeState(from: previousKey, to: item.mergeKey)
        modelContext?.rekeyContextItem(
            item,
            from: previousKey.modelID(in: id),
            to: item.mergeKey.modelID(in: id)
        )
    }

    private func migrateLiveMergeState(
        from oldKey: CodexChatItemKey,
        to newKey: CodexChatItemKey
    ) {
        guard oldKey != newKey else {
            return
        }
        if let messageText = liveMergeState.messageDeltaTextByItemKey.removeValue(forKey: oldKey) {
            liveMergeState.messageDeltaTextByItemKey[newKey] = messageText
        }
        if let reasoningText = liveMergeState.reasoningDeltaTextByItemKey.removeValue(
            forKey: oldKey
        ) {
            liveMergeState.reasoningDeltaTextByItemKey[newKey] = reasoningText
        }
        if let outputText = liveMergeState.outputDeltaTextByItemKey.removeValue(forKey: oldKey) {
            liveMergeState.outputDeltaTextByItemKey[newKey] = outputText
        }
    }

    private func addItemToIndexes(_ item: CodexItem) {
        itemsByMergeKey[item.mergeKey] = item
        if let turnID = item.turnID {
            itemsByTurnID[turnID, default: []].append(item)
            turnsByID[turnID]?.attachContextItemIfNeeded(item)
        }
    }

    private func removeItemFromIndexes(_ item: CodexItem) {
        itemsByMergeKey.removeValue(forKey: item.mergeKey)
        guard let turnID = item.turnID else {
            return
        }
        itemsByTurnID[turnID]?.removeAll { $0 === item }
        turnsByID[turnID]?.detachContextItem(item)
        if itemsByTurnID[turnID]?.isEmpty == true {
            itemsByTurnID.removeValue(forKey: turnID)
        }
    }

    private func unregisterItemsFromContext(_ items: [CodexItem]) {
        guard let modelContext else {
            return
        }
        for item in items {
            modelContext.unregisterContextItem(item)
            item.detachFromContext()
        }
    }

    private struct LiveMergeState {
        var messageDeltaTextByItemKey: [CodexChatItemKey: String] = [:]
        var reasoningDeltaTextByItemKey: [CodexChatItemKey: String] = [:]
        var outputDeltaTextByItemKey: [CodexChatItemKey: String] = [:]
    }

    private struct DeltaTextMerge {
        var text: String
        var accumulatedText: String
    }

    private struct ItemProgressPayload: Decodable {
        var delta: String?
    }

}

private extension CodexThreadItem.Kind {
    var isSeededReviewLogItem: Bool {
        switch self {
        case .userMessage:
            false
        case .agentMessage,
             .enteredReviewMode,
             .exitedReviewMode,
             .plan,
             .reasoning,
             .commandExecution,
             .fileChange,
             .mcpToolCall,
             .dynamicToolCall,
             .collabAgentToolCall,
             .subAgentActivity,
             .webSearch,
             .imageView,
             .sleep,
             .imageGeneration,
             .contextCompaction,
             .diagnostic,
             .error,
             .unknown:
            true
        }
    }
}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexWorkspaceGroup: Sendable {}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexWorkspace: Sendable {}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexTurn: Sendable {}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexItem: Sendable {}

@available(
    *,
    unavailable,
    message: "Codex persistent models are not Sendable. Use the model ID to cross concurrency contexts."
)
extension CodexChat: Sendable {}
