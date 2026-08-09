# CodexDataKit

CodexDataKit provides SwiftData-style `@Observable` app-server backed models on top of `CodexAppServerKit`.

Use this product when app or UI code needs workspace group, workspace, and chat models without rendering directly from JSON-RPC payloads.

## Main Types

- `CodexModelContainer`: Associates a `CodexAppServer` with an eagerly created main-actor `CodexModelContext`.
- `CodexModelContext`: Fetches models, preserves model identity, and performs app-server actions for attached models.
- `CodexModelActor`, `CodexDefaultSerialModelExecutor`: Own a separate context graph on a serial model-actor executor.
- `CodexFetchDescriptor`: Value description of predicate, sort order, limit, offset, and context-change inclusion.
- `CodexFetchedResults`: The observable owner of query criteria, items, optional sections, cursors, typed phase, identity snapshot, and ordered transactions.
- `CodexFetchedResultsSnapshot`, `CodexFetchedResultsTransaction`: Section and item ID snapshots plus section/item changes suitable for conversion to native UI update APIs.
- `CodexPersistentModel`: SwiftData-style model protocol. The protocol itself is not main-actor isolated; concrete context ownership decides the isolation domain.
- `CodexWorkspaceGroup`, `CodexWorkspace`, `CodexChat`, `CodexTurn`, `CodexItem`: Observable model objects attached to a model context.
- `CodexQuery`: A SwiftUI `DynamicProperty` wrapper around `CodexFetchedResults`.
- `CodexFetchPhase`: The typed fetch state. Validation and app-server failures are carried by `CodexFetchFailure`.

## Quick Start

```swift
import CodexAppServerKit
import CodexDataKit

let appServer = try await CodexAppServer()
let container = CodexModelContainer(appServer: appServer)
let context = container.mainContext

let chats = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
try await chats.performFetch()

for chat in chats.items {
    print(chat.title)
}

await appServer.close()
```

The container does not take app-server close authority. `init(appServer:)` associates
a caller-managed server, and the owner that created that server remains responsible
for closing it. Internally, contexts retain a context-family coordinator rather than
the container facade, so retaining a context does not create a container/main-context
cycle or silently lose cross-context delivery.

## Fetching

Use `CodexFetchDescriptor` as the canonical query value:

```swift
let workspaceID = CodexWorkspaceID(rawValue: workspaceURL.standardizedFileURL.resolvingSymlinksInPath().path)
let descriptor = CodexFetchDescriptor<CodexChat>(
    predicate: #Predicate<CodexChat> { chat in
        chat.isArchived == false
            && chat.workspaceID == workspaceID
            && chat.searchableText.localizedStandardContains("review")
    },
    sortBy: [CodexSortDescriptor(\.recencyAt, order: .reverse)],
    fetchLimit: 50
)

let results = context.fetchedResults(
    for: descriptor,
    sectionedBy: .workspaceGroup
)
try await results.performFetch()
```

Sort descriptors use the known key-path contract directly. A key path must map to a
supported CodexDataKit model field; arbitrary key paths are not silently treated as
app-server sorts. Section descriptors support the same key-path style, plus
relationship aliases such as `.workspaceGroup` and `.workspace` for the common
sidebar groupings. Unsupported predicate, sort, section, model, limit, and offset
values fail through `CodexFetchFailure.validation` instead of trapping during query
construction or SwiftUI updates.

A nil chat predicate is the active-only convenience scope. An explicit predicate is
evaluated literally: if it does not mention `isArchived`, CodexDataKit fetches and
merges both active and archived server scopes. Add `chat.isArchived == false` when a
consumer wants active chats only.

Chat fetches include eligible context changes by default. A `CodexChat` created or actively observed by the
context remains eligible for fetch results when the app-server thread list
temporarily omits it, as long as the predicate can be decided locally. Set
`includeContextChanges` to `false` on `CodexFetchDescriptor`
when a fetch should report only the server-owned page membership.

Every effective local ordering ends with the model's typed ID in the primary sort
direction. The pinned app-server's `createdAt` and `updatedAt` cursors do not include
that tie-breaker, so those sorts enumerate the server through its stable `recencyAt`
cursor and then sort/page locally. A source-unconstrained fetch composes the
app-server's interactive-default listing with explicit user-visible noninteractive
source kinds; internal memory-consolidation sessions are not part of that default
membership. Because those partitions have no single server order, an empty `sortBy`
reconstructs the app-server default as `createdAt` descending with an ID tie-breaker
and pages locally after the merge. A complete query with one archived scope, one
primary `recencyAt` sort, and a positive fetch limit reads bounded prefixes from both
partitions before merging the requested page. Other composite orderings and
unbounded or incomplete queries enumerate the required partitions before local
sorting and paging. An explicit source predicate remains one source partition; it
uses direct server paging only when the predicate is complete, has one archived
scope, and uses empty sorting or one primary `recencyAt` sort.

Fetches preserve object identity. If the same app-server thread appears in a later refresh, CodexDataKit mutates the existing `CodexChat` instance instead of replacing it.

```swift
try await results.refresh()

if results.nextCursor != nil {
    try await results.loadNextPage()
}
```

Each `CodexFetchedResults` serializes fetch, refresh, pagination, and mutation-driven
reloads. A refresh rebuilds the currently loaded window in staging and commits items,
cursors, sections, and phase together. Cancelling a queued load removes it from the
queue; cancelling an in-flight load preserves the prior stable result and phase.
Queries stay live for mutations performed through the same model context. Changes
made by another process or app-server client require an explicit `refresh()`.

Use `registeredModel(for:)` when code needs only models that are already registered in
the context. This lookup does not create placeholder chats and does not issue an
app-server request.

```swift
if let chat = context.registeredModel(for: threadID) {
    render(chat.title)
}
```

`model(for: CodexThreadID)` remains the identity/placeholder API: it returns the
registered chat when present, or registers a placeholder `CodexChat` for that ID.
Workspace and workspace-group IDs also support `registeredModel(for:)` for symmetric
context identity lookups.

## Sectioning

Pass `sectionedBy` at the results/query boundary when a UI wants sidebar sections.

```swift
let workspaces = context.fetchedResults(
    for: CodexFetchDescriptor<CodexWorkspace>.workspaces,
    sectionedBy: .workspaceGroup
)

let chats = context.fetchedResults(
    for: CodexFetchDescriptor<CodexChat>(
        sortBy: [CodexSortDescriptor(\.updatedAt, order: .reverse)]
    ),
    sectionedBy: .workspace
)
```

Passing no section descriptor gives a single unsectioned result. Section identifiers stay typed as `CodexFetchSectionID`, so workspace and workspace-group sections can be used directly in UI selection state. Sectioning is a projection after global sorting, offset, and limit: section order follows each section's first item, and members preserve global relative order. A section key is not silently inserted as the primary sort.

## Fetched Results Transactions

Use `CodexFetchedResults` when non-SwiftUI UI code needs ordered changes instead of only the observable current value.

```swift
let results = context.fetchedResults(
    for: CodexFetchDescriptor<CodexChat>.recentChats,
    sectionedBy: .workspaceGroup
)

Task {
    for await transaction in results.transactions {
        apply(
            oldSnapshot: transaction.oldSnapshot,
            newSnapshot: transaction.newSnapshot,
            sectionChanges: transaction.sectionChanges,
            itemChanges: transaction.itemChanges
        )
    }
}

try await results.performFetch()
```

`CodexFetchedResults` is the single owner of both current values and transactions; there is no forwarding controller or second model graph. Snapshots contain section IDs, optional titles, and item IDs only; section and item changes are ordered and include insert, delete, move, and update cases. The transaction stream buffers only the newest transaction. Every transaction carries complete old and new identity snapshots, so a consumer whose current snapshot no longer equals `oldSnapshot` replaces it with `newSnapshot` instead of replaying stale granular changes.

CodexDataKit does not import AppKit, UIKit, or SwiftUI for this API. Convert `CodexFetchedResultsTransaction` into `NSCollectionView`, `UICollectionView`, diffable data source, or `NSOutlineView` updates in the UI layer. Detail transcript streams remain the responsibility of `CodexChat.observe()`.

## Models

Models are context-attached observable objects:

```swift
let workspace = try await context.fetch(CodexFetchDescriptor<CodexWorkspace>.workspaces).first
let chat = try await workspace?.startChat()
try await chat?.send("Explain the latest diff.")
```

Attached models expose their context for identity and model operations. App-server
lifecycle remains owned by the composition root, not by a model:

```swift
let sameContext = chat?.modelContext === context
print(sameContext)
```

Each CodexDataKit model graph is owned by the context that vended it. The container
eagerly creates its UI-facing `mainContext`, similar to SwiftData's
`ModelContainer.mainContext`. A `CodexModelActor` creates a separate context through
`CodexDefaultSerialModelExecutor`; its actor-isolated `modelContext` is the only
mutation entry point for that graph.

```swift
actor IndexWorker: CodexModelActor {
    nonisolated let modelContainer: CodexModelContainer
    nonisolated let modelExecutor: CodexDefaultSerialModelExecutor

    init(container: CodexModelContainer) {
        modelContainer = container
        modelExecutor = CodexDefaultSerialModelExecutor(modelContainer: container)
    }

    func recentChatIDs() async throws -> [CodexThreadID] {
        try await modelContext.fetch(
            CodexFetchDescriptor<CodexChat>.recentChats
        ).map(\.id)
    }
}
```

Treat these instances like Core Data or SwiftData model objects: keep them inside
their vending context, mutate same-identity objects in place, and pass semantic IDs
or value DTOs across concurrency domains. Main and model-actor contexts own distinct
instances and merge supported changes by semantic identity; they never share a
mutable model object. Do not make UI-owned mirrors of model properties just to
observe changes.

Keep review-specific state, parsed findings, and review timelines outside CodexDataKit. CodexDataKit owns generic Codex app-server data models; higher-level packages can layer their own indices on top of `CodexChat.id`, workspace IDs, or sectioned fetch results.

When a consumer needs the canonical transcript for one loaded turn, use
`chat.transcript(in:)`. This projection is built by the chat owner from the
context's current items; consumers do not reconstruct `CodexThreadItem` values
or invent a separate output cache.

CodexDataKit preserves every raw review rollout item while normalizing
the app-server's live and persisted companion assistant representations to
`CodexThreadItem.SemanticRelation.companionOf(.exitedReviewMode)`. Renderers use
that relation instead of inferring review identity from item text, turn
adjacency, or the top-level thread source. Persisted review rollouts may retain
the client source that initiated them.

## Live Chat Observation

Use `CodexChat.observe()` or `CodexModelContext.observe(_:)` when a detail view needs an immutable transcript projection followed by live app-server updates.

```swift
let chat = context.model(for: CodexThreadID(rawValue: "thread-1"))
let observation = try await context.observe(chat)

for await event in observation.updates {
    switch event.payload {
    case .snapshot(let snapshot, _):
        projection.replace(with: snapshot)
    case .update(let update):
        projection.apply(update)
    }
}

await observation.close()
```

Observation first refreshes or seeds the chat with `includeTurns: true`, then consumes `CodexThread.events`. Turn, item, message, delta, usage, completion, and failure events still mutate the context-owned model graph, but that graph is not the presentation baseline. `CodexItem.id` is the stable model identity; `CodexItem.itemID` keeps the raw app-server item ID.

Each observation owns one subscriber lease and one iterator. The first event is a complete immutable snapshot. Later events carry a `(generation, sequence)` cursor and either a self-contained update or another complete snapshot barrier. Apply updates only to the immediately preceding projection; a snapshot replaces the projection and covers every event through its cursor. A second consumer must call `observe()` again instead of creating a second iterator from the same `updates` value.

Item removal and text-append updates use `CodexChatItemLocator`, whose turn ID, item kind, and raw item ID match DataKit's semantic merge key. Do not locate those targets by raw item ID alone because distinct item kinds can legally share that wire ID.

`CodexChatObservation.chat` remains the context-owned semantic action and identity handle. Do not reread it to apply an update: the graph may already contain later mutations. Keep selection state as semantic IDs and build app-specific presentation state only from event payloads. `CodexChatUpdate.affectedTurnID` can scope update handling after the projection has validated and applied the event cursor.

Subscriber queues are bounded. A slow subscriber receives a complete `.bufferOverflow` snapshot instead of an unbounded delta backlog. An observation handle retains its context while the handle is alive, so its stream never silently outlives the mutation owner. Explicit `close()` finishes that subscriber and waits for its lease release; closing the last lease also cancels and joins the shared upstream pump. Iterator task cancellation releases the same lease. Deinitialization only signals release and cannot await pump completion, so lifecycle owners should call and await `close()` during normal teardown.

CodexDataKit may read app-server thread snapshots internally to establish or reconcile the current value. Those reads are not part of the observation stream. Once live events have advanced an observed chat, later thread reads are merged into the existing model and must not rewind already-applied live turns or items unless an explicit model operation such as rollback requests replacement.

When a higher-level package persists an app-specific operation identity, keep that identity outside CodexDataKit. Resolve it to the app-server thread ID at that layer, then observe the generic chat model:

```swift
let chat = context.model(for: operation.threadID)
let observation = try await chat.observe()
```

## SwiftUI

Install the container or context in the environment, then use `@CodexQuery` in views.

```swift
import SwiftUI
import CodexDataKit

struct Sidebar: View {
    @CodexQuery(
        sort: \.updatedAt,
        order: .reverse,
        sectionBy: .workspaceGroup
    )
    private var chats

    var body: some View {
        List {
            ForEach(chats.sections) { section in
                Section(section.title ?? "") {
                    ForEach(section.items) { chat in
                        Text(chat.title)
                    }
                }
            }
        }
    }
}

Sidebar()
    .codexModelContainer(container)
```

## Testing

Use `CodexAppServerKitTesting` to test CodexDataKit owners without a real app-server process.

```swift
import CodexAppServerKitTesting
import CodexDataKit
import Testing

@MainActor
@Test func loadsChats() async throws {
    let runtime = try await CodexAppServerTestRuntime.start(threads: [])

    let container = CodexModelContainer(appServer: runtime.server)
    let context = container.mainContext
    let results = context.fetchedResults(for: CodexFetchDescriptor<CodexChat>.recentChats)
    try await results.performFetch()

    #expect(results.items.isEmpty)
    await runtime.close()
}
```

Use `CodexAppServerTestStoredThread` when a test needs nonempty results. The
fixture owns the complete current-v2 thread/turn wire value and validates its
`CodexThreadSnapshot` projection instead of re-encoding production models.

For lower-level app-server APIs, see [../CodexAppServerKit/README.md](../CodexAppServerKit/README.md).
