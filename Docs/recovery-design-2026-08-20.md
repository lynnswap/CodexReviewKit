# ReviewMonitor v0.6.2 recovery design (2026-08-20)

| Item | Value |
|---|---|
| Status | **Proposed — Phase 2 design gate approval pending** |
| Recovery base | `v0.6.2` / `82bddbcb1310a091eff742b36ab90781a4cbee5a` |
| Current-main evidence | `26c8f7b49e4afb356698d3c49e5107e96477b2ca` |
| Recovery branch | `codex/v0-6-2-recovery` |
| Parent issue | [#96](https://github.com/lynnswap/CodexReviewKit/issues/96) |
| Working ledger | [review-stability-recovery-2026-08-20.md](review-stability-recovery-2026-08-20.md) |
| Toolchain observed | Xcode 27.0 / Apple Swift 6.4; package language mode remains Swift 6 |

This document is the single source of truth for the recovery architecture. If
implementation requires a different owner, public contract, dependency
direction, persistence schema, or migration policy, update this document and
re-run the design gate before changing product code.

## 1. Scope contract

### Outcome

The recovery is complete when ReviewMonitor can run current Codex reviews while
its user-facing review identity, lifecycle, duration, history, and log remain
stable independently of transient app-server list/read behavior.

The concrete consumer stories are:

1. A ReviewMonitor user starts, watches, cancels, and revisits a review. One
   product review is always one sidebar row and one detail log.
2. After app restart, the same review title, lifecycle, duration, final result,
   and bounded log are restored without fetching the thread from app-server.
3. A Codex or Claude Code MCP client uses `review_start`, `review_await`,
   `review_read`, `review_list`, and `review_cancel` against the same product
   review/history owner as the UI.
4. A user can authenticate with current ChatGPT web login or an OpenAI API key,
   and ReviewMonitor can locate the installed Codex executable automatically.

### Compatibility policy

- The latest published release is v0.6.2. Its user-visible review behavior and
  published MCP field names are the compatibility baseline.
- The 519 commits after v0.6.2 have not been released. Their public-looking
  `CodexAppServerKit` / `CodexDataKit` products and main-only MCP renames are not
  compatibility obligations.
- Current Codex app-server wire behavior is a required external contract. Port
  the current terminal, notification, cancellation, and login semantics into
  the v0.6.2 product owners.
- Source-breaking removal of unreleased current-main architecture is allowed.
- The current ReviewMonitor home and preferences must remain recoverable during
  cutover. Migration is copy/import, never in-place reuse of the only source.
- Bottom status-accessory overlap is explicitly out of scope by user decision.

### Consumers

- `CodexReviewMonitor.app`: composition root and native AppKit consumer.
- `ReviewUI`: native review/history presentation.
- `CodexReviewMCPServer`: headless consumer of review commands and durable
  results/logs.
- Current Codex and Claude Code: external MCP clients discovered through the
  published tool schema.

There is no confirmed consumer of the unreleased generic Codex chat/DataKit
products. Do not create a proxy consumer to preserve them.

### Non-goals

- A general Codex thread/chat browser.
- Exposing reviewer, compact, spawn, or other internal subagent threads as
  standalone product rows.
- Recreating the current CodexDataKit fetched-results stack.
- CloudKit synchronization for review history.
- Persisting authentication secrets inside the review history database.
- Restoring post-v0.6.2 SDK/DocC products as part of runtime recovery.

## 2. Phase 1 evidence and numbered findings

### Baseline measurements

| Measurement | Current main | v0.6.2 recovery base |
|---|---:|---:|
| Swift source lines under `Sources` | 90,715 | 39,390 |
| `public` declarations/tokens | 1,467 | 334 |
| `package` declarations/tokens | 2,817 | 1,093 |
| `open` declarations/tokens | 109 | 4 |
| Library products | 8 | 4 |
| Regular/test targets | 20 | 13 |
| Largest host file | 4,173 lines | 2,129 lines |
| Largest sidebar controller | 2,418 lines | 2,680 lines |

The current architecture added more than 51,000 local source lines while moving
ReviewMonitor presentation from product reviews to generic app-server chats.
The recovery does not use line count as a quality metric; these measurements
show the migration scope that is deliberately not being carried forward.

### Findings

#### F1 — Product review membership has no durable owner (CONFIRMED)

Current sidebar membership comes from app-server `thread/list`, including
`.subAgentReview`. A live proof produced two rows for one review: the canonical
product run and the reviewer child. The child contains the expected structured
JSON and becomes a standalone generic row. Tracked by [#99](https://github.com/lynnswap/CodexReviewKit/issues/99).

#### F2 — Completed duration was replaced by thread recency (CONFIRMED)

v0.6.2 freezes `startedAt...endedAt`. Current main explicitly renders
`endedAt` as a relative date and its tests bless that contract. Persisted rows
without a live run lose lifecycle, symbol, title, and duration together. Tracked
by [#100](https://github.com/lynnswap/CodexReviewKit/issues/100).

#### F3 — Successful app-server refresh can delete a live/history row (CONFIRMED mechanism; reported disappearance trace PLAUSIBLE)

The live proof showed a newly started review omitted from the first 25-item
`thread/list` page and preserved only by a temporary live-chat rule. Terminal
MCP projection issued many `thread/list` refreshes, and successful partial pages
are committed as fetched-results membership. A later page can reinsert the row.
No fixed one-minute sidebar timer causes the recovery; the next successful list
or runtime re-install does. Tracked by [#102](https://github.com/lynnswap/CodexReviewKit/issues/102).

#### F4 — Runtime transitions intentionally clear all presentation (CONFIRMED)

Runtime close admission publishes `nil`, clears the model source, sets sidebar
sections to `[]`, and clears the detail log. Account changes, login
reconciliation, connection death, restart, and final stop all reach this path.
Durable product history must remain visible across these transport transitions.

#### F5 — Fetch and observation failures are silent (CONFIRMED)

Sidebar fetch catches every error without logging or UI state. Detail
observation failure clears content without a typed retryable error. Persistence
open/migration/commit/query failure must instead remain visible at its owner and
must not fall back to empty history.

#### F6 — Current crash report is unconfirmed; crash surfaces remain (PLAUSIBLE)

No current `.ips`, unified-log fatal, or live-probe process crash was found.
The generic chat projection still contains external-order-dependent
preconditions. Recovery removes that projection. Any future captured crash
sequence must be replayed at the ingestion owner before adding a guard.

#### F7 — v0.6.2 still has a current-toolchain log viewport failure (CONFIRMED)

Under Xcode 27, `detailLogKeepsBottomFilledForMultilineStreamDuringLiveWindowResize`
reproducibly loses bottom pinning at two checkpoints. Tracked by
[#103](https://github.com/lynnswap/CodexReviewKit/issues/103). This is separate
from persistence and the out-of-scope accessory overlap.

#### F8 — Current package tests have an API-key prompt lifecycle crash (CONFIRMED)

Current main's focused `addAccountAPIKeyPromptClearsSecretOnCancellation` test
cannot present the prompt and then trips its testing precondition. The API-key
feature must be reimplemented against the recovery owner and native lifecycle,
not copied wholesale. Tracked by [#97](https://github.com/lynnswap/CodexReviewKit/issues/97).

## 3. Target and product design

### Candidate A — Existing v0.6.2 targets plus SQLiteData-backed history (recommended)

Keep the released target graph. Add SQLiteData 1.9.0 only to the existing
`CodexReview` target and contain every SQLiteData/GRDB import under
`Sources/CodexReview/Persistence`.

Dependency evidence was checked at the signed
[SQLiteData 1.9.0 tag](https://github.com/pointfreeco/sqlite-data/tree/1.9.0)
(`97987458b49f0311717ecfbf7e8ac4c406afbf55`): Swift tools 6.1, Swift 6
language mode, macOS 13 minimum, MIT license, GRDB-backed transactions and
migrations, explicit database injection for fetches, and observable publishers
for UIKit-style native controllers. The runtime target also brings Point-Free
sharing/dependency/query support; this dependency cost is accepted only because
the recovery deletes the custom generic fetched-results architecture instead of
stacking SQLiteData beside it. CloudKit support is not enabled or used.

```text
CodexReviewMonitor.app (composition root)
    ├──▶ CodexReviewHost ───────▶ CodexReview
    │        ├──▶ CodexReviewAppServer ─▶ CodexReview
    │        └──▶ CodexReviewMCPServer ─▶ CodexReview
    └──▶ ReviewUI ──────────────▶ CodexReview

CodexReview ─▶ SQLiteData 1.9.0 ─▶ GRDB
```

Responsibilities, each stated as one sentence:

- `CodexReview`: owns the product review aggregate from command admission through durable history.
- `CodexReviewAppServer`: converts current Codex app-server wire behavior into
  typed product review events.
- `CodexReviewMCPServer`: exposes product review commands and history through
  the published MCP protocol.
- `CodexReviewHost`: owns the application runtime lifecycle.
- `ReviewUI`: renders observable product review/history state with AppKit.
- `CodexReviewTesting`: supplies deterministic backend fixtures that traverse
  the production review/history data flow.

Why no new persistence target:

- Every confirmed product consumer needs review history.
- A target split would require a new type-erased observation/commit bridge back
  into `CodexReview`, adding another lifecycle boundary without isolating
  SwiftPM dependency resolution.
- Types and access control can keep SQLiteData behind one owner inside the
  existing domain target.

### Candidate B — Direct GRDB adapter

Direct GRDB would reduce transitive dependencies and still provide migrations,
transactions, and value observation. It would require hand-written row/query
mapping and AppKit observation that SQLiteData already supplies.

This remains the fallback only if the first implementation probe shows that
SQLiteData cannot satisfy explicit database injection, commit-before-publish,
or deterministic AppKit observation under the repository flags.

### Candidate C — Repair current generic-chat/CodexDataKit architecture

Rejected. It retains app-server thread membership as UI state, keeps product
review identity split between run/chat/source kinds, and requires continued
fallbacks for missing live records. The confirmed symptoms are consequences of
that ownership model rather than isolated call-site defects.

### Decision

Adopt Candidate A with SQLiteData 1.9.0. Do not expose SQLiteData types in any
public signature and do not use its global default database. Inject the one
database connection explicitly at the ReviewMonitor composition root.

## 4. Owner map and lifecycle

### Target owner map

| Responsibility | Current-main owner/problem | Recovery owner |
|---|---|---|
| Product review ID | Run record plus source/reviewer chat IDs | `CodexReviewStore` allocates one stable review ID |
| Attempt identity | Multiple raw optional IDs | Review attempt value attached to one review ID |
| Live app-server I/O | AppServerKit/DataKit plus product adapters | `AppServerCodexReviewBackend` only |
| Notification semantics | Wire, DataKit, UI projections | Backend decoder/reducer boundary |
| Lifecycle/terminal | Run worker plus chat status/replay | One review processor and terminal commit |
| Persistence | None; app-server threads are re-fetched | `ReviewHistoryStore` local SQLite database |
| Log membership/order | Generic chat turn/item projection | Review history transaction sequence |
| Sidebar membership/order | Fetched app-server chats | Durable product review query |
| Detail content | Selected generic chat observation | Durable log query for selected review ID |
| Duration | Live run or generic recency fallback | Review start/end in durable run record |
| Selection | Generic chat ID | Product review ID |
| Render artifacts | Chat/document caches plus native views | Native snapshot/document diff rebuilt from history query |
| Authentication | Current runtime transition graph | Recovery auth owner plus current login/API-key adapters |
| Executable discovery | Current CodexKit helper | One composition-root resolver |

### Durable source of truth

The database owns the semantic state that must survive process or transport
loss. In-memory observable objects and native snapshots are projections that can
be rebuilt from the database.

The database contains three tables:

1. `reviewRuns`
   - stable review ID, session/workspace, target and target summary;
   - lifecycle/status, start/end, cancellation/failure, canonical final result;
   - current attempt and canonical outer/source/reviewer thread linkage;
   - model/account presentation metadata and ordering timestamps.
2. `reviewAttempts`
   - stable attempt ID and parent review ID;
   - source/review/turn identities, model, start/end, and terminal reason.
3. `reviewLogEntries`
   - stable entry ID, review/attempt ID, transaction sequence;
   - semantic kind, group/source item identity, append/replace behavior;
   - text, typed metadata payload, timestamp, and optional upstream event ID.

Foreign keys are enabled. `(reviewID, sequence)` is unique. Upstream event IDs,
when the contract provides them, have a uniqueness constraint scoped to the
attempt. Review history keeps the existing 256 KiB capped-log behavior per run;
rows removed or truncated by the semantic cap are changed in the same
transaction, so the durable store does not grow an unbounded hidden event log.

Authentication credentials are never columns or metadata payloads in this
database.

### Commit-before-publish flow

```text
App-server notification / UI or MCP command
    ↓
Typed ReviewMutation at the product boundary
    ↓
ReviewHistoryStore actor validates identity + applies one SQLite transaction
    ↓
Immutable committed ReviewHistoryCommit
    ├──▶ observable review/job projection (stable object identity)
    ├──▶ ReviewUI native rendering
    └──▶ MCP read/list/await result
```

- A semantic mutation is never published before its transaction commits.
- The single run processor supplies total order and awaits each history commit;
  fire-and-forget database writes are not allowed.
- The UI reads only committed query state. A transport failure does not replace
  that state with an empty result.
- Replayed events use stable attempt/event identity. If an upstream event has no
  stable identity, the decoder must define whether it is non-replayable rather
  than deduplicating by display text.

### Startup and shutdown

Startup order:

1. Resolve a recovery-owned database URL.
2. Open SQLite and run all versioned migrations.
3. Hydrate durable review/history queries.
4. Construct store/UI/MCP consumers with the same database owner.
5. Start the app-server runtime and live ingestion.

Shutdown order:

1. Close review admission and reject new work with a typed closed error.
2. Request active review cancellation as required by the stop purpose.
3. Wait for authoritative turn terminal or a typed connection terminal.
4. Commit final/incomplete lifecycle state and await all history writes.
5. Stop UI/MCP query subscriptions and rendering tasks.
6. Stop MCP HTTP/protocol requests.
7. Stop authentication/runtime consumers and app-server.
8. Close the database and release the owner.

`deinit` only cancels synchronous observation tokens as a backstop. It is not
the owner of async shutdown.

## 5. API-first sketch

The released v0.6.2 public review/MCP surface remains primary. Persistence is a
package implementation detail. New domain values cross actor boundaries as
immutable `Sendable` values.

```swift
package struct ReviewID: RawRepresentable, Hashable, Sendable, Codable {
    package let rawValue: String
}

package struct ReviewHistoryCommit: Sendable {
    package let review: ReviewJobSnapshot
    package let logChanges: [ReviewLogChange]
}

package enum ReviewHistoryMutation: Sendable {
    case create(ReviewCreation)
    case apply(ReviewEvent, attempt: ReviewAttemptID)
    case requestCancellation(ReviewCancellation)
    case finish(ReviewTerminal)
    case delete(ReviewID)
}

package actor ReviewHistoryStore {
    package init(database: any DatabaseWriter) throws
    package func apply(
        _ mutation: ReviewHistoryMutation,
        to reviewID: ReviewID
    ) async throws -> ReviewHistoryCommit
    package func snapshot() async throws -> ReviewHistorySnapshot
    package func close() async
}

@MainActor
@Observable
public final class CodexReviewStore {
    public private(set) var jobs: Set<CodexReviewJob> { get }
    public var orderedJobs: [CodexReviewJob] { get }
    public func start(forceRestartIfNeeded: Bool = false) async
    public func stop() async

    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) async throws -> CodexReviewAPI.Read.Result
    package func cancelReview(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome
}
```

`DatabaseWriter` is shown in the package-only initializer to clarify the
implementation contract; the concrete declaration imports it privately within
the persistence folder. No public API names SQLiteData or GRDB.

The observable `CodexReviewJob` instances are stable query projections. The
history owner updates an existing instance in place for the same review ID and
rebuilds them from SQLite at startup. The `jobs` collection is no longer an
independent mutable source of truth.

### Failure model

- Database open/migration/commit/query failures: typed persistence error,
  visible recovery UI, no empty-history fallback.
- Missing review/attempt/event identity: typed ingestion contract error at the
  decoder/processor boundary.
- App-server transport loss: current live attempt becomes failed/interrupted as
  the external contract dictates; committed history remains visible.
- Unknown/malformed notification: preserved diagnostic plus typed decoder
  failure; never fabricated success.
- Closed store/history: typed closed error for new work; repeated close is a
  documented no-op returning the same completion.

## 6. Consumer code

### Current-main presentation (rejected)

```swift
let results = modelContext.fetchedResults(for: genericChatDescriptor)
try await results.performFetch()
sidebar.apply(results.sections)

let selectedChat = modelContext.model(for: selectedChatID)
detail.observe(selectedChat)
```

This code lets partial app-server pages define product membership and gives an
internal reviewer child the same status as a review.

### Recovery presentation

```swift
let store = try CodexReviewStore.live(
    databaseURL: applicationSupportURL.appending(path: "review-history.sqlite")
)
try await store.loadHistory()

sidebar.bind(to: store.orderedJobs)
detail.bind(to: store.job(id: selection.reviewID))
```

The actual native controller continues to observe the stable store/job objects;
the difference is that membership/content are hydrated from committed history,
not app-server fetches.

### MCP consumer

```swift
let run = try await store.startReview(request)
let terminal = await store.waitForTerminalReview(id: run.id)
return ReviewStartResult(jobID: run.id, output: terminal.reviewText)
```

UI and MCP do not reconstruct terminal output independently.

## 7. Access control plan

### Keep public

- Existing v0.6.2 consumer types and commands needed by ReviewUI/MCP/tool app:
  `CodexReviewStore`, `CodexReviewJob`, `ReviewJobCore`, `ReviewLogEntry`, review
  target/request/result/error types, authentication/settings models.
- No new persistence API. Existing public raw String IDs remain source-compatible;
  package code converts them to the typed `ReviewID` at the boundary.

### Package/internal

- SQLite tables, migrations, database factory, row DTOs, mutation/commit values,
  writer actor, query subscriptions, import/migration helpers.
- App-server wire DTOs and notification reducers.
- Authentication provider adapters and executable candidate strategies.

### Remove or do not port

- `CodexAppServerKit`, `CodexAppServerKitTesting`, and `CodexDataKit` products.
- Generic Codex chat sidebar/detail types and source-kind presentation fallback.
- `ReviewChatLogUI` split introduced only for the unreleased generic-chat path.
- Any SQLiteData/GRDB re-export or public table/query wrapper.

All new declarations default to package/internal. Each public addition must be
reachable from the consumer code above.

## 8. Variation axes and addition tests

| Axis | Single absorption point | Variant addition test |
|---|---|---|
| Live / preview / test backend | `CodexReviewStoreBackend` composition | Add one backend implementation; no UI/store branch |
| ChatGPT / API key auth | authentication submission/provider owner | Add one provider case + adapter registration |
| App-server notification kind | backend decoder/reducer | Add one typed event handler; no UI/persistence decode |
| Review attempt generation | product review processor | Add restart attempt without creating a new review row |
| Live / preview / test database | composition-root database factory | Inject on-disk or temporary DB; no product branch |
| MCP identifier alias | MCP request decoder | Add alias at decoder only; core keeps `ReviewID` |
| Log presentation kind | `ReviewLogEntry.Kind` projection | Add kind + one renderer registration, not transport casts |

## 9. Deletion and cutover list

The recovery starts from v0.6.2, so deletion is primarily expressed as code
that is deliberately not ported:

- Do not port generic `CodexChat` sidebar/detail membership.
- Do not port `CodexModelContext` refresh/revalidation as review history.
- Do not port subagent source labels as review lifecycle inference.
- Do not port current-main relative `endedAt` timing.
- Do not port raw chat-log terminal projection or reviewer JSON fallbacks.
- Do not port current-main SDK target/package integration.

Within the recovery branch:

- Replace mutable `jobs` / `workspaces` source-of-truth storage with hydrated
  history projections.
- Replace UI/MCP terminal-result derivation with the one terminal commit.
- Replace swallowed persistence/fetch errors with typed visible state.
- Delete compatibility paths for retired app-server login/notification shapes
  once current contract fixtures and live probes pass.

## 10. Avoided shapes

- `thread/list` or `thread/read` as sidebar/detail source of truth.
- A second historical cache beside SQLite.
- Publishing a job/log mutation before its transaction commits.
- Fire-and-forget database writes or shutdown that only sends cancellation.
- JSON-content heuristics to distinguish reviewer output.
- Relative activity timestamps as review duration.
- A row-level guard that merely hides `.subAgentReview` while leaving no product
  history owner.
- SQLiteData property wrappers outside the persistence/query owner.
- A global default database accessed from arbitrary domain/UI call sites.
- Preview/test branches in production reducers or renderers.
- Fallback to empty history on database or observation error.

## 11. Test plan

### Characterization before migration

- v0.6.2 job-owned sidebar/detail and fixed duration.
- Human review output from `exitedReviewMode.review`.
- Current notification/terminal/cancellation/login fixtures captured from the
  source branches listed in issues #104–#107.
- Existing log truncation, append/replace, command panel, find, and scroll-tail
  behavior.

### Persistence contract (#102, #108)

- Fresh database, every schema migration, corrupted/incompatible database.
- Atomic run + log mutation, injected commit failure, process termination after
  each transaction boundary.
- Restart hydration with identical title/status/duration/result/log.
- Empty/partial app-server list while durable history remains unchanged.
- Duplicate/replayed event identity, sequence order, cap/truncation, deletion.
- Copy/import cutover leaves the current-main source untouched and is idempotent.

### App-server contract (#104–#107)

- Sparse and full terminal snapshots; missing final review fails visibly.
- Command/process/tool/file/reasoning event normalization and lossy UTF-8.
- Interrupt response/terminal races and cleanup ordering.
- Current ChatGPT login success, cancel, fallback, restart, and API key flow.

### Native UI (#99, #100, #103)

- Source plus reviewer child produces one product row and human detail output.
- Running timer freezes to start/end duration and remains fixed after time moves.
- Stable row/job native identity through history updates and app-server restart.
- Log tail pinning through append/reflow/resize; user scroll-away remains stable.
- Production observation/render completion, not sleep or queue-turn counts, is
  used as the test synchronization point.

### MCP and runtime (#109)

- All five tools from current Codex and Claude Code.
- Multiple sessions/reviews, cancel, long await, paged logs, stop/restart.
- Full package tests and ReviewMonitor app tests.
- Live normal, long-output, cancel, network-loss, login, restart, and persisted
  replay scenarios.
- Final branch-wide Codex review with no unresolved correctness findings.

## 12. Finding-to-design mapping

| Finding / issue | Recovery element |
|---|---|
| F1 / #99 | Product review ID + durable run query; child identity is internal only |
| F2 / #100 | Durable start/end fields and one duration projection |
| F3–F5 / #102 | SQLite owner, commit-before-publish, visible persistence errors |
| F6 | Remove generic chat projection; replay any captured sequence at ingestion owner |
| F7 / #103 | Native render completion and viewport contract |
| F8 / #97 | Reimplemented provider flow and native lifecycle tests |
| #98 | Composition-root executable resolver |
| #104 | Canonical terminal reducer and final result |
| #105 | Single notification normalization boundary |
| #106 | Authoritative terminal barrier before cleanup |
| #107 | App-server-owned callback/login completion |
| #108 | Copy/import cutover and rollback safety |
| #109 | Published MCP baseline plus evidence-driven aliases |

No numbered finding is intentionally left to the current generic-chat path.

## 13. Migration waves

Each wave is a separately committed, testable slice. A slice cuts over its
owner and removes the replaced path in the same slice.

1. **History foundation** — characterization tests, SQLiteData dependency,
   schema/migrations, commit/query owner, startup hydration (#102).
2. **Current event contract** — notification normalization and canonical
   terminal result committed to history (#104, #105).
3. **Lifecycle/cancellation** — authoritative terminal barrier and ordered
   shutdown (#106).
4. **Authentication/runtime discovery** — current ChatGPT flow, API key, and
   executable resolver (#97, #98, #107).
5. **Product UI/MCP cutover** — one review row/detail, fixed duration, viewport,
   published MCP contract (#99, #100, #103, #109).
6. **Safe state cutover and live proof** — copy/import migration, restart/replay,
   current-client/runtime matrix (#108).

Before starting each wave, record its file/time budget in the recovery ledger.
If one failure class needs three unsuccessful fixes or new guards begin to
multiply, freeze the slice and return to this design gate.

## 14. Acceptance criteria

- The recovery target graph remains the v0.6.2 graph; no generic DataKit/chat
  product is reintroduced.
- SQLiteData/GRDB imports exist only in the persistence folder.
- Sidebar/detail/MCP all read the same committed product review/history.
- App-server omission, restart, or connection loss never clears committed UI.
- One logical review has one ID/row, one lifecycle, one duration, and one final
  result; internal reviewer threads never become product rows.
- Completed duration is stable and logs survive app restart.
- Database and task close paths are awaited and leave no callback/write after
  close.
- Required issues #97–#100 and #102–#109 meet their acceptance criteria; #101
  remains explicitly out of scope.
- All new public declarations are justified by consumer code; all SQLite and
  wire implementation types remain package/internal.
- Package tests, app tests, migration tests, runtime scenarios, and Codex review
  are green.

## 15. Design gate decision

Approval of this document authorizes migration implementation on
`codex/v0-6-2-recovery`. It does not authorize push, PR creation, release, or
tag creation.
