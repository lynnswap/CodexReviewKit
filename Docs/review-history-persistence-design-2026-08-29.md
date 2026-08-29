# Review history persistence design (2026-08-29)

Status: Re-gated after adversarial review; implementation in progress

| Item | Value |
| --- | --- |
| Integration branch | `codex/persist-review-history` |
| Baseline | `22b1e975015b0bf24b45dad669a91c8b52fd8d2c` |
| Target base | `main` |
| Database framework | SQLiteData 1.11.2 |
| Package baseline | Swift tools 6.3 / Swift language mode 6 |
| Local validation toolchain | Xcode 27.0 / Swift 6.4 |
| CI compatibility toolchain | Latest stable Xcode 26 runner selected by `.github/workflows/ci.yml` |

This document is the design contract and progress ledger for durable ReviewMonitor
history. If implementation requires another owner, schema, lifecycle, failure
semantic, or MCP authorization policy, update this document before changing code.

## 1. Scope contract

### Outcome

ReviewMonitor restores application-wide review history after relaunch without
persisting the live transcript. A restored row preserves its review identity,
workspace and manual order, target, effective model, lifecycle, canonical result,
and structured findings. Selecting a restored review renders a compact detail from
those semantic fields.

The feature is complete when:

1. A succeeded, failed, or cancelled review remains one sidebar row after a clean
   app restart.
2. The row retains its target, model, exact known duration, terminal cause, final
   review, and findings.
3. A process-abandoned queued/running record is restored as
   `.interrupted(.previousProcessExit)` and never appears live or cancellable.
   Its unknown end time is not guessed.
4. History remains readable while the MCP runtime is starting, stopped, or failed.
5. A new MCP session cannot list, read, await, or cancel records restored from a
   previous process.
6. Database open, migration, decode, or write failure is visible at the Store
   boundary and blocks new review admission instead of silently using empty or
   non-durable history.
7. A rebuilt app passes an isolated end-to-end run: launch on a dedicated MCP
   port and history path, complete a real review, terminate, relaunch, and verify
   the restored sidebar/detail/findings state.

### Compatibility

- Keep the four existing library products and their public source surface.
- Keep the five MCP tool names, schemas, response fields, and session-local
  authorization behavior.
- No migration of a previously shipped review-history database is required; there
  is no current durable history owner.
- Current account/settings/runtime persistence remains unchanged.
- Local commits, push, and the requested Ready PR are authorized for this task.

### Non-goals

- Full transcript or app-server event replay.
- Cross-process review resumption from thread/turn identifiers.
- Reproducible source archives, working-tree snapshots, or diff storage.
- CloudKit synchronization.
- Persisting credentials, account secrets, raw JSON-RPC, reasoning, command output,
  tool results, developer diagnostics, or streaming deltas.
- Making previous-process history readable through a newly initialized MCP session.

## 2. Phase 1 findings at the baseline

### Measurements

- `CodexReview`: 225 `public`, 872 `package`, 8 `open` tokens.
- `CodexReviewHost`: 45 `public`, 99 `package`, 10 `open` tokens.
- `ReviewUI`: 9 `public`, 2 `package`, 2 `open` tokens.
- No `#if canImport` / `#if os` source gates.
- Relevant largest files before migration:
  - `LiveCodexReviewStoreBackend.swift`: 3,701 lines.
  - `CodexReviewStoreReviews.swift`: 2,685 lines.
  - `ReviewMonitorSidebarViewController.swift`: 2,672 lines.
  - `CodexReviewStore.swift`: 1,709 lines.
  - `CodexReviewJob.swift`: 1,004 lines.

### Numbered findings

#### F1 — Durable review membership has no owner (confirmed)

`CodexReviewStore` owns process-local workspaces/jobs and its seed contains only
account/settings state. Relaunch constructs a new Store with no review records.

#### F2 — The current aggregate mixes semantic state with transient projection (confirmed)

`CodexReviewJob` contains canonical lifecycle/output alongside raw log entries,
incremental message assembly, rendered text projections, log revisions, and mutation
hints. Encoding the class would persist duplicate and runtime-only state.

#### F3 — Exact review target is discarded after admission (confirmed)

The validated `Start.Request.target` reaches the worker, while the job retains only
`targetSummary`. History must record the typed validated target at admission; it
must not parse the display string later.

#### F4 — The current 256 KiB limit is not a durable log bound (confirmed)

The cap excludes multiple log kinds and metadata payloads. Persisting
`ReviewLogEntry` is not a bounded-history design.

#### F5 — The detail UI needs an explicit compact-history projection (confirmed)

The selected detail renders `job.logEntries`, while workspace findings render
`core.output.reviewResult`. Restored history must build a canonical final/error/
cancellation entry from semantic history rather than store rendered projections.

#### F6 — Runtime availability currently hides otherwise valid history (confirmed)

The sidebar selects its unavailable state before considering existing jobs when the
server is starting, stopped, or failed. Durable history must remain visible and use
the status accessory for runtime/history health.

#### F7 — MCP authorization and application history have different lifetimes (confirmed)

MCP read/list/cancel filter by the current transport session. Persisted history is
application-wide UI data and must restore with a non-live session identity.

#### F8 — The existing history URL helper is not an independent live seam (confirmed)

`PreparedRecoveryEnvironment.withHistoryDatabaseURL` belongs to an unused capability
graph that also owns a replacement Codex home, login staging, and saved accounts.
Activating the graph only for history would expand this change into runtime-home
migration. The history database therefore gets a dedicated Application Support
location owner, and the unused helper is removed so there is one live path owner.

## 3. Target graph and owner map

### Considered structures

1. **Internal `CodexReviewPersistence` target (selected).**
   It owns SQLiteData schema, migrations, queries, transactions, retention, and DB
   close. `CodexReview` owns the semantic port/records; `CodexReviewHost` owns the
   production URL and composition. This keeps SQLiteData out of domain and UI source.
2. Put SQLiteData inside `CodexReviewHost`.
   This avoids one target but adds schema/query ownership to the existing 3,701-line
   runtime adapter and cannot enforce the storage boundary.
3. Put SQLiteData inside `CodexReview`.
   This makes the semantic target own a concrete I/O framework and lets persistence
   types spread into the Store. It also makes preview/testing selection less explicit.

The selected same-package internal target is justified by a real outbound-adapter
dependency boundary. It is not a new product or separately versioned package.

```text
ReviewUI ───────────────────────────────▶ CodexReview
CodexReviewMCPServer ───────────────────▶ CodexReview
CodexReviewPersistence ─▶ CodexReview + SQLiteData
CodexReviewHost ─────────┬──────────────▶ CodexReview
                        └──────────────▶ CodexReviewPersistence
ReviewMonitor.app ─────────────────────▶ CodexReviewHost + ReviewUI
```

Responsibilities:

- `CodexReview`: owns live review semantics and the history persistence contract.
- `CodexReviewPersistence`: stores and restores semantic review records in SQLite.
- `CodexReviewHost`: supplies the owner-only production database location and concrete adapter.
- `ReviewUI`: renders Store state and forwards history deletion/reorder intent.
- `CodexReviewMCPServer`: keeps current-session authorization over Store commands.

### Resource lifecycle

```text
ReviewMonitor composition
  -> prepare owner-only Application Support directory
  -> construct ReviewHistoryDatabase with its exact URL
  -> inject persistence port into CodexReviewStore
  -> first Store load opens/migrates the explicit DatabasePool and orphan-finalizes history
  -> runtime starts
  -> review admission persists a running header before backend dispatch
  -> worker finalization commits terminal result + findings + retention
  -> application shutdown drains review workers
  -> Store synchronizes terminal snapshots and ordering
  -> history database closes
  -> application termination replies
```

Runtime restart/account switch does not close history. Application shutdown is a
separate Store operation from runtime `stop()`.

`CodexReviewStore` owns three internal linearization mechanisms:

- `HistoryStartReceipt` captures validated target, model, job/workspace order,
  session, and Store work admission before the start-header write. Pending receipts
  are visible to session/runtime close. After the write it revalidates the same
  receipt; stale starts are terminalized durably without backend dispatch.
- One `HistoryTerminalReceipt` per live job owns the first terminal snapshot and
  exactly one durable commit. Worker completion, cancel response, runtime detach,
  waiter resumption, and application shutdown join that receipt.
- `ReviewHistoryMutationCoordinator` executes database mutation and MainActor apply
  in one ordinal lane. Reorder, terminal retention, and explicit delete cannot
  apply results in a different order from their database commits.

## 4. Semantic surface

All new declarations are `package` unless an existing public API requires otherwise.
No SQLiteData or GRDB type appears outside `CodexReviewPersistence`.

```swift
package protocol ReviewHistoryPersistence: Sendable {
    func load(retentionPolicy: ReviewHistoryRetentionPolicy)
      async throws -> [RestoredReviewRecord]
    func recordStarted(_ record: StartedReviewRecord) async throws
    func recordTerminal(
      _ record: TerminalReviewRecord,
      retentionPolicy: ReviewHistoryRetentionPolicy
    ) async throws
      -> ReviewHistoryMutationResult
    func saveOrdering(_ ordering: ReviewHistoryOrdering) async throws
    func deleteTerminalReview(id: String) async throws
      -> ReviewHistoryMutationResult
    func deleteAllTerminalReviews() async throws
      -> ReviewHistoryMutationResult
    func close() async throws
}

package enum ReviewHistoryAvailability: Sendable, Equatable {
    case loading
    case available
    case failed(String)
    case closed
}

@MainActor
extension CodexReviewStore {
    package func deleteReviewHistory(id: String) async
    package func deleteAllReviewHistory() async
    public func shutdown() async
}
```

The persistence boundary has phase-specific immutable values:

- `StartedReviewRecord`: ID, cwd, workspace/job order, typed target, captured
  model, and non-optional start time.
- `TerminalReviewRecord`: ID, model, typed terminal, optional end time, summary,
  and completed-only canonical result/parsed projection.
- `RestoredReviewRecord`: one compatible started + terminal pair. An active row
  cannot be represented as a restored value.

The live SQLite implementation lazily constructs and then explicitly owns
`any DatabaseWriter` and close state. Production constructs `DatabasePool` from
the exact URL during the first load; tests inject
`DatabaseQueue`/`DatabasePool`. Do not use `prepareDependencies`,
`@Dependency(\.defaultDatabase)`, or SQLiteData `defaultDatabase(...)`.
`CodexReviewStore` remains `@MainActor`; only immutable Sendable records cross the
boundary. The Store-owned mutation lane retains every task/receipt and shutdown
joins them before close.

### Consumer path

Before:

```swift
let store = CodexReviewStore.makeLiveStore(...)
ReviewMonitorWindowController(store: store, ...)
```

After: construction stays unchanged. App termination calls the additive public
`store.shutdown()` instead of runtime-only `stop()`. `CodexReviewHost` composes the
database behind `makeLiveStore`, and `ReviewUI` continues to observe the Store.

## 5. Schema and invariants

SQLiteData `@Table` records are storage models, not the domain aggregate.

### `review_workspaces`

- `cwd` primary key
- `sortOrder`

### `review_records`

- stable review ID primary key
- `cwd` foreign key to workspace
- manual `sortOrder`
- typed target discriminator and variant payload
- captured/effective model
- lifecycle phase and typed terminal/cancellation/interruption fields
- `startedAt`, nullable `endedAt`, summary, canonical final review
- parsed-result state/source/parser version
- `terminalCommittedAt` and created/updated timestamps for deterministic retention

### `review_findings`

- stable finding ID primary key
- review ID foreign key with `ON DELETE CASCADE`
- ordinal, priority, title, body, path, start/end line
- unique `(reviewID, ordinal)`

Schema rules:

- `STRICT` tables, foreign keys, explicit indices, and versioned migrations.
- Published migrations are append-only; production never erases history on schema change.
- Active rows have no terminal payload. Terminal rows have one compatible typed terminal.
- Succeeded rows require non-empty canonical final review text no larger than the
  existing 256 KiB domain limit.
- Findings and parsed-result metadata are one transaction with terminal commit.
- The persistence port does not carry session IDs, thread/turn IDs, exit code,
  finding `rawText`, rendered projections, or raw log entries.
- Terminal mutation updates only terminal/result fields of an existing active row;
  it cannot overwrite cwd, target, or manual order.
- Restored rows derive display title, elapsed time, final flag, compact log entries,
  and other projections; those values are not columns.

### Retention

- Keep at most 50 terminal reviews per workspace and 500 terminal reviews globally.
- Prune oldest terminal reviews by `(terminalCommittedAt, id)` after terminal commit
  and at startup.
- The terminal transaction protects its current review ID from pruning so the
  completing API can always read its result.
- Never prune the current nonterminal rows.
- Return pruned IDs from the transaction so Store membership matches durable membership.
- Remove workspace rows that no longer own active or terminal reviews.
- No time-based expiry in v1.

## 6. Failure semantics

- Open/migration/load/decode failure: publish history `.failed`, retain the database,
  do not present empty history, continue runtime/auth/settings startup, reject new
  review admission with an explicit I/O error.
- Start-header write failure: do not dispatch a backend review or publish a live row.
- Session/runtime/application close during start-header suspension: the start receipt
  commits one typed requested-interruption terminal and dispatches no backend work.
- Terminal write failure: retain the current in-memory result, publish history
  `.failed`, let the already completed review return its real outcome, and reject
  subsequent starts until the next successful app launch.
- Delete/order failure: keep current durable membership/order, publish history
  `.failed`, and do not silently claim success.
- Close failure: publish/log the failure and complete application termination only
  after the close attempt returns.
- A queued/running row found at startup becomes
  `.interrupted(.previousProcessExit)` with unknown `endedAt`; UI must not show a
  running timer or invent an exact duration.
- Once public application shutdown enters `.closing`, `start` and `restart` cannot
  admit a new runtime. Repeated shutdown callers join the same terminal completion.

## 7. Variation points

| Axis | Absorption point | Variant test |
| --- | --- | --- |
| live / preview / test persistence | composition injects `ReviewHistoryPersistence` | add one adapter and one factory registration |
| storage implementation | the history port | replace SQLite adapter without editing Store/UI |
| target kind | typed target codec in persistence | add one target case and one codec/schema migration |
| terminal cause | existing `ReviewTerminalRecord` mapping | add one typed cause mapping and round-trip test |
| runtime availability | sidebar/status presentation | history membership remains independent of server state |

## 8. Deletions and avoided shapes

### Deletions

- Remove the unused `PreparedRecoveryEnvironment.withHistoryDatabaseURL` helper and
  its isolated test; the live history location has one dedicated owner.
- Remove no Store/MCP public behavior. Restored rows use semantic reconstruction,
  not a parallel UI-only history model.

### Avoided shapes

- Do not serialize `CodexReviewJob` or `ReviewLogEntry` wholesale.
- Do not call SQLiteData `@FetchAll` from `ReviewUI` leaf views.
- Do not add history operations to `CodexReviewStoreBackend`; runtime transport and
  durable history are independent variation axes.
- Do not reuse `writeDiagnosticsIfNeeded` as persistence. It is optional test
  diagnostics, catches write errors, and stores rendered/raw projections.
- Do not persist MCP session identity as future authorization.
- Do not use thread IDs as cross-process recovery tokens.
- Do not create an unowned database Task or rely on deinit for async close.
- Do not let the persistence executor serialize writes while MainActor applies their results
  independently; both halves belong to the Store history-mutation lane.
- Do not fall back to a second database path or recreate a corrupt database.

## 9. Test contract

### Persistence adapter

- fresh migration and schema constraints
- started/terminal round trip for every target and terminal variant
- findings transaction and cascade deletion
- startup orphan conversion with unknown end time
- per-workspace/global retention and returned pruned IDs
- invalid/incompatible row fails load without erasing data
- close rejects subsequent operations
- temporary-file and in-memory database configurations

### Store

- history loads once before accepting review starts
- start header is durable before backend dispatch
- blocked start revalidates exact session/work admission/model/order receipt before dispatch
- start failure prevents dispatch and row publication
- terminal persistence completes before waiter, cancel response, runtime detach, and worker result finalization
- persistence failure is visible and blocks later starts without changing the real terminal outcome
- restored rows remain inaccessible to a new MCP session
- clean shutdown synchronizes terminal rows/order and closes history after workers
- shutdown is one-shot and rejects concurrent restart/runtime acquisition
- delete updates database, Store membership, workspace membership, and selection source
- overlapping reorder/delete/terminal prune preserves identical DB and Store order/membership

### ReviewUI / app

- history remains visible for starting/stopped/failed server states
- restored success/failure/cancellation detail is non-empty
- terminal row with unknown end does not render a running timer
- history failure appears in the status presentation
- terminal context menu deletes; active context menu cancels
- composition uses the production history path while preview/tests use injected stores
- application termination awaits `shutdown()`

### Isolated application E2E

- Rebuild `CodexReviewMonitor.app` from the branch.
- Launch that binary with a dedicated MCP port, diagnostics file, and temporary
  history database path. Do not replace `HOME` or touch the user's production
  history database.
- The E2E-only overrides are explicit environment/argument inputs owned by the
  ReviewMonitor composition root: `REVIEW_MONITOR_TEST_PORT`,
  `REVIEW_MONITOR_TEST_CODEX_COMMAND`, `REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH`, and
  `REVIEW_MONITOR_TEST_HISTORY_PATH`. They are not production fallback paths.
- Call its real Streamable HTTP MCP endpoint and complete a review against this
  checkout.
- Terminate through `NSRunningApplication.terminate()` and wait for application
  shutdown completion.
- Relaunch the same binary with the same isolated history path.
- Verify diagnostics and visible UI show exactly one restored terminal row with
  target/model/status/final detail/findings and no command/reasoning transcript.
- Verify a newly initialized MCP session cannot list/read the restored row.
- Capture a screenshot of the restored sidebar/detail for the PR when the visible
  change is reviewable.

### Required gates

```bash
swift test --build-system swiftbuild --no-parallel
xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj \
  -scheme CodexReviewMonitor \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
scripts/check-compatibility.sh
git diff --check
```

Then run branch-wide local Codex review against `main` until it reports no findings.

## 10. Finding coverage

| Finding | Design response |
| --- | --- |
| F1 | One history port + SQLite owner + Store hydration |
| F2 | Storage records exclude job projection/runtime state |
| F3 | Started record stores the typed validated target |
| F4 | No generic log table; canonical result retains the existing hard bound |
| F5 | Restored compact semantic log projection |
| F6 | Sidebar membership independent of server availability |
| F7 | Restored non-live session identity and unchanged MCP filters |
| F8 | Dedicated Application Support owner; remove unused whole-environment helper |

## 11. Migration slices and progress

### Slice A — schema and adapter

Budget: 6 hours; at most 10 production and 4 test files.

- [x] Add SQLiteData dependency and internal target.
- [x] Add schema, migrations, codec, retention, close owner.
- [x] Pass focused persistence tests.

### Slice B — Store cutover

Budget: 8 hours; at most 12 production and 5 test files.

- [x] Add semantic port/records and injected disabled/test implementations.
- [x] Load history, persist start/terminal, synchronize ordering, and delete.
- [x] Add application shutdown separate from runtime stop.
- [x] Pass focused Store/MCP tests.

### Slice C — ReviewMonitor/UI composition

Budget: 5 hours; at most 8 production and 4 test files.

- [x] Compose production path/database.
- [x] Keep history visible during runtime failure.
- [x] Render history health and deletion semantics.
- [x] Pass focused ReviewUI/app tests.

### Slice D — integration and delivery

- [x] Run all repository gates.
- [ ] Run branch-wide local Codex review to clean.
- [x] Commit final fixes and verify clean worktree.
- [ ] Push branch and create Ready PR to `main`.

## 12. Acceptance remeasurement

At completion, record:

- final product/target graph from `swift package dump-package`;
- public/package/open distribution and any new public declarations;
- largest relevant files and `CodexReviewStore` stored-property change;
- remaining platform gates;
- the concrete path owner and DB close proof;
- old path/helper and alternate persistence routes removed;
- exact test/review results.

Completion remeasurement before publication:

- `swift package dump-package` confirms `CodexReviewPersistence` is internal and
  depends only on `CodexReview` and `SQLiteData`; `CodexReviewHost` composes it;
  `ReviewUI` has no persistence dependency.
- The only additive application-host surface is SPI
  `ApplicationHostSupport`: one-shot `CodexReviewStore.shutdown()`, explicit
  isolated-store factories, and the history-path test keys. The reviewed API
  baseline and checksum include those additions; the original public live-store
  factory is unchanged.
- Persistence behavior lives in `CodexReviewStoreHistory.swift` (760 lines) and
  the internal adapter/codec/schema files (444/479/290 lines). Store adds the
  availability, port, mutation-lane receipts, durable-ID sets, result leases, and
  one-shot shutdown state; it does not add a second UI model or log cache.
- Production owns
  `Application Support/CodexReviewMonitor/RecoveryV1/review-history.sqlite` via
  the retained Application Support/application/recovery capability chain. App
  termination cancels and joins launch, Store work, history receipts, database
  close, and directory close in that order. Runtime restart does not close it.
- The unused whole-recovery history URL helper is removed. There is no alternate
  persistence route, generic log table, raw transcript column, or SQLite import
  in `ReviewUI`.
- `swift test --build-system swiftbuild --no-parallel`, the locked app test gate
  (18 tests), all compatibility gates, schema/codec/retention tests, and the
  actual-app semantic/UI E2E pass. The E2E rebuilt the app, ran Codex 0.149.1,
  restored the same terminal job and `AccessGate.swift:3-3` finding after a clean
  restart, verified MCP-session isolation, and captured accessibility text plus a
  screenshot.
- The repo-standard app command without flags is blocked before compilation by
  local Xcode macro trust. CI/release/E2E use the committed workspace lock with
  automatic resolution disabled and `-skipMacroValidation`; the same app tests
  pass through that non-interactive path.
- A pre-existing live-runtime cleanup timeout can retire a long-lived MCP SSE
  session after the review has already committed. The E2E accepts curl status 18
  only when the same server remains running and the exact completed semantic row
  is present, then still verifies the database and restarted UI. Upstream Codex
  confirms review completion itself does not terminate app-server; this transport
  lifecycle is separate from durable-history ownership.
