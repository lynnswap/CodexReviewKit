import Foundation
import SwiftUI

extension EnvironmentValues {
    @Entry public var codexModelContext: CodexModelContext? = nil
}

extension View {
    public func codexModelContainer(_ container: CodexModelContainer) -> some View {
        environment(\.codexModelContext, container.mainContext)
    }

    public func codexModelContext(_ context: CodexModelContext) -> some View {
        environment(\.codexModelContext, context)
    }
}

public struct CodexQueryResults<Model: CodexPersistentModel>: RandomAccessCollection {
    public typealias Index = Array<Model>.Index
    public typealias Element = Model

    public var items: [Model]
    public var sections: [CodexFetchSection<Model>]
    public var phase: CodexFetchPhase

    public init(
        items: [Model] = [],
        sections: [CodexFetchSection<Model>] = [],
        phase: CodexFetchPhase = .idle
    ) {
        self.items = items
        self.sections = sections
        self.phase = phase
    }

    public var startIndex: Index {
        items.startIndex
    }

    public var endIndex: Index {
        items.endIndex
    }

    public subscript(position: Index) -> Model {
        items[position]
    }
}

@MainActor
@propertyWrapper
public struct CodexQuery<Model: CodexPersistentModel>: @preconcurrency DynamicProperty {
    @Environment(\.codexModelContext) private var modelContext
    @State private var fetchedResults: CodexFetchedResults<Model>?
    private let fetchDescriptor: CodexFetchDescriptor<Model>
    private let sectionBy: CodexSectionDescriptor<Model>?

    public init(
        _ descriptor: CodexFetchDescriptor<Model> = .init(),
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.fetchDescriptor = descriptor
        self.sectionBy = sectionBy
    }

    public init(
        filter: Predicate<Model>? = nil,
        sort: [CodexSortDescriptor<Model>] = [],
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.fetchDescriptor = CodexFetchDescriptor(
            predicate: filter,
            sortBy: sort
        )
        self.sectionBy = sectionBy
    }

    public init<Value: Comparable>(
        filter: Predicate<Model>? = nil,
        sort keyPath: KeyPath<Model, Value> & Sendable,
        order: SortOrder = .forward,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.init(
            filter: filter,
            sort: [CodexSortDescriptor(keyPath, order: order)],
            sectionBy: sectionBy
        )
    }

    public init<Value: Comparable>(
        filter: Predicate<Model>? = nil,
        sort keyPath: KeyPath<Model, Value?> & Sendable,
        order: SortOrder = .forward,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.init(
            filter: filter,
            sort: [CodexSortDescriptor(keyPath, order: order)],
            sectionBy: sectionBy
        )
    }

    public init(
        filter: Predicate<Model>? = nil,
        sort keyPath: any KeyPath<Model, String> & Sendable,
        comparator: String.StandardComparator = .localizedStandard,
        order: SortOrder = .forward,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.init(
            filter: filter,
            sort: [CodexSortDescriptor(
                keyPath,
                comparator: comparator,
                order: order
            )],
            sectionBy: sectionBy
        )
    }

    public init(
        filter: Predicate<Model>? = nil,
        sort keyPath: any KeyPath<Model, String?> & Sendable,
        comparator: String.StandardComparator = .localizedStandard,
        order: SortOrder = .forward,
        sectionBy: CodexSectionDescriptor<Model>? = nil
    ) {
        self.init(
            filter: filter,
            sort: [CodexSortDescriptor(
                keyPath,
                comparator: comparator,
                order: order
            )],
            sectionBy: sectionBy
        )
    }

    public var wrappedValue: CodexQueryResults<Model> {
        guard let fetchedResults else {
            return CodexQueryResults()
        }
        return CodexQueryResults(
            items: fetchedResults.items,
            sections: fetchedResults.sections,
            phase: fetchedResults.phase
        )
    }

    public mutating func update() {
        guard let modelContext else {
            preconditionFailure(
                "CodexQuery requires a CodexModelContext in the SwiftUI environment."
            )
        }

        if let fetchedResults,
           fetchedResults.modelContext === modelContext,
           fetchedResults.querySignature == fetchDescriptor.querySignature,
           fetchedResults.sectionBy == sectionBy {
            return
        }

        let results = modelContext.fetchedResults(for: fetchDescriptor, sectionedBy: sectionBy)
        fetchedResults = results
        Task {
            try? await results.performFetch()
        }
    }
}
