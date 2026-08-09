import CodexAppServerKit
import Foundation

package struct CodexChatRecord: Hashable, Sendable {
    package var id: CodexThreadID
    package var name: String?
    package var preview: String?
    package var title: String
    package var modelProvider: String?
    package var isArchived: Bool
    package var workspaceID: CodexWorkspaceID?
    package var workspaceURL: URL?
    package var workspaceGroupID: CodexWorkspaceGroupID?
    package var source: CodexThreadSessionSource?
    package var sourceKind: CodexThreadSourceKind?
    package var sourceProvenance: CodexThreadListSourceProvenance?
    package var searchableText: String
    package var createdAt: Date?
    package var updatedAt: Date?
    package var recencyAt: Date?

    package init(chat: CodexChat) {
        id = chat.id
        name = chat.name
        preview = chat.preview
        title = chat.title
        modelProvider = chat.modelProvider
        isArchived = chat.isArchived
        workspaceID = chat.workspaceID
        workspaceURL = chat.workspace?.url
        workspaceGroupID = chat.workspaceGroupID
        source = chat.source
        sourceKind = chat.sourceKind
        sourceProvenance = chat.threadListSourceProvenance
        searchableText = chat.searchableText
        createdAt = chat.createdAt
        updatedAt = chat.updatedAt
        recencyAt = chat.recencyAt
    }
}

package enum CodexThreadCandidateSourceScope: Hashable, Sendable {
    case defaultUserVisible
    case explicit([CodexThreadSourceKind])

    package static let userVisibleNoninteractiveKinds: [CodexThreadSourceKind] = [
        .exec,
        .appServer,
        .subAgentReview,
        .subAgentCompact,
        .subAgentThreadSpawn,
        .subAgentOther,
        .unknown,
    ]

    package var sourceKindFilters: [[CodexThreadSourceKind]?] {
        switch self {
        case .defaultUserVisible:
            // The app-server's nil filter is the only way to include its supported custom
            // interactive sources. A second disjoint query adds user-visible noninteractive
            // sources without admitting internal memory-consolidation sessions.
            [nil, Self.userVisibleNoninteractiveKinds]
        case .explicit(let sourceKinds):
            [sourceKinds]
        }
    }

    package var requiresCompositeFetch: Bool {
        switch self {
        case .defaultUserVisible:
            true
        case .explicit:
            false
        }
    }

    package func matches(_ record: CodexChatRecord) -> Bool {
        if record.source != nil || record.sourceKind != nil {
            return matches(source: record.source, sourceKind: record.sourceKind)
        }
        guard let provenance = record.sourceProvenance else {
            return false
        }
        return provenance.possibilities.allSatisfy(contains)
    }

    package func matches(_ resolution: CodexThreadSourceResolution) -> Bool {
        switch resolution {
        case .exact(let source):
            matches(source: source, sourceKind: source.sourceKind)
        case .kindOnly(let sourceKind):
            matches(source: nil, sourceKind: sourceKind)
        case .partitionProven(let provenance):
            provenance.possibilities.allSatisfy(contains)
        case .unresolved, .knownNull:
            false
        }
    }

    package func contains(_ possibility: CodexThreadListSourcePossibility) -> Bool {
        switch possibility {
        case .kind(let sourceKind):
            matches(source: nil, sourceKind: sourceKind)
        case .supportedCustomInteractive:
            if case .defaultUserVisible = self {
                true
            } else {
                false
            }
        }
    }

    package func matches(
        source: CodexThreadSessionSource?,
        sourceKind: CodexThreadSourceKind?
    ) -> Bool {
        if let source {
            switch self {
            case .defaultUserVisible:
                return Self.matchesDefaultUserVisibleSource(source)
            case .explicit(let sourceKinds):
                return sourceKinds.contains { source.matches(sourceKind: $0) }
            }
        }
        guard let sourceKind else {
            return false
        }
        switch self {
        case .defaultUserVisible:
            return sourceKind == .cli
                || sourceKind == .vscode
                || Self.userVisibleNoninteractiveKinds.contains(sourceKind)
        case .explicit(let sourceKinds):
            return sourceKinds.contains { filterKind in
                if filterKind == .subAgent {
                    return sourceKind == .subAgent
                        || sourceKind == .subAgentReview
                        || sourceKind == .subAgentCompact
                        || sourceKind == .subAgentThreadSpawn
                        || sourceKind == .subAgentOther
                }
                return sourceKind == filterKind
            }
        }
    }

    private static func matchesDefaultUserVisibleSource(
        _ source: CodexThreadSessionSource
    ) -> Bool {
        switch source {
        case .cli, .vscode, .exec, .appServer, .unknown:
            return true
        case .custom(let value):
            return value == "atlas" || value == "chatgpt"
        case .subAgent(.review), .subAgent(.compact), .subAgent(.threadSpawn),
            .subAgent(.other):
            return true
        case .subAgent(.memoryConsolidation):
            return false
        }
    }
}

package struct CodexThreadQueryPlan: Sendable {
    package typealias RecordPredicate = @Sendable (CodexChatRecord) -> Bool

    package var predicate: RecordPredicate?
    package var predicateSignature: CodexChatPredicateSignature?
    package var sortPlans: [CodexSortPlan<CodexChat>]
    package var fetchLimit: Int?
    package var fetchOffset: Int
    package var includeContextChanges: Bool
    private var serverFilter: CodexThreadServerFilter

    package init(descriptor: CodexFetchDescriptor<CodexChat>) throws {
        if let predicate = descriptor.predicate {
            let lowered = try makeCodexChatRecordPredicate(predicate)
            self.predicate = lowered.predicate
            self.predicateSignature = lowered.signature
            self.serverFilter = try CodexThreadServerFilter(signature: lowered.signature)
        } else {
            self.predicate = { $0.isArchived == false }
            self.predicateSignature = nil
            self.serverFilter = .defaultChatFilter
        }
        self.sortPlans = try descriptor.validatedSortPlans()
        self.fetchLimit = descriptor.fetchLimit
        self.fetchOffset = descriptor.normalizedFetchOffset
        self.includeContextChanges = descriptor.includeContextChanges
    }

    package var signature: CodexFetchDescriptorSignature {
        CodexFetchDescriptorSignature(
            modelKind: .chat,
            predicate: predicateSignature,
            sortPlans: sortPlans.map(\.signature),
            fetchLimit: fetchLimit,
            fetchOffset: fetchOffset,
            includeContextChanges: includeContextChanges,
            validationFailure: nil
        )
    }

    package var archived: Bool? {
        serverFilter.archived
    }

    package var archiveScopes: [Bool] {
        archived.map { [$0] } ?? [false, true]
    }

    package var workspaces: [URL]? {
        serverFilter.workspaces
    }

    package var singleWorkspace: URL? {
        guard let workspaces, workspaces.count == 1 else {
            return nil
        }
        return workspaces[0]
    }

    package var searchTerm: String? {
        serverFilter.searchTerm
    }

    package var modelProviders: [String]? {
        serverFilter.modelProviders
    }

    package var sourceKinds: [CodexThreadSourceKind]? {
        serverFilter.sourceKinds
    }

    package var candidateSourceScope: CodexThreadCandidateSourceScope {
        sourceKinds.map(CodexThreadCandidateSourceScope.explicit) ?? .defaultUserVisible
    }

    package var serverPredicateIsComplete: Bool {
        serverFilter.isComplete
    }

    package var membershipRequiresServerRefresh: Bool {
        serverFilter.requiresServerRefreshForMembership
    }

    package var usesServerOwnedOrdering: Bool {
        sortPlans.isEmpty || sortPlans.first?.key == .recencyAt
    }

    package func mutationStrategy(
        for operation: CodexFetchedResultsMutationOperation
    ) -> CodexFetchedResultsMutationStrategy {
        let requiresAuthoritativeRefresh =
            membershipRequiresServerRefresh || usesServerOwnedOrdering
        switch operation {
        case .insert, .archive, .relationshipRefresh:
            return requiresAuthoritativeRefresh ? .refreshLoadedWindow : .applyLocally
        case .revalidate(let affectsMembership, let hasNextPage):
            return requiresAuthoritativeRefresh
                || (affectsMembership && (hasNextPage || fetchOffset > 0))
                ? .refreshLoadedWindow
                : .applyLocally
        case .remove(let hasNextPage):
            return requiresAuthoritativeRefresh || fetchOffset > 0 || hasNextPage
                ? .refreshLoadedWindow
                : .removeLocally
        }
    }

    package func matchesLocalCandidate(_ chat: CodexChat) -> Bool {
        matchesLocalCandidate(CodexChatRecord(chat: chat))
    }

    package func matchesLocalCandidate(_ record: CodexChatRecord) -> Bool {
        guard serverFilter.matchesArchiveScope(record) else {
            return false
        }
        if record.source != nil || record.sourceKind != nil {
            return candidateSourceScope.matches(record)
                && (predicate?(record) ?? true)
        }
        guard let provenance = record.sourceProvenance else {
            return false
        }
        return provenance.possibilities.allSatisfy { possibility in
            guard candidateSourceScope.contains(possibility) else {
                return false
            }
            var projectedRecord = record
            projectedRecord.sourceKind = possibility.projectedSourceKind
            return predicate?(projectedRecord) ?? true
        }
    }

    package func matchesServerResponse(_ chat: CodexChat) -> Bool {
        let record = CodexChatRecord(chat: chat)
        guard candidateSourceScope.matches(record) else {
            return false
        }
        return serverFilter.isComplete || matchesLocalCandidate(record)
    }

    package func matchesArchiveScope(_ archived: Bool) -> Bool {
        serverFilter.matchesArchiveScope(archived)
    }

    package func threadQuery(
        cursor: String?,
        includePaging: Bool,
        archived archiveScope: Bool? = nil
    ) -> CodexThreadQuery {
        let serverSort = sortPlans.first { sortPlan in
            switch sortPlan.key {
            case .createdAt, .updatedAt, .recencyAt:
                return true
            case .name:
                return false
            }
        }
        return CodexThreadQuery(
            archived: archiveScope ?? archived,
            cursor: includePaging ? cursor : nil,
            workspaces: workspaces,
            limit: includePaging ? fetchLimit : nil,
            searchTerm: searchTerm,
            modelProviders: modelProviders,
            sortDirection: serverSort?.threadSortDirection,
            sortKey: serverSort?.threadSortKey,
            sourceKinds: sourceKinds
        )
    }
}

package enum CodexFetchedResultsMutationOperation: Sendable, Equatable {
    case insert
    case archive
    case revalidate(affectsMembership: Bool, hasNextPage: Bool)
    case remove(hasNextPage: Bool)
    case relationshipRefresh
}

package enum CodexFetchedResultsMutationStrategy: Sendable, Equatable {
    case applyLocally
    case removeLocally
    case refreshLoadedWindow
}

package enum CodexFetchDescriptorModelKind: Hashable, Sendable {
    case chat
    case workspace
    case workspaceGroup
    case unsupported(String)
}

package struct CodexFetchDescriptorSignature: Hashable, Sendable {
    package var modelKind: CodexFetchDescriptorModelKind
    package var predicate: CodexChatPredicateSignature?
    package var sortPlans: [CodexSortPlanSignature]
    package var fetchLimit: Int?
    package var fetchOffset: Int
    package var includeContextChanges: Bool
    package var validationFailure: CodexFetchValidationError?
}

package struct CodexSortPlanSignature: Hashable, Sendable {
    package var path: CodexSortPath
    package var order: SortOrder
    package var stringComparator: String.StandardComparator?
}

extension CodexSortPlan {
    package var signature: CodexSortPlanSignature {
        .init(path: path, order: order, stringComparator: stringComparator)
    }
}

extension CodexFetchDescriptor {
    package var querySignature: CodexFetchDescriptorSignature {
        do {
            if let fetchLimit, fetchLimit < 0 {
                throw CodexFetchValidationError.negativeFetchLimit(fetchLimit)
            }
            if let fetchOffset, fetchOffset < 0 {
                throw CodexFetchValidationError.negativeFetchOffset(fetchOffset)
            }
            if predicate != nil, Model.self != CodexChat.self {
                throw CodexFetchValidationError.unsupportedPredicate(
                    String(describing: Model.self)
                )
            }
            let kind: CodexFetchDescriptorModelKind
            if Model.self == CodexChat.self {
                return try CodexThreadQueryPlan(
                    descriptor: self as! CodexFetchDescriptor<CodexChat>
                ).signature
            } else if Model.self == CodexWorkspace.self {
                kind = .workspace
            } else if Model.self == CodexWorkspaceGroup.self {
                kind = .workspaceGroup
            } else {
                throw CodexFetchValidationError.unsupportedModel(String(describing: Model.self))
            }
            return CodexFetchDescriptorSignature(
                modelKind: kind,
                predicate: nil,
                sortPlans: try validatedSortPlans().map(\.signature),
                fetchLimit: fetchLimit,
                fetchOffset: normalizedFetchOffset,
                includeContextChanges: includeContextChanges,
                validationFailure: nil
            )
        } catch let failure as CodexFetchValidationError {
            return CodexFetchDescriptorSignature(
                modelKind: .unsupported(String(describing: Model.self)),
                predicate: nil,
                sortPlans: [],
                fetchLimit: fetchLimit,
                fetchOffset: normalizedFetchOffset,
                includeContextChanges: includeContextChanges,
                validationFailure: failure
            )
        } catch {
            preconditionFailure("Unexpected fetch descriptor validation error: \(error)")
        }
    }
}

package enum CodexChatPredicateKey: Hashable, Sendable {
    case isArchived
    case modelProvider
    case workspaceID
    case sourceKind
    case searchableText
}

package enum CodexChatPredicateValue: Hashable, Sendable {
    case key(CodexChatPredicateKey)
    case bool(Bool)
    case string(String)
    case optionalString(String?)
    case workspaceID(CodexWorkspaceID)
    case optionalWorkspaceID(CodexWorkspaceID?)
    case sourceKind(CodexThreadSourceKind)
    case optionalSourceKind(CodexThreadSourceKind?)
    case stringArray([String])
    case workspaceIDArray([CodexWorkspaceID])
    case sourceKindArray([CodexThreadSourceKind])
    case nilLiteral(String)
}

extension CodexChatPredicateValue {
    fileprivate func codexPredicateEquals(_ other: Self) -> Bool {
        switch (self, other) {
        case (.nilLiteral, .optionalString(.none)),
            (.optionalString(.none), .nilLiteral),
            (.nilLiteral, .optionalWorkspaceID(.none)),
            (.optionalWorkspaceID(.none), .nilLiteral),
            (.nilLiteral, .optionalSourceKind(.none)),
            (.optionalSourceKind(.none), .nilLiteral):
            return true
        case (.optionalString(.some(let lhs)), .string(let rhs)),
            (.string(let rhs), .optionalString(.some(let lhs))):
            return lhs == rhs
        case (.optionalWorkspaceID(.some(let lhs)), .workspaceID(let rhs)),
            (.workspaceID(let rhs), .optionalWorkspaceID(.some(let lhs))):
            return lhs == rhs
        case (.optionalSourceKind(.some(let lhs)), .sourceKind(let rhs)),
            (.sourceKind(let rhs), .optionalSourceKind(.some(let lhs))):
            return lhs == rhs
        default:
            return self == other
        }
    }
}

package indirect enum CodexChatPredicateSignature: Hashable, Sendable {
    case bool(CodexChatPredicateValue)
    case equal(CodexChatPredicateValue, CodexChatPredicateValue)
    case notEqual(CodexChatPredicateValue, CodexChatPredicateValue)
    case localizedStandardContains(CodexChatPredicateValue, CodexChatPredicateValue)
    case contains(CodexChatPredicateValue, CodexChatPredicateValue)
    case conjunction(CodexChatPredicateSignature, CodexChatPredicateSignature)
    case disjunction(CodexChatPredicateSignature, CodexChatPredicateSignature)
    case negation(CodexChatPredicateSignature)
}

private struct CodexThreadServerFilter: Hashable, Sendable {
    private enum ArchiveScope: Equatable {
        case unscoped
        case scoped(Bool)
        case ambiguous
    }

    var archived: Bool?
    var workspaces: [URL]?
    var searchTerm: String?
    var modelProviders: [String]?
    var sourceKinds: [CodexThreadSourceKind]?
    var isComplete = true

    init() {}

    init(signature: CodexChatPredicateSignature) throws {
        let derivedFilter = Self.filter(from: signature)
        if signature.referencesSourceKind, derivedFilter?.sourceKinds == nil {
            throw CodexFetchValidationError.unsupportedPredicate(
                String(describing: signature)
            )
        }
        let archiveScope = Self.archiveScope(from: signature)
        guard var filter = derivedFilter else {
            switch archiveScope {
            case .scoped(let archived):
                self = Self(isComplete: false)
                self.archived = archived
            case .unscoped:
                self = Self(isComplete: false)
            case .ambiguous:
                self = Self(isComplete: false)
            }
            return
        }
        switch archiveScope {
        case .scoped(let archived):
            if let filterArchived = filter.archived, filterArchived != archived {
                throw CodexFetchValidationError.invalidArchiveScope(
                    String(describing: signature)
                )
            }
            filter.archived = archived
        case .unscoped:
            break
        case .ambiguous:
            filter.archived = nil
            filter.isComplete = false
        }
        self = filter
    }

    private init(isComplete: Bool) {
        self.isComplete = isComplete
    }

    static var defaultChatFilter: Self {
        var filter = Self()
        filter.archived = false
        return filter
    }

    var requiresServerRefreshForMembership: Bool {
        searchTerm?.isEmpty == false
            || modelProviders?.isEmpty == false
            || isComplete == false
    }

    func matchesArchiveScope(_ record: CodexChatRecord) -> Bool {
        matchesArchiveScope(record.isArchived)
    }

    func matchesArchiveScope(_ archived: Bool) -> Bool {
        self.archived.map { archived == $0 } ?? true
    }

    private static func archiveScope(from signature: CodexChatPredicateSignature) -> ArchiveScope {
        switch signature {
        case .bool(.key(.isArchived)):
            return .scoped(true)
        case .bool:
            return .unscoped
        case .equal(let lhs, let rhs):
            return equalityArchiveScope(lhs, rhs)
        case .notEqual(let lhs, let rhs):
            return inequalityArchiveScope(lhs, rhs)
        case .localizedStandardContains, .contains:
            return .unscoped
        case .conjunction(let lhs, let rhs):
            if lhs.boolConstant == false || rhs.boolConstant == false {
                return .unscoped
            }
            if lhs.boolConstant == true {
                return archiveScope(from: rhs)
            }
            if rhs.boolConstant == true {
                return archiveScope(from: lhs)
            }
            return mergeConjunctionArchiveScope(archiveScope(from: lhs), archiveScope(from: rhs))
        case .disjunction(let lhs, let rhs):
            if lhs.boolConstant == true || rhs.boolConstant == true {
                return .unscoped
            }
            if lhs.boolConstant == false {
                return archiveScope(from: rhs)
            }
            if rhs.boolConstant == false {
                return archiveScope(from: lhs)
            }
            return mergeDisjunctionArchiveScope(archiveScope(from: lhs), archiveScope(from: rhs))
        case .negation(let signature):
            return negatedArchiveScope(from: signature)
        }
    }

    private static func equalityArchiveScope(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> ArchiveScope {
        switch (lhs, rhs) {
        case (.key(.isArchived), .bool(let value)), (.bool(let value), .key(.isArchived)):
            return .scoped(value)
        default:
            return .unscoped
        }
    }

    private static func inequalityArchiveScope(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> ArchiveScope {
        switch (lhs, rhs) {
        case (.key(.isArchived), .bool(let value)), (.bool(let value), .key(.isArchived)):
            return .scoped(!value)
        default:
            return .unscoped
        }
    }

    private static func negatedArchiveScope(
        from signature: CodexChatPredicateSignature
    ) -> ArchiveScope {
        switch signature {
        case .bool(.key(.isArchived)):
            return .scoped(false)
        case .bool:
            return .unscoped
        case .equal(let lhs, let rhs):
            return negatedEqualityArchiveScope(lhs, rhs)
        case .notEqual(let lhs, let rhs):
            return negatedInequalityArchiveScope(lhs, rhs)
        case .localizedStandardContains, .contains:
            return .unscoped
        case .conjunction(let lhs, let rhs):
            if lhs.boolConstant == true {
                return negatedArchiveScope(from: rhs)
            }
            if rhs.boolConstant == true {
                return negatedArchiveScope(from: lhs)
            }
            if lhs.boolConstant == false || rhs.boolConstant == false {
                return .unscoped
            }
            return archiveScope(from: signature) == .unscoped ? .unscoped : .ambiguous
        case .disjunction(let lhs, let rhs):
            if lhs.boolConstant == false {
                return negatedArchiveScope(from: rhs)
            }
            if rhs.boolConstant == false {
                return negatedArchiveScope(from: lhs)
            }
            if lhs.boolConstant == true || rhs.boolConstant == true {
                return .unscoped
            }
            return archiveScope(from: signature) == .unscoped ? .unscoped : .ambiguous
        case .negation(let signature):
            return archiveScope(from: signature)
        }
    }

    private static func negatedEqualityArchiveScope(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> ArchiveScope {
        switch equalityArchiveScope(lhs, rhs) {
        case .scoped(let archived):
            return .scoped(!archived)
        case .unscoped:
            return .unscoped
        case .ambiguous:
            return .ambiguous
        }
    }

    private static func negatedInequalityArchiveScope(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> ArchiveScope {
        switch inequalityArchiveScope(lhs, rhs) {
        case .scoped(let archived):
            return .scoped(!archived)
        case .unscoped:
            return .unscoped
        case .ambiguous:
            return .ambiguous
        }
    }

    private static func mergeConjunctionArchiveScope(
        _ lhs: ArchiveScope,
        _ rhs: ArchiveScope
    ) -> ArchiveScope {
        switch (lhs, rhs) {
        case (.ambiguous, _), (_, .ambiguous):
            return .ambiguous
        case (.unscoped, let scope), (let scope, .unscoped):
            return scope
        case (.scoped(let lhs), .scoped(let rhs)):
            return lhs == rhs ? .scoped(lhs) : .ambiguous
        }
    }

    private static func mergeDisjunctionArchiveScope(
        _ lhs: ArchiveScope,
        _ rhs: ArchiveScope
    ) -> ArchiveScope {
        switch (lhs, rhs) {
        case (.ambiguous, _), (_, .ambiguous):
            return .ambiguous
        case (.unscoped, .unscoped):
            return .unscoped
        case (.scoped(let lhs), .scoped(let rhs)) where lhs == rhs:
            return .scoped(lhs)
        default:
            return .ambiguous
        }
    }

    private static func filter(from signature: CodexChatPredicateSignature) -> Self? {
        switch signature {
        case .bool(.key(.isArchived)):
            var filter = Self()
            filter.archived = true
            return filter
        case .bool(.bool(let value)):
            return Self(isComplete: value)
        case .bool:
            return nil
        case .negation(.bool(.key(.isArchived))):
            var filter = Self()
            filter.archived = false
            return filter
        case .negation(.bool(.bool(let value))):
            return Self(isComplete: value == false)
        case .negation:
            return nil
        case .equal(let lhs, let rhs):
            return equalityFilter(lhs, rhs)
        case .notEqual(let lhs, let rhs):
            return inequalityFilter(lhs, rhs)
        case .localizedStandardContains(let lhs, let rhs):
            return localizedContainsFilter(lhs, rhs)
        case .contains(let lhs, let rhs):
            return containsFilter(lhs, rhs)
        case .conjunction(let lhs, let rhs):
            if lhs.boolConstant == true {
                return filter(from: rhs)
            }
            if rhs.boolConstant == true {
                return filter(from: lhs)
            }
            if lhs.boolConstant == false || rhs.boolConstant == false {
                return Self(isComplete: false)
            }
            guard var lhsFilter = filter(from: lhs),
                let rhsFilter = filter(from: rhs),
                lhsFilter.merge(rhsFilter)
            else {
                return nil
            }
            return lhsFilter
        case .disjunction(let lhs, let rhs):
            if lhs.boolConstant == false {
                return filter(from: rhs)
            }
            if rhs.boolConstant == false {
                return filter(from: lhs)
            }
            if lhs.boolConstant == true || rhs.boolConstant == true {
                return Self()
            }
            return disjunctionFilter(lhs, rhs)
        }
    }

    private mutating func merge(_ other: Self) -> Bool {
        guard merge(&archived, other.archived),
            merge(&workspaces, other.workspaces),
            merge(&searchTerm, other.searchTerm),
            merge(&modelProviders, other.modelProviders),
            merge(&sourceKinds, other.sourceKinds)
        else {
            return false
        }
        isComplete = isComplete && other.isComplete
        return true
    }

    private func merge<Value: Equatable>(_ lhs: inout Value?, _ rhs: Value?) -> Bool {
        guard let rhs else {
            return true
        }
        guard let lhsValue = lhs else {
            lhs = rhs
            return true
        }
        return lhsValue == rhs
    }

    private static func equalityFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        switch (lhs, rhs) {
        case (.key(.isArchived), .bool(let value)), (.bool(let value), .key(.isArchived)):
            var filter = Self()
            filter.archived = value
            return filter
        case (.key(.workspaceID), .optionalWorkspaceID(.some(let id))),
            (.optionalWorkspaceID(.some(let id)), .key(.workspaceID)),
            (.key(.workspaceID), .workspaceID(let id)),
            (.workspaceID(let id), .key(.workspaceID)):
            var filter = Self()
            filter.workspaces = [URL(fileURLWithPath: id.rawValue, isDirectory: true)]
            return filter
        case (.key(.modelProvider), .optionalString(.some(let provider))),
            (.optionalString(.some(let provider)), .key(.modelProvider)),
            (.key(.modelProvider), .string(let provider)),
            (.string(let provider), .key(.modelProvider)):
            var filter = Self()
            filter.modelProviders = [provider]
            return filter
        case (.key(.sourceKind), .optionalSourceKind(.some(let sourceKind))),
            (.optionalSourceKind(.some(let sourceKind)), .key(.sourceKind)),
            (.key(.sourceKind), .sourceKind(let sourceKind)),
            (.sourceKind(let sourceKind), .key(.sourceKind)):
            var filter = Self()
            filter.sourceKinds = [sourceKind]
            filter.isComplete = sourceKind != .subAgent
            return filter
        default:
            return nilCheckFilter(lhs, rhs)
        }
    }

    private static func inequalityFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        switch (lhs, rhs) {
        case (.key(.isArchived), .bool(let value)), (.bool(let value), .key(.isArchived)):
            var filter = Self()
            filter.archived = !value
            return filter
        default:
            return nilCheckFilter(lhs, rhs)
        }
    }

    private static func nilCheckFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        switch (lhs, rhs) {
        case (.key(.workspaceID), .nilLiteral),
            (.nilLiteral, .key(.workspaceID)),
            (.key(.modelProvider), .nilLiteral),
            (.nilLiteral, .key(.modelProvider)),
            (.key(.sourceKind), .nilLiteral),
            (.nilLiteral, .key(.sourceKind)):
            return Self(isComplete: false)
        default:
            return nil
        }
    }

    private static func localizedContainsFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        guard lhs == .key(.searchableText),
            case .string(let searchTerm) = rhs
        else {
            return nil
        }
        return searchTerm.isEmpty ? Self() : Self(isComplete: false)
    }

    private static func containsFilter(
        _ lhs: CodexChatPredicateValue,
        _ rhs: CodexChatPredicateValue
    ) -> Self? {
        switch (lhs, rhs) {
        case (.stringArray(let values), .key(.modelProvider)):
            guard values.isEmpty == false else {
                return Self(isComplete: false)
            }
            var filter = Self()
            filter.modelProviders = values
            return filter
        case (.sourceKindArray(let values), .key(.sourceKind)):
            guard values.isEmpty == false else {
                return Self(isComplete: false)
            }
            var filter = Self()
            filter.sourceKinds = values
            filter.isComplete = values.contains(.subAgent) == false
            return filter
        case (.workspaceIDArray(let values), .key(.workspaceID)):
            guard values.isEmpty == false else {
                return Self(isComplete: false)
            }
            var filter = Self()
            filter.workspaces = values.map { URL(fileURLWithPath: $0.rawValue, isDirectory: true) }
            return filter
        default:
            return nil
        }
    }

    private static func disjunctionFilter(
        _ lhs: CodexChatPredicateSignature,
        _ rhs: CodexChatPredicateSignature
    ) -> Self? {
        guard let lhs = filter(from: lhs), let rhs = filter(from: rhs) else {
            return nil
        }
        var merged = Self(isComplete: lhs.isComplete && rhs.isComplete)
        if lhs.onlyHasSourceKinds, rhs.onlyHasSourceKinds {
            merged.sourceKinds = union(lhs.sourceKinds, rhs.sourceKinds)
            return merged
        }
        if lhs.onlyHasModelProviders, rhs.onlyHasModelProviders {
            merged.modelProviders = union(lhs.modelProviders, rhs.modelProviders)
            return merged
        }
        if lhs.onlyHasWorkspaces, rhs.onlyHasWorkspaces {
            merged.workspaces = union(lhs.workspaces, rhs.workspaces)
            return merged
        }
        return nil
    }

    private var onlyHasSourceKinds: Bool {
        sourceKinds != nil && archived == nil && workspaces == nil
            && searchTerm == nil && modelProviders == nil
    }

    private var onlyHasModelProviders: Bool {
        modelProviders != nil && archived == nil && workspaces == nil
            && searchTerm == nil && sourceKinds == nil
    }

    private var onlyHasWorkspaces: Bool {
        workspaces != nil && archived == nil && searchTerm == nil
            && modelProviders == nil && sourceKinds == nil
    }

    private static func union<Value: Hashable>(_ lhs: [Value]?, _ rhs: [Value]?) -> [Value]? {
        let values = (lhs ?? []) + (rhs ?? [])
        var seen: Set<Value> = []
        let unique = values.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }
}

private struct CodexChatExpression<Value: Sendable>: Sendable {
    var evaluate: @Sendable (CodexChatRecord) -> Value
    var signature: CodexChatPredicateValue
}

private enum CodexChatSequenceValue: Sendable {
    case strings([String])
    case workspaceIDs([CodexWorkspaceID])
    case sourceKinds([CodexThreadSourceKind])

    func contains(_ value: CodexChatPredicateValue) -> Bool {
        switch (self, value) {
        case (.strings(let values), .string(let value)):
            values.contains(value)
        case (.workspaceIDs(let values), .workspaceID(let value)):
            values.contains(value)
        case (.sourceKinds(let values), .sourceKind(let value)):
            values.contains(value)
        default:
            false
        }
    }
}

private struct CodexChatPredicateLowering: Sendable {
    var predicate: CodexThreadQueryPlan.RecordPredicate
    var signature: CodexChatPredicateSignature
}

private extension CodexChatPredicateSignature {
    var boolConstant: Bool? {
        guard case .bool(.bool(let value)) = self else {
            return nil
        }
        return value
    }

    var referencesSourceKind: Bool {
        switch self {
        case .bool(let value):
            value == .key(.sourceKind)
        case .equal(let lhs, let rhs),
            .notEqual(let lhs, let rhs),
            .localizedStandardContains(let lhs, let rhs),
            .contains(let lhs, let rhs):
            lhs == .key(.sourceKind) || rhs == .key(.sourceKind)
        case .conjunction(let lhs, let rhs), .disjunction(let lhs, let rhs):
            lhs.referencesSourceKind || rhs.referencesSourceKind
        case .negation(let predicate):
            predicate.referencesSourceKind
        }
    }
}

extension PredicateExpressions.Value: CodexChatRecordPredicateExpression where Output == Bool {
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let expression = try codexChatBoolExpression()
        return .init(predicate: expression.evaluate, signature: .bool(expression.signature))
    }
}

private protocol CodexChatRecordPredicateExpression {
    func codexChatRecordPredicate() throws -> CodexChatPredicateLowering
}

private protocol CodexChatRecordBoolExpression {
    func codexChatBoolExpression() throws -> CodexChatExpression<Bool>
}

private protocol CodexChatRecordStringExpression {
    func codexChatStringExpression() throws -> CodexChatExpression<String>
}

private protocol CodexChatRecordOptionalStringExpression {
    func codexChatOptionalStringExpression() throws -> CodexChatExpression<String?>
}

private protocol CodexChatRecordWorkspaceIDExpression {
    func codexChatWorkspaceIDExpression() throws -> CodexChatExpression<CodexWorkspaceID>
}

private protocol CodexChatRecordOptionalWorkspaceIDExpression {
    func codexChatOptionalWorkspaceIDExpression() throws -> CodexChatExpression<CodexWorkspaceID?>
}

private protocol CodexChatRecordSourceKindExpression {
    func codexChatSourceKindExpression() throws -> CodexChatExpression<CodexThreadSourceKind>
}

private protocol CodexChatRecordOptionalSourceKindExpression {
    func codexChatOptionalSourceKindExpression() throws -> CodexChatExpression<CodexThreadSourceKind?>
}

private protocol CodexChatRecordEquatableExpression {
    func codexChatEquatableExpression() throws -> CodexChatExpression<CodexChatPredicateValue>
}

private protocol CodexChatRecordSequenceExpression {
    func codexChatSequenceExpression() throws -> CodexChatExpression<CodexChatSequenceValue>
}

private protocol CodexChatRecordMembershipElementExpression {
    func codexChatMembershipElementExpression() throws -> CodexChatExpression<CodexChatPredicateValue>
}

private func makeCodexChatRecordPredicate(
    _ predicate: Predicate<CodexChat>
) throws -> CodexChatPredicateLowering {
    guard let expression = predicate.expression as? any CodexChatRecordPredicateExpression else {
        throw CodexFetchValidationError.unsupportedPredicate(
            String(reflecting: type(of: predicate.expression))
        )
    }
    return try expression.codexChatRecordPredicate()
}

extension PredicateExpressions.Conjunction: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordPredicateExpression, RHS: CodexChatRecordPredicateExpression
{
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let lhsPredicate = try lhs.codexChatRecordPredicate()
        let rhsPredicate = try rhs.codexChatRecordPredicate()
        return .init(
            predicate: { record in
                lhsPredicate.predicate(record) && rhsPredicate.predicate(record)
            },
            signature: .conjunction(lhsPredicate.signature, rhsPredicate.signature)
        )
    }
}

extension PredicateExpressions.Disjunction: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordPredicateExpression, RHS: CodexChatRecordPredicateExpression
{
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let lhsPredicate = try lhs.codexChatRecordPredicate()
        let rhsPredicate = try rhs.codexChatRecordPredicate()
        return .init(
            predicate: { record in
                lhsPredicate.predicate(record) || rhsPredicate.predicate(record)
            },
            signature: .disjunction(lhsPredicate.signature, rhsPredicate.signature)
        )
    }
}

extension PredicateExpressions.Negation: CodexChatRecordPredicateExpression
    where Wrapped: CodexChatRecordPredicateExpression
{
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let predicate = try wrapped.codexChatRecordPredicate()
        return .init(
            predicate: { record in
                predicate.predicate(record) == false
            },
            signature: .negation(predicate.signature)
        )
    }
}

extension PredicateExpressions.Equal: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordEquatableExpression, RHS: CodexChatRecordEquatableExpression
{
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let lhsExpression = try lhs.codexChatEquatableExpression()
        let rhsExpression = try rhs.codexChatEquatableExpression()
        return .init(
            predicate: { record in
                lhsExpression.evaluate(record)
                    .codexPredicateEquals(rhsExpression.evaluate(record))
            },
            signature: .equal(lhsExpression.signature, rhsExpression.signature)
        )
    }
}

extension PredicateExpressions.NotEqual: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordEquatableExpression, RHS: CodexChatRecordEquatableExpression
{
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let lhsExpression = try lhs.codexChatEquatableExpression()
        let rhsExpression = try rhs.codexChatEquatableExpression()
        return .init(
            predicate: { record in
                lhsExpression.evaluate(record)
                    .codexPredicateEquals(rhsExpression.evaluate(record)) == false
            },
            signature: .notEqual(lhsExpression.signature, rhsExpression.signature)
        )
    }
}

extension PredicateExpressions.StringLocalizedStandardContains: CodexChatRecordPredicateExpression
    where Root: CodexChatRecordStringExpression, Other: CodexChatRecordStringExpression
{
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let rootExpression = try root.codexChatStringExpression()
        let otherExpression = try other.codexChatStringExpression()
        return .init(
            predicate: { record in
                rootExpression.evaluate(record).localizedStandardContains(otherExpression.evaluate(record))
            },
            signature: .localizedStandardContains(rootExpression.signature, otherExpression.signature)
        )
    }
}

extension PredicateExpressions.SequenceContains: CodexChatRecordPredicateExpression
    where LHS: CodexChatRecordSequenceExpression, RHS: CodexChatRecordMembershipElementExpression
{
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let sequenceExpression = try sequence.codexChatSequenceExpression()
        let elementExpression = try element.codexChatMembershipElementExpression()
        return .init(
            predicate: { record in
                sequenceExpression.evaluate(record).contains(elementExpression.evaluate(record))
            },
            signature: .contains(sequenceExpression.signature, elementExpression.signature)
        )
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordBoolExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == Bool
{
    fileprivate func codexChatBoolExpression() throws -> CodexChatExpression<Bool> {
        if keyPath == \CodexChat.isArchived {
            return .init(evaluate: { $0.isArchived }, signature: .key(.isArchived))
        }
        throw CodexFetchValidationError.unsupportedPredicate(String(describing: keyPath))
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordPredicateExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == Bool
{
    fileprivate func codexChatRecordPredicate() throws -> CodexChatPredicateLowering {
        let expression = try codexChatBoolExpression()
        return .init(predicate: expression.evaluate, signature: .bool(expression.signature))
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordStringExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == String
{
    fileprivate func codexChatStringExpression() throws -> CodexChatExpression<String> {
        if keyPath == \CodexChat.searchableText {
            return .init(evaluate: { $0.searchableText }, signature: .key(.searchableText))
        }
        throw CodexFetchValidationError.unsupportedPredicate(String(describing: keyPath))
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordOptionalStringExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == String?
{
    fileprivate func codexChatOptionalStringExpression() throws -> CodexChatExpression<String?> {
        if keyPath == \CodexChat.modelProvider {
            return .init(evaluate: { $0.modelProvider }, signature: .key(.modelProvider))
        }
        throw CodexFetchValidationError.unsupportedPredicate(String(describing: keyPath))
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordOptionalWorkspaceIDExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == CodexWorkspaceID?
{
    fileprivate func codexChatOptionalWorkspaceIDExpression() throws -> CodexChatExpression<CodexWorkspaceID?> {
        if keyPath == \CodexChat.workspaceID {
            return .init(evaluate: { $0.workspaceID }, signature: .key(.workspaceID))
        }
        throw CodexFetchValidationError.unsupportedPredicate(String(describing: keyPath))
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordOptionalSourceKindExpression
    where Root == PredicateExpressions.Variable<CodexChat>, Output == CodexThreadSourceKind?
{
    fileprivate func codexChatOptionalSourceKindExpression() throws -> CodexChatExpression<CodexThreadSourceKind?> {
        if keyPath == \CodexChat.sourceKind {
            return .init(evaluate: { $0.sourceKind }, signature: .key(.sourceKind))
        }
        throw CodexFetchValidationError.unsupportedPredicate(String(describing: keyPath))
    }
}

extension PredicateExpressions.KeyPath: CodexChatRecordEquatableExpression
    where Root == PredicateExpressions.Variable<CodexChat>
{
    fileprivate func codexChatEquatableExpression() throws -> CodexChatExpression<CodexChatPredicateValue> {
        if Output.self == Bool.self {
            let expression = try (self as! PredicateExpressions.KeyPath<Root, Bool>)
                .codexChatBoolExpression()
            return .init(
                evaluate: { .bool(expression.evaluate($0)) },
                signature: expression.signature
            )
        }
        if Output.self == String?.self {
            let expression = try (self as! PredicateExpressions.KeyPath<Root, String?>)
                .codexChatOptionalStringExpression()
            return .init(
                evaluate: { .optionalString(expression.evaluate($0)) },
                signature: expression.signature
            )
        }
        if Output.self == CodexWorkspaceID?.self {
            let expression = try (self as! PredicateExpressions.KeyPath<Root, CodexWorkspaceID?>)
                .codexChatOptionalWorkspaceIDExpression()
            return .init(
                evaluate: { .optionalWorkspaceID(expression.evaluate($0)) },
                signature: expression.signature
            )
        }
        if Output.self == CodexThreadSourceKind?.self {
            let expression = try (self as! PredicateExpressions.KeyPath<Root, CodexThreadSourceKind?>)
                .codexChatOptionalSourceKindExpression()
            return .init(
                evaluate: { .optionalSourceKind(expression.evaluate($0)) },
                signature: expression.signature
            )
        }
        throw CodexFetchValidationError.unsupportedPredicate(String(describing: keyPath))
    }
}

extension PredicateExpressions.ForcedUnwrap: CodexChatRecordStringExpression
    where Inner: CodexChatRecordOptionalStringExpression, Wrapped == String
{
    fileprivate func codexChatStringExpression() throws -> CodexChatExpression<String> {
        let expression = try inner.codexChatOptionalStringExpression()
        return .init(
            evaluate: { record in
                guard let value = expression.evaluate(record) else {
                    preconditionFailure("CodexChat predicate force-unwrapped nil String.")
                }
                return value
            },
            signature: expression.signature
        )
    }
}

extension PredicateExpressions.ForcedUnwrap: CodexChatRecordMembershipElementExpression
    where Inner: CodexChatRecordEquatableExpression
{
    fileprivate func codexChatMembershipElementExpression() throws -> CodexChatExpression<CodexChatPredicateValue> {
        let expression = try inner.codexChatEquatableExpression()
        return .init(
            evaluate: { record in
                switch expression.evaluate(record) {
                case .optionalString(.some(let value)):
                    return .string(value)
                case .optionalWorkspaceID(.some(let value)):
                    return .workspaceID(value)
                case .optionalSourceKind(.some(let value)):
                    return .sourceKind(value)
                case .optionalString(.none),
                    .optionalWorkspaceID(.none),
                    .optionalSourceKind(.none):
                    return .nilLiteral("membership")
                default:
                    preconditionFailure("CodexChat predicate force-unwrapped an unsupported or nil membership value.")
                }
            },
            signature: expression.signature
        )
    }
}

extension PredicateExpressions.ForcedUnwrap: CodexChatRecordWorkspaceIDExpression
    where Inner: CodexChatRecordOptionalWorkspaceIDExpression, Wrapped == CodexWorkspaceID
{
    fileprivate func codexChatWorkspaceIDExpression() throws -> CodexChatExpression<CodexWorkspaceID> {
        let expression = try inner.codexChatOptionalWorkspaceIDExpression()
        return .init(
            evaluate: { record in
                guard let value = expression.evaluate(record) else {
                    preconditionFailure("CodexChat predicate force-unwrapped nil workspace ID.")
                }
                return value
            },
            signature: expression.signature
        )
    }
}

extension PredicateExpressions.ForcedUnwrap: CodexChatRecordSourceKindExpression
    where Inner: CodexChatRecordOptionalSourceKindExpression, Wrapped == CodexThreadSourceKind
{
    fileprivate func codexChatSourceKindExpression() throws -> CodexChatExpression<CodexThreadSourceKind> {
        let expression = try inner.codexChatOptionalSourceKindExpression()
        return .init(
            evaluate: { record in
                guard let value = expression.evaluate(record) else {
                    preconditionFailure("CodexChat predicate force-unwrapped nil source kind.")
                }
                return value
            },
            signature: expression.signature
        )
    }
}

extension PredicateExpressions.Value: CodexChatRecordBoolExpression where Output == Bool {
    fileprivate func codexChatBoolExpression() throws -> CodexChatExpression<Bool> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .bool(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordStringExpression where Output == String {
    fileprivate func codexChatStringExpression() throws -> CodexChatExpression<String> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .string(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordOptionalStringExpression
    where Output == String?
{
    fileprivate func codexChatOptionalStringExpression() throws -> CodexChatExpression<String?> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .optionalString(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordOptionalWorkspaceIDExpression
    where Output == CodexWorkspaceID?
{
    fileprivate func codexChatOptionalWorkspaceIDExpression() throws -> CodexChatExpression<CodexWorkspaceID?> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .optionalWorkspaceID(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordOptionalSourceKindExpression
    where Output == CodexThreadSourceKind?
{
    fileprivate func codexChatOptionalSourceKindExpression() throws -> CodexChatExpression<CodexThreadSourceKind?> {
        let value = value
        return .init(evaluate: { _ in value }, signature: .optionalSourceKind(value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordEquatableExpression {
    fileprivate func codexChatEquatableExpression() throws -> CodexChatExpression<CodexChatPredicateValue> {
        if Output.self == Bool.self {
            let value = value as! Bool
            return .init(evaluate: { _ in .bool(value) }, signature: .bool(value))
        }
        if Output.self == String?.self {
            let value = value as! String?
            return .init(evaluate: { _ in .optionalString(value) }, signature: .optionalString(value))
        }
        if Output.self == String.self {
            let value = value as! String
            return .init(evaluate: { _ in .string(value) }, signature: .string(value))
        }
        if Output.self == CodexWorkspaceID?.self {
            let value = value as! CodexWorkspaceID?
            return .init(
                evaluate: { _ in .optionalWorkspaceID(value) },
                signature: .optionalWorkspaceID(value)
            )
        }
        if Output.self == CodexWorkspaceID.self {
            let value = value as! CodexWorkspaceID
            return .init(evaluate: { _ in .workspaceID(value) }, signature: .workspaceID(value))
        }
        if Output.self == CodexThreadSourceKind?.self {
            let value = value as! CodexThreadSourceKind?
            return .init(
                evaluate: { _ in .optionalSourceKind(value) },
                signature: .optionalSourceKind(value)
            )
        }
        if Output.self == CodexThreadSourceKind.self {
            let value = value as! CodexThreadSourceKind
            return .init(evaluate: { _ in .sourceKind(value) }, signature: .sourceKind(value))
        }
        throw CodexFetchValidationError.unsupportedPredicate(String(describing: value))
    }
}

extension PredicateExpressions.Value: CodexChatRecordSequenceExpression {
    fileprivate func codexChatSequenceExpression() throws -> CodexChatExpression<CodexChatSequenceValue> {
        if let value = value as? [String] {
            return .init(evaluate: { _ in .strings(value) }, signature: .stringArray(value))
        }
        if let value = value as? [CodexWorkspaceID] {
            return .init(evaluate: { _ in .workspaceIDs(value) }, signature: .workspaceIDArray(value))
        }
        if let value = value as? [CodexThreadSourceKind] {
            return .init(evaluate: { _ in .sourceKinds(value) }, signature: .sourceKindArray(value))
        }
        throw CodexFetchValidationError.unsupportedPredicate(String(describing: value))
    }
}

extension PredicateExpressions.NilLiteral: CodexChatRecordEquatableExpression {
    fileprivate func codexChatEquatableExpression() throws -> CodexChatExpression<CodexChatPredicateValue> {
        .init(
            evaluate: { _ in .nilLiteral(String(describing: Wrapped.self)) },
            signature: .nilLiteral(String(describing: Wrapped.self))
        )
    }
}
