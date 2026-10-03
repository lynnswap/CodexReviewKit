# Review history persistence design

Design and validation record begun on 2026-08-29. The measurements and delivery
status below belong to that implementation, not the current checkout. See
[architecture.md](architecture.md) for the current target structure.

| Item | Recorded value |
| --- | --- |
| Status | Re-gated after adversarial review; implementation in progress |
| Integration branch | `codex/persist-review-history` |
| Baseline | `22b1e975015b0bf24b45dad669a91c8b52fd8d2c` |
| Target base | `main` |
| Database framework | SQLiteData 1.11.2 |
| Package baseline | Swift tools 6.3 / Swift language mode 6 |
| Local validation | Xcode 27.0 / Swift 6.4 |
| CI compatibility | Latest stable Xcode 26 runner selected by `.github/workflows/ci.yml` |

## What history preserves

ReviewMonitor restores review history after relaunch. Each row keeps its ID,
workspace, manual order, typed target, effective model, lifecycle, final review,
and structured findings. The detail view derives a compact display from those
fields. Transcripts stay in memory.

Manual review order applies across the app. A repository section can combine a
primary checkout with linked worktrees, while each review keeps its original
`cwd`. Existing databases migrate by sorting workspaces first, then the previous
workspace-local review order, preserving the visible order.

Acceptance requires:

1. A completed, failed, or cancelled review returns as one sidebar row after a
   clean restart, with its target, model, known duration, terminal cause, result,
   and findings.
2. A queued or running row left by the previous process becomes
   `.interrupted(.previousProcessExit)`. It has no invented end time and cannot
   appear live or cancellable.
3. History stays readable while the MCP runtime starts, stops, or fails. A new
   MCP session cannot list, read, await, or cancel previous-process records.
4. Database open, migration, decode, and write failures are visible at the store
   and block new review admission. The database is retained.
5. An isolated app E2E run completes a real review, terminates, relaunches, and
   verifies the restored sidebar, detail, and findings.

The four library products and their public source surface stay compatible, as
do the five MCP tool names, schemas, response fields, and session access rules.
Account, settings, and runtime persistence stay unchanged. At the baseline,
there was no shipped history database requiring migration. The original task
also authorized local commits, push, and a Ready PR.

History excludes transcripts, raw JSON-RPC, reasoning, command output, tool
results, diagnostics, streaming deltas, credentials, account secrets, finding
`rawText`, and rendered projections. This work does not add event replay,
cross-process review resumption, source archives, working-tree snapshots,
diffs, or CloudKit synchronization. Thread and turn IDs cannot authorize or
resume a review after relaunch.

## Problems at the baseline

| Finding | Problem | Design response |
| --- | --- | --- |
| F1 | Store seeds contain accounts and settings, but no durable review membership | Load records through a history port and SQLite adapter |
| F2 | `CodexReviewJob` mixes results with logs, message assembly, rendering, revisions, and mutation hints | Persist semantic records instead of encoding the job |
| F3 | Admission passes the typed target to the worker but retains only `targetSummary` | Store the validated target without parsing its display text |
| F4 | The 256 KiB cap excludes some log kinds and metadata | Keep the final-result bound; omit a generic log table |
| F5 | Detail reads `job.logEntries`, while findings read `core.output.reviewResult` | Derive compact final, error, or cancellation entries from history |
| F6 | Sidebar runtime-unavailable state hides existing jobs | Keep history visible and show runtime health in the status accessory |
| F7 | MCP sessions and app history have different lifetimes | Restore rows with a non-live session identity and keep MCP filters |
| F8 | `PreparedRecoveryEnvironment.withHistoryDatabaseURL` also depends on replacement-home, login, and account staging | Give history its own Application Support location and remove the unused helper |

Recorded source measurements:

| Target | `public` | `package` | `open` |
| --- | ---: | ---: | ---: |
| `CodexReview` | 225 | 872 | 8 |
| `CodexReviewHost` | 45 | 99 | 10 |
| `ReviewUI` | 9 | 2 | 2 |

There were no `#if canImport` or `#if os` source gates. The largest relevant files
were `LiveCodexReviewStoreBackend.swift` (3,701 lines),
`CodexReviewStoreReviews.swift` (2,685),
`ReviewMonitorSidebarViewController.swift` (2,672),
`CodexReviewStore.swift` (1,709), and `CodexReviewJob.swift` (1,004).

## Owners and dependencies

`CodexReviewPersistence` is an internal target in the same package. It owns
SQLiteData schema, migrations, queries, transactions, retention, and close.
`CodexReview` defines the records and persistence interface, and
`CodexReviewHost` supplies the production location and adapter. This keeps
SQLiteData out of the store and UI without adding a product or versioned package.

Putting storage in `CodexReviewHost` would add schema and query work to the
3,701-line runtime adapter. Putting it in `CodexReview` would couple review
behavior to concrete database I/O and make preview and test selection less clear.

```text
ReviewUI ───────────────────────────────▶ CodexReview
CodexReviewMCPServer ───────────────────▶ CodexReview
CodexReviewPersistence ─▶ CodexReview + SQLiteData
CodexReviewHost ─────────┬──────────────▶ CodexReview
                        └──────────────▶ CodexReviewPersistence
ReviewMonitor.app ─────────────────────▶ CodexReviewHost + ReviewUI
```

| Owner | Responsibility |
| --- | --- |
| `CodexReview` | Live review behavior, app-wide manual order, and history contract |
| `CodexReviewPersistence` | Save and restore review records in SQLite |
| `CodexReviewHost` | Owner-only database location and live adapter |
| `ReviewUI` | Render store state, group repository sections, and pass workspace scope for deletion and reordering |
| `CodexReviewMCPServer` | Restrict commands to the current session |

Update this design before changing an owner, schema, lifecycle, failure
behavior, or MCP access policy.

### Lifetime and write order

At composition, the host prepares the owner-only Application Support directory
and injects a database with its exact URL. The first store load opens and
migrates the database, finalizes abandoned rows, and restores history before
accepting reviews. Admission saves a start header before dispatching backend
work. Finalization saves the terminal result, findings, and retention changes
in one transaction.

Application shutdown drains workers, synchronizes terminal snapshots and order,
then closes the database before replying to termination. Runtime `stop()`,
restart, and account switching leave history open.

The store coordinates three kinds of work:

- `HistoryStartReceipt` captures target, model, job and workspace order, session,
  and admission before the write. Session and runtime close can see pending
  receipts. After saving, the store rechecks the receipt; a stale request gets a
  durable terminal result without backend dispatch.
- `HistoryTerminalReceipt` holds the first terminal snapshot and one commit per
  live job. Worker completion, cancellation responses, runtime detach, waiters,
  and shutdown all wait for that commit.
- `ReviewHistoryMutationCoordinator` runs each database mutation and its
  MainActor state change in the same order. Reorder, retention, and deletion
  therefore update the store in database commit order.

The store retains those tasks and receipts until shutdown has waited for them.
Database writes alone cannot establish this ordering if their results are
applied independently on the MainActor.

## Persistence interface

New declarations use `package` access unless an existing public API requires
otherwise. SQLiteData and GRDB types stay in `CodexReviewPersistence`.

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
    package func reorderJob(
      id: String,
      inWorkspaces cwds: Set<String>,
      before nextJobID: String?
    ) async -> Bool
    public func shutdown() async
}
```

Immutable Sendable values cross this interface:

| Record | Contents |
| --- | --- |
| `StartedReviewRecord` | ID, cwd, workspace and job order, typed target, captured model, non-optional start time |
| `TerminalReviewRecord` | ID, model, typed terminal, optional end time, summary, and completed-only final result and parsed findings |
| `RestoredReviewRecord` | A compatible start and terminal pair; active rows cannot form this value |

The live adapter lazily creates and owns `any DatabaseWriter` and its close
state. Production opens a `DatabasePool` at the supplied URL on first load;
tests can inject a `DatabaseQueue` or `DatabasePool`. It does not use
`prepareDependencies`, `@Dependency(\.defaultDatabase)`, or SQLiteData
`defaultDatabase(...)`. `CodexReviewStore` remains `@MainActor`.

Consumers keep their existing construction:

```swift
let store = CodexReviewStore.makeLiveStore(...)
ReviewMonitorWindowController(store: store, ...)
```

The host assembles storage behind `makeLiveStore`. App termination calls the
additive `store.shutdown()` instead of runtime-only `stop()`.

## Schema

SQLiteData `@Table` records describe storage rather than the observable job.

`review_workspaces` stores `cwd` as its primary key and a `sortOrder`.

`review_records` stores:

- Stable review ID and workspace `cwd` foreign key
- Unique app-wide `sortOrder`
- Typed target and payload, captured/effective model
- Lifecycle and typed terminal, cancellation, and interruption fields
- `startedAt`, nullable `endedAt`, summary, and final review
- Parsed-result state, source, and parser version
- `terminalCommittedAt` and creation/update timestamps

`review_findings` stores a stable finding ID, review foreign key with
`ON DELETE CASCADE`, ordinal, priority, title, body, path, and start/end line.
The pair `(reviewID, ordinal)` is unique.

Tables are `STRICT`, with foreign keys, explicit indices, and versioned,
append-only migrations. Production keeps history during schema changes.
Active rows have no terminal payload. Terminal rows have a compatible typed
terminal; success requires non-empty final review text within the 256 KiB
limit. Findings and parser metadata commit with the terminal result.

The port excludes session, thread, and turn IDs, exit code, raw logs, and
rendered values. Restored rows derive title, elapsed time, final flag, and
compact logs from stored fields. A terminal write changes only terminal and
result fields of an active row, preserving cwd, target, and order.

Reordering updates the whole supplied repository section in one store mutation,
preserving each review's `cwd`. Views filter the app-wide order without
regrouping by workspace or storing another UI order. New reviews reserve unique
app-wide positions. Load, start insertion, and order saving reject duplicate
positions, including collisions with rows omitted from a partial update.

### Retention

Keep at most 50 terminal reviews per workspace and 500 globally. Prune the
oldest by `(terminalCommittedAt, id)` at startup and after terminal commit.
Protect the completing review in its transaction so the API can read its result,
and keep all active rows. Return pruned IDs to update store membership, then
remove workspaces with no reviews. Version 1 has no time-based expiry.

## Failures

| Failure | Result |
| --- | --- |
| Open, migration, load, or decode | Set history to `.failed`, retain the database, continue runtime/auth/settings startup, and reject new reviews with an I/O error |
| Start-header write | Publish no live row and dispatch no backend review |
| Session, runtime, or app closes during a start write | Commit one requested interruption and dispatch no backend work |
| Terminal write | Keep the in-memory outcome, set history to `.failed`, return the completed review's actual result, and reject new starts until a successful app launch |
| Delete or reorder | Keep durable membership/order, set history to `.failed`, and report failure |
| Close | Publish/log the error and wait for the close attempt before termination completes |

On startup, queued and running rows become
`.interrupted(.previousProcessExit)` with unknown `endedAt`. The UI shows
neither a running timer nor an invented duration. Once application shutdown
enters `.closing`, start and restart cannot acquire a runtime; repeated shutdown
calls wait for the same completion.

## Boundaries to keep

Storage, target codecs, and terminal mappings can vary behind the history
interface. Live, preview, and test persistence are selected at composition.
A new target needs a codec/schema migration; a new terminal cause needs a typed
mapping and round-trip test. Runtime availability changes presentation without
changing history membership.

Remove `PreparedRecoveryEnvironment.withHistoryDatabaseURL` and its isolated
test so the production history location has one owner. Keep the Store and MCP
public behavior, using restored semantic records in the existing UI model.

Use the history port separately from `CodexReviewStoreBackend`; transport and
storage can vary independently. Keep SQLiteData `@FetchAll` out of leaf views.
`writeDiagnosticsIfNeeded` remains optional test output: it catches write
errors and includes raw/rendered values, so it cannot serve as persistence.
Retain database tasks and explicitly await close rather than relying on deinit.
A corrupt database reports failure without a fallback path or recreation.

## Validation

### Adapter

Test fresh migration and constraints, every target and terminal round trip,
findings transactions and cascade deletion, abandoned-row conversion, retention,
and returned pruned IDs. Invalid or incompatible rows must fail without erasing
data, and operations after close must fail. Cover both temporary-file and
in-memory databases.

### Store

Verify that history loads once before admission and start headers save before
dispatch. After a suspended write, recheck the session, work admission, model,
and order. A failed start must publish no row and dispatch no backend work.

Waiters, cancellation responses, runtime detach, and worker finalization must
wait for terminal persistence. A failed write must expose the error and block
later starts while preserving the completed review's outcome. Restored rows
must remain inaccessible to new MCP sessions.

Test overlapping reorder, delete, and retention operations for matching database
and store membership/order. Deletion must also update workspace membership and
the selection source. Shutdown must drain workers, synchronize terminal rows
and order, wait for receipts, and close once, rejecting restart and runtime
acquisition during shutdown.

### UI and app

Verify history visibility during runtime startup, stop, and failure. Restored
success, failure, and cancellation details must be non-empty. Unknown end times
must have no running timer, and history errors must appear in status. Terminal
context menus delete; active context menus cancel.

Reordering must accept every insertion gap in a repository section, including
between checkout and worktree rows. Keep each review's cwd and hidden filtered
rows, and restore the same order after reload. Verify production uses its history
path, previews/tests use injected stores, and app termination awaits shutdown.

### Isolated app E2E

Rebuild the app and launch it with a dedicated MCP port, diagnostics file, and
temporary database. The composition root owns these explicit inputs:
`REVIEW_MONITOR_TEST_PORT`, `REVIEW_MONITOR_TEST_CODEX_COMMAND`,
`REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH`, and `REVIEW_MONITOR_TEST_HISTORY_PATH`.
Leave `HOME` and production history unchanged.

Complete a real review through Streamable HTTP, terminate with
`NSRunningApplication.terminate()`, and wait for shutdown. Relaunch the same
binary with the same history path. Check diagnostics and visible UI for one
terminal row with target, model, status, final detail, and findings, without
command or reasoning transcripts. Verify a new MCP session cannot list or read
it. Capture the restored sidebar and detail for the PR. The executable procedure
is in the [E2E README](../scripts/review-history-e2e/README.md).

```bash
swift test --build-system swiftbuild --no-parallel
xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj \
  -scheme CodexReviewMonitor \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
scripts/check-compatibility.sh
git diff --check
```

Then run branch-wide local Codex review against `main` until it has no findings.

## Original delivery record

| Slice | Planned budget | Recorded completion |
| --- | --- | --- |
| A: schema and adapter | 6 hours; at most 10 production and 4 test files | Dependency, internal target, schema, migrations, codec, retention, close owner, and focused tests complete |
| B: store | 8 hours; at most 12 production and 5 test files | Port and injected disabled/test adapters; load, start/terminal writes, order, delete, shutdown, and Store/MCP tests complete |
| C: app and UI | 5 hours; at most 8 production and 4 test files | Production path/database, history visibility/health/deletion, and UI/app tests complete |
| D: delivery | — | Repository checks, clean local review, commits, and clean worktree complete; push and Ready PR still unchecked |

Completion measurements were intended to cover the product/target graph,
public/package/open declarations, largest files and store properties, remaining
platform gates, location and close ownership, deleted alternate routes, and
exact validation results. The recorded results were:

- `swift package dump-package` kept persistence internal, depending on
  `CodexReview` and SQLiteData. Host assembled it; UI had no storage dependency.
- Added ApplicationHostSupport SPI covered one-shot `shutdown()`, isolated-store
  factories, and history test keys. API baseline and checksum included these
  additions; the public live-store factory stayed unchanged.
- History store code had 760 lines; adapter, codec, and schema had 444, 479, and
  290. The store added availability, port, mutation receipts, durable-ID sets,
  result leases, and shutdown state, without another UI model or log cache.
- The production location was
  `Application Support/CodexReviewMonitor/RecoveryV1/review-history.sqlite`,
  retained through Application Support/application/recovery capabilities.
  Termination cancelled and waited for launch, store work, history receipts,
  database close, and directory close in that order. Runtime restart kept it open.
- The unused helper was removed, with no alternate database route, generic log
  table, transcript column, or SQLite import in UI.
- Package tests, the locked app test run (18 tests), compatibility checks,
  schema/codec/retention tests, and actual-app semantic/UI E2E passed. E2E used
  Codex 0.149.1 and restored the same terminal job and `AccessGate.swift:3-3`
  finding after restart. It checked MCP isolation and captured accessibility
  text and a screenshot. Local branch review reported zero findings.
- The standard app test command was blocked before compilation by local Xcode
  macro trust. CI, release, and E2E used the committed workspace lock,
  disabled automatic resolution, and `-skipMacroValidation`; app tests passed
  through that path.
- Runtime shutdown closed MCP admission, drained finite JSON-RPC responses
  through HTTP response-end acknowledgement, then disconnected sessions and
  closed the event-loop group. E2E required curl status 0 and a complete
  JSON-RPC/SSE response; restored history could not substitute for that response.
