# ReviewMonitor v0.6.2 recovery design (2026-08-20)

| Item | Value |
|---|---|
| Status | **Approved contract, resequenced — implementation gated by the predecessor chain** |
| Recovery base | `v0.6.2` / `82bddbcb1310a091eff742b36ab90781a4cbee5a` |
| Current-main evidence | `26c8f7b49e4afb356698d3c49e5107e96477b2ca` |
| Upstream Codex contract | `3b45c29062ff0e76e71c91b6753290400e7fa8da` |
| Installed live Codex | `codex-cli 0.148.0-alpha.15` from ChatGPT.app |
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
   and v0.6.2-compatible effective log are restored without fetching the thread
   from app-server.
3. During an active authorized MCP session, a Codex or Claude Code client uses
   `review_start`, `review_await`, `review_read`, `review_list`, and
   `review_cancel` against the same committed product history as the UI.
4. A user can authenticate with current ChatGPT web login or an OpenAI API key,
   and ReviewMonitor can locate the installed Codex executable automatically.

### Compatibility policy

- The latest published release is v0.6.2. Its user-visible review behavior and
  published MCP field names are the compatibility baseline.
- The four v0.6.2 Swift library products remain source-compatible for external
  consumers. Public changes are additive/defaulted; package-only MCP/store
  operations may become async to query SQLite. A v0.6.2 API-digester baseline
  and a separate-package consumer fixture enforce this contract.
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
- A client for standalone `command/exec` or `process/spawn`; ReviewMonitor does
  not originate or own those connection-scoped requests.
- Exposing reviewer, compact, spawn, or other internal subagent threads as
  standalone product rows.
- Recreating the current CodexDataKit fetched-results stack.
- CloudKit synchronization for review history.
- Persisting authentication secrets inside the review history database.
- Restoring post-v0.6.2 SDK/DocC products as part of runtime recovery.
- Cross-session or cross-app-restart MCP access to old reviews. Durable history
  is application-wide for ReviewUI; the published MCP authorization remains
  session-local unless a future explicit authorization token is designed.

### Recovery-owned environment

The path-owned former Wave 0 implementation, including the follow-up branch tip
`c83e49960c303682ea4b4be77a8cfe0f7ff59151`, is rejected and must not merge.
It failed the same filesystem-authority invariant across four implementation
rounds (`864b16a`, `3b2def2`, `d3f3e20`, `c83e499`). It remains evidence for
tests only; adding another standardized/canonical URL guard is not an authorized
repair.

No recovery build uses the current default `~/.codex_review` directory or the
existing `codexReview.runtimePreferences` value as a writable destination.
`RecoveryEnvironmentPlan` describes the intended names and policy without
performing I/O. The descriptor-capability gate in issue #113 prepares exactly
one `PreparedRecoveryEnvironment` before any Process, MCP, authentication, or
GRDB admission. Production diagnostic names remain versioned locations under
ReviewMonitor's Application Support directory:

- `RecoveryV1/CodexHome`
- `RecoveryV1/LoginStaging/<authentication-session-id>`
- `RecoveryV1/SavedAccounts/<stable-account-id>`
- `RecoveryV1/review-history.sqlite`
- a `codexReview.recoveryV1.runtimePreferences` preference key

These URLs are display/configuration facts, not authorization tokens. Every
managed directory/file operation is performed relative to an opaque descriptor
capability from the prepared environment. Development probes additionally use
an injected trusted-ancestor descriptor, isolated preference suite, and MCP port
override so they can coexist with the current app. The existing home and
preference value are read-only migration inputs. The #108 importer creates a
verified copy/snapshot before reading secrets, writes only through destination
capabilities, and records a migration manifest. App-server startup is gated on
successful preparation; it cannot fall through to the legacy default path.

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

#### F9 — v0.6.2 predates the anchor-based reorder correction (CONFIRMED)

PR #50 replaced visible/store insertion indices with stable before-anchor
commands for filtered, grouped, and blank-area drops. Durable sort columns do
not reproduce this interaction contract by themselves. Tracked by
[#110](https://github.com/lynnswap/CodexReviewKit/issues/110).

#### F10 — Attempt-local force-close breaks the shared runtime generation (CONFIRMED by PR #117 P1)

At PR #117 head `d90be363162692ca34b55cd9c2da77109ec852cf`, one
attempt's cancellation grace invokes the Store's runtime-unidentified
`forceCloseReviewConnection()`. `AppServerCodexReviewBackend` closes the one
`AppServerClient` shared by every review session, its router delivers connection
termination to all siblings, and otherwise healthy siblings terminalize. The
target attempt then tries rollback/resume through that same permanently closed
client. The Host can construct a replacement client/backend, but no
runtime-generation owner correlates the forced close, enrolls siblings, or
constructs exactly one replacement. This makes Wave 3A unsafe to merge alone;
Wave 3A+B is one combined merge gate.

## 3. Target and product design

### Candidate A — SQLiteData wrapper

[SQLiteData 1.9.0](https://github.com/pointfreeco/sqlite-data/tree/1.9.0)
provides GRDB-backed migrations/transactions, typed queries, explicit database
parameters, and observable fetch publishers. It also resolves a much larger
Point-Free sharing/dependency/query/macro graph. The actual-flags probe passed
only when `FetchAll` was stored as a plain explicitly initialized value; the
property-wrapper declaration touched the global default database before init
replacement. Because stable job identity, visible error state, subscription
lifecycle, and AppKit projection still require product-owned code, the wrapper
does not remove an owner in this design.

### Candidate B — Direct GRDB adapter (recommended)

Keep the released target graph. Add GRDB 7.11.1 only to the existing
`CodexReview` target and contain every GRDB import under
`Sources/CodexReview/Persistence`.

The comparison probes used the recovery Swift 6 / macOS 26 flags:

- SQLiteData: explicit database, observation, separate load error, subscription
  cancel/Task completion, migration rollback, and close passed after avoiding
  the global-default property-wrapper path; initial graph planned about 807
  build units.
- Direct GRDB: migration rollback, explicit database, MainActor
  `ValueObservation`, direct error callback, cancellable observation, and
  throwing close passed with about 114 build units.

The probes were disposable packages and used the same command that the root
package uses: `swift test --build-system swiftbuild --no-parallel` in
`/tmp/codexreview-sqlite-probe` (3 tests passed) and
`/tmp/codexreview-grdb-probe` (2 tests passed). Their resolved direct-GRDB
revision was `b83108d10f42680d78f23fe4d4d80fc88dab3212`. The commands, dependency
graphs, and results are also recorded in the recovery ledger before the probe
directories are removed.

Direct GRDB leaves row mapping in the product, but that mapping is already part
of the seven-table schema owner. It avoids wrapper/macro/global-dependency
lifecycle while exposing the exact error and cancellation contracts required by
this design. Baseline: [GRDB 7.11.1](https://github.com/groue/GRDB.swift/tree/v7.11.1)
(`b83108d10f42680d78f23fe4d4d80fc88dab3212`).

```text
CodexReviewMonitor.app (composition root)
    ├──▶ CodexReviewHost ───────▶ CodexReview
    │        ├──▶ CodexReviewAppServer ─▶ CodexReview
    │        └──▶ CodexReviewMCPServer ─▶ CodexReview
    └──▶ ReviewUI ──────────────▶ CodexReview

CodexReview ─▶ GRDB 7.11.1
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
- Types and access control can keep GRDB behind one owner inside the
  existing domain target.

`ReviewHistoryStore` is an independent collaborator of `CodexReviewStore`; no
persistence method is added to the already broad `CodexReviewStoreBackend`
runtime seam. Authentication replaces the old duplicate `signIn`/`addAccount`
backend entries with one intent-bearing `authenticate(request:)` operation
rather than adding another parallel path. Executable discovery remains in
`CodexReviewHost` composition and is not a backend fallback.

### Candidate C — Repair current generic-chat/CodexDataKit architecture

Rejected. It retains app-server thread membership as UI state, keeps product
review identity split between run/chat/source kinds, and requires continued
fallbacks for missing live records. The confirmed symptoms are consequences of
that ownership model rather than isolated call-site defects.

### Decision

Adopt Candidate B with GRDB 7.11.1. Do not expose GRDB types in any public or
cross-target signature and do not use a global default database.
The ReviewMonitor composition root injects a domain
`ReviewHistoryConfiguration` containing the exact recovery-owned managed-file
capability; the `CodexReview` persistence owner performs the #113 last-moment
identity revalidation, then opens and retains one `DatabasePool` with
foreign keys and WAL explicitly enabled for production and temporary-file
integration tests. Focused
in-memory/migration unit tests may use `DatabaseQueue`; no runtime code selects
between them. Tests inject a capability prepared below a temporary trusted
ancestor through the same seam. A raw URL-only GRDB open is not mergeable.
The configuration may carry a package-only immutable `ReviewHistoryBootstrap`
for preview/test content. Live configurations always set it to `nil`. Bootstrap
is applied through normal writer transactions only after migration and startup-
orphan recovery, and only when the opened database is brand new and empty; it
never overwrites existing history or bypasses the query/publication path.

Issue #113 does not add a library product or a file-bucket target. The
package-only descriptor primitive lives under
`Sources/CodexReview/RecoveryStorage/`: `CodexReview` needs it for history,
`CodexReviewAppServer` already depends on `CodexReview` for the Process handoff,
and `CodexReviewHost` already depends on both for composition and authentication.
`RecoveryEnvironmentPlan` and the prepared aggregate remain in
`CodexReviewHost`; low-level `DirectoryCapability` and managed-file values point
only downward. If implementation cannot preserve this acyclic dependency graph,
return to the topology gate rather than passing raw URLs across targets.

## 4. Owner map and lifecycle

### Target owner map

| Responsibility | Current-main owner/problem | Recovery owner |
|---|---|---|
| Product review ID | Run record plus source/reviewer chat IDs | `CodexReviewStore` allocates one stable review ID |
| Attempt identity | Multiple raw optional IDs | Review attempt value attached to one review ID |
| Live app-server I/O | AppServerKit/DataKit plus product adapters | `AppServerCodexReviewBackend` only |
| Notification semantics | Wire, DataKit, UI projections | Backend decoder/reducer boundary |
| Lifecycle/terminal | Run worker plus chat status/replay | One review processor and terminal commit |
| Application lifetime | `serverState` plus caller-owned stop Tasks; no public close | `CodexReviewStore` open/closing/closed state; its one close Task owns Store acquisition/review/rate-limit/cleanup work and assembles every failure |
| Runtime generation/publication | Host factory awaits then directly installs client/backend state | Store-owned AppServer generation; inert `PreparedRuntime` with auth/settings only; exact activation and atomic publication |
| Shared AppServer connection | One backend/client shared by sessions, but attempt-local force-close | Store runtime transition enrolls sibling recovery and creates one replacement backend/client |
| AppServer semantic shutdown | Client close is not a join for private notification router/event sessions | `AppServerCodexReviewBackend.closeAndWaitForOwnedLifecycle()` captures and directly joins its owned Task/sessions after client close |
| MCP lifecycle | Listener/session stop does not own admitted handler Tasks | One Host app-lifetime `MCPServerLifecycleOwner` creates sequential leases across stop/start, retains the lease across restart/recoveryReplacement, and owns network/handler/session completion |
| Runtime consumers | Rate-limit/auth observation is cancelled without a joined lifetime | Store close Task owns rate-limit/review/cleanup work; AppServer handle owns only Host auth observation/reader/router/session/client/process |
| Persistence | None; app-server threads are re-fetched | `ReviewHistoryStore` local SQLite database |
| Log membership/order | Generic chat turn/item projection | Review history transaction sequence |
| Sidebar membership/order | Fetched app-server chats | Durable product review query |
| Detail content | Selected generic chat observation | Durable log query for selected review ID |
| Duration | Live run or generic recency fallback | Review start/end in durable run record |
| Selection | Generic chat ID | Product review ID |
| Render artifacts | Chat/document caches plus native views | Native snapshot/document diff rebuilt from history query |
| Authentication | Current runtime transition graph | Recovery auth owner plus current login/API-key adapters |
| Executable discovery | Current CodexKit helper | One composition-root resolver |
| Recovery path policy | URL construction plus caller checks | `RecoveryEnvironmentPlan` (configuration only) |
| Filesystem authority | Canonical/standardized URL checks in former Wave 0 | One descriptor-backed recovery storage actor and its opaque `DirectoryCapability` values |
| Prepared runtime/history locations | Bare URLs passed between callers | One `PreparedRecoveryEnvironment` aggregate |
| Auth artifacts/RegistryV2 | Helpers beside live backend | One authentication disk actor using descriptor-relative files |
| Login staging lifecycle | Environment creates/removes a bare temporary URL | One `LoginStagingLease` per admitted authentication session |
| Pending auth/cleanup debt | Caller state, logs, or Environment cleanup | Authentication disk actor's one versioned atomic state manifest |

### Descriptor-backed RecoveryV1 authority (#113)

`RecoveryEnvironmentPlan` is inert configuration. Its only mutating operation is
to ask the package recovery storage actor to prepare and return one
`PreparedRecoveryEnvironment`. The prepared value aggregates opaque capabilities
for the RecoveryV1 root, primary Codex home, login-staging root, saved-account
root, and the managed history file location. It does not expose a raw descriptor
or treat a URL as proof of containment.

Every path component below a trusted ancestor is opened separately with
`openat(parentFD, component, O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)`. A missing
managed component is created with `mkdirat`, then reopened with the same flags;
the descriptor returned by creation is never inferred from the requested path.
Components are single validated names: empty, slash-containing, `.` and `..`
values are rejected before I/O. Each open is followed by `fstat`; the capability
records volume/device/inode identity, file type, owner, mode, and policy
generation. Parent-descriptor traversal establishes ancestry. Revalidation uses
the still-owned parent descriptor plus `fstatat(..., AT_SYMLINK_NOFOLLOW)` and a
fresh `openat`/`fstat`, and requires the recorded device/inode/type to match.

The default production anchor is the already-opened user Application Support
ancestor selected by composition. Tests inject an owner-controlled temporary
anchor. A configured home on another volume must be introduced as its own
explicit trusted anchor and policy; discovering a new `st_dev` while walking an
existing managed subtree is a mount-crossing failure, never an implicit new
root. No managed child may cross its anchor's device. Existing explicitly
configured homes are validation-only: recovery never `chmod`s, `chown`s, or
rewrites ACLs to make them pass.

New managed directories are created as the effective user with mode `0700`.
Existing managed directories must be directories owned by `geteuid()`, have no
group/world permission bits, and have no extended ACL entry, including an
inherited entry. Failure to read ownership, mode, mount identity, or ACL is an
unknown-policy failure and closes admission. Trusted anchors have an explicit
composition policy; a broader system ancestor is never silently promoted into a
managed writable subtree.

Creation, bounded reads, temp creation, file/directory `fsync`, same-directory
atomic replacement, and removal use descriptor-relative operations
(`openat`/`mkdirat`/`renameat`/`unlinkat`) only. Recursive removal walks the
already-opened manifested directory, opens every child with no-follow semantics,
rejects an identity/device/type/policy mismatch, and removes entries relative to
their parent descriptor. There is no `FileManager.removeItem(at:)`, canonical-
path prefix test, or symlink-resolved deletion fallback for managed state.

The same core exposes a read-only source capability for Wave 7 without granting
source mutation. `AbsoluteComponentPath` parses a locator string once at the
input boundary; the actor then walks it from its already-opened trusted system
root and enforces the declared read-only mount/owner policy. A versioned
`ReadOnlySourceAllowlist` is the only enumeration API. It returns opaque file
capabilities plus relative component sequences. Only after provider filtering
has excluded API-key artifacts may the snapshotter request bounded size/SHA-256.
Verified copy revalidates the expected source snapshot, reads that descriptor
directly into a descriptor-owner-created managed destination, and returns
source-before/source-after plus destination identity, byte count, and digest.
The caller requires before == after before publishing its manifest. No API opens
an arbitrary child URL, returns a source URL, or mutates the source.

Foundation canonical/standardized URLs and `F_GETPATH` output may appear in a
redacted diagnostic or be passed to an unavoidable path-only system/library API;
they never grant authority. Immediately before `Process.run` or GRDB constructs
its connection, the consuming owner asks the storage actor to reopen the full
capability chain and compare all recorded identities. The actor then invokes the
synchronous open/launch handoff while retaining the descriptors. A mismatch
fails before the external call. No caller may save the resulting URL and reuse
it for a later open.

#### Threat model and residual risk

The contract protects against case/Unicode/firmlink aliases, symlink components,
reverse-ancestor overlap, unexpected mounts, shared ownership/mode/ACLs, stale
path reuse, and replacement detected before a managed mutation or external
handoff. The trusted-ancestor descriptor and every live child descriptor are the
authority even if their display path is renamed.

A malicious process running as the same UID is explicitly a residual threat:
it can have enough authority to rename or replace path entries after the final
identity check, and path-only Process/SQLite APIs cannot consume ReviewMonitor's
directory descriptor atomically. Last-moment revalidation plus retained
descriptors narrows and detects normal races but is not claimed to defeat that
last-instruction race. Treating a hostile same-UID process as in scope would
require a sandbox/broker or a downstream descriptor-relative API and a new
design gate. Other users, accidental aliases, and non-cooperating current-main
paths remain in scope and fail closed.

### Durable source of truth

The database owns the semantic state that must survive process or transport
loss. In-memory observable objects and native snapshots are projections that can
be rebuilt from the database.

The history database and its queries have application lifetime. App-server and
account runtime generations are shorter-lived producers. Restarting, switching,
signing out, or replacing a runtime may change live command availability, but
it never closes the history owner or publishes an empty history snapshot.

The database contains seven tables:

1. `reviewHistoryState`
   - single row containing schema metadata and the next global history revision.
2. `reviewWorkspaces`
   - canonical workspace URL/path and durable manual sort order.
3. `reviewRuns`
   - stable review ID, session/workspace, target and target summary;
   - lifecycle/status, start/end, cancellation/failure, canonical final result,
     result payload version, and result digest;
   - current attempt and canonical outer/source/reviewer thread linkage;
   - model/account presentation metadata, last applied global revision, sort order,
     `lastCommittedAt` / `observedThroughAt`, duration accuracy, and startup-
     recovery state; nullable `durationExactMs` preserves authoritative
     duration-only inputs without inventing end time.
4. `reviewAttempts`
   - stable attempt ID and parent review ID;
   - source/review/turn identities, model, start/end, and terminal reason.
5. `reviewLogEntries`
   - stable entry ID, review/attempt ID, immutable `displayOrdinal`, and
     `lastMutationRevision`;
   - semantic kind, group/source item identity, append/replace behavior;
   - text, typed metadata payload, timestamp, optional upstream event ID, and
     `latestSourceEntryID` for provenance;
   - optional canonical-result role/reference and digest; a role row contains no
     duplicate final-result text.
6. `reviewEventReceipts`
   - only stable replayable item/turn lifecycle event keys and the revision that
     applied them; raw delta chunks without an upstream stable ID are not
     receipts and are never replayed as an event journal.
7. `reviewImports`
   - source fingerprint, importer/schema version, deterministic legacy key,
     source content hash, destination review ID, status, and skip/failure reason.

Foreign keys are enabled. Attempt identity and foreign keys use the composite
`(reviewID, attemptID)`; recovery never fabricates the old global-looking
`"attempt-1"` default. `reviewRuns.currentAttemptID` must reference an attempt
under the same review. `(reviewID, displayOrdinal)` is unique. Appends allocate
the next ordinal inside the writer transaction; grouped append/replace updates
the existing row without changing its ordinal and stamps only
`lastMutationRevision`. Stable upstream
event IDs have a uniqueness constraint scoped to the attempt. A connection-
scoped standalone process handle is never inferred to be a review item ID. It
may exist as attempt-local routing metadata only when the owner of that exact
standalone request registered the handle-to-attempt/item mapping before sending
the request; the current recovery product sends no such request. Review history
stores effective semantic log rows, not an
append-only raw event journal: group replacement updates one row, and rows
removed or truncated by the existing 256 KiB capped-text policy are changed in
the same transaction. That 256 KiB policy applies only to the existing capped
rendered-text kinds; command/progress/event rows and metadata are not claimed to
fit inside a global 256 KiB hard limit. Ungrouped visible lifecycle/diagnostic
rows are retained,
and complete reviews are not automatically evicted from the database. The
in-memory query window contains every nonterminal review plus the newest 100
terminal reviews and can page older reviews on demand. A terminal review can be
explicitly deleted from ReviewUI after confirmation; active reviews and MCP
sessions cannot delete history. Deletion cascades attempts, log rows, and
receipts in one transaction, removes an empty workspace row, and clears UI
selection only after commit. These rows are intentional user history rather
than hidden replay state.

The durable row ID is the public/MCP effective `ReviewLogEntry.id` and remains
stable when grouped deltas or replacement events mutate that row.
`latestSourceEntryID` records the newest contributing wire-entry ID for
diagnostics/import provenance only. This intentionally corrects v0.6.2's
projection behavior, which changed the effective public ID to the latest event
on every grouped update. Entry order, effective count, text, metadata, and MCP
paging remain compatible. The stable-ID change is an accepted behavioral
difference and is pinned by the external consumer fixture and MCP golden tests.

For a completed review, one terminal transaction normalizes the final review
once and writes all of: completed lifecycle, the sole text owner
`reviewRuns.finalResult`, its payload version/digest, and exactly one effective
log marker carrying the canonical-result role/reference and digest. The query
joins that marker to `reviewRuns.finalResult` when constructing
`ReviewLogEntry`; the log table never duplicates the text. The transaction
rolls back as a whole on any mismatch. History queries and migrations validate
the one-to-one digest invariant; corruption is a typed data error with last-good
UI, never a choice of whichever copy is nonempty. Lifecycle/result is always
read from `reviewRuns`; no reducer, query, UI, or MCP code reconstructs terminal
success from a log row.

`ReviewFinalResult` accepts nonempty normalized text up to 256 KiB UTF-8. A
larger upstream result produces a visible `outputTooLarge(actualBytes:limit:)`
terminal failure rather than silent truncation or unbounded eager hydration.
For valid results, the joined canonical row participates in the existing 256
KiB rendered projection and is retained losslessly; older noncanonical capped
rows are trimmed/removed first. This priority and over-limit failure are an
accepted compatibility correction to guarantee one stable final row while
keeping the same total capped-log budget. Tests pin boundary Unicode, exactly-
limit, over-limit, restart, DB size, and loaded-window memory behavior.

The terminal transaction also owns companion suppression. With full current-v2
delivery, the `exitedReviewMode` source becomes the canonical marker and the
typed same-turn final-assistant companion is removed from the visible effective
set (its stable receipt/provenance remains). With sparse delivery, the already-
ingested same-turn summary row is promoted to that marker; no second row is
appended. Selection uses outer thread/turn/attempt and typed item role, never
text/digest equality. Thus every completed review has exactly one visible
terminal-result row.

Every mutating transaction increments one global database revision in
`reviewHistoryState` and stamps every affected row. That same revision is
returned in `ReviewHistoryCommit` and includes workspace reorder, run/attempt,
log, receipt, and import changes. Query projections reject an older
row revision; there is no separate per-run revision counter.

Receipt semantics are explicit: an identical duplicate is an idempotent no-op;
the same stable event key with a conflicting payload is a typed ingestion
contract error. A terminal for a previous attempt may close that attempt record
but cannot change the current run lifecycle. An identical duplicate terminal is
a no-op; a conflicting terminal for the same attempt is a typed contract error.

Only `reviewRuns.currentAttemptID` may mutate product lifecycle, canonical
output, or user-visible effective log rows. A late event for an older attempt
may update that attempt's terminal, receipt, or bounded diagnostic record, but
cannot update the product result/log or reopen/reterminalize the current run.
Group and receipt uniqueness keys are scoped as
`(reviewID, attemptID, kind, upstreamKey)`. A registered process handle, if a
future product operation introduces one, is additionally scoped to its app-
server connection and cannot cross an attempt boundary.

On startup, a nonterminal row with no matching live processor becomes
`recoveryRequired`. The product may attach a verified matching current turn; if
it cannot, it commits an interrupted/failed terminal with an explicit previous-
process-exit reason. Exact `endedAt` remains nil, while the last committed event
time becomes `observedThroughAt` and yields a labeled lower-bound duration. It
never remains a permanently running timer merely because the previous process
exited, and it never presents the lower bound as an exact duration.

Authentication credentials are never columns or metadata payloads in this
database.

Any structured JSON column (target, result, cancellation, log metadata,
diagnostic payload) has an adjacent explicit payload version/type. Unknown or
undecodable versions fail the row/query with a typed migration/data error and
retain the last good UI snapshot; they never decode as nil/default content.

The recovery-owned history directory capability enforces the #113 owner/mode/
ACL/mount policy. The SQLite database, WAL, and shared-memory files are created
with owner read/write permissions only after last-moment GRDB handoff
revalidation. Diagnostics report schema/version/operation plus redacted
filesystem identity, never review content or bound SQL values by default.

### Commit-before-publish flow

```text
App-server notification / UI or MCP command
    ↓
Typed ReviewMutation at the product boundary
    ↓
ReviewHistoryStore actor validates identity + applies one SQLite transaction
    ↓
SQLite database revision N
    ├──▶ ReviewHistoryQuery observation ─▶ stable job projection ─▶ ReviewUI
    └──▶ immutable ReviewHistoryCommit(revision: N) ─▶ processor/MCP terminal
```

- A semantic mutation is never published before its transaction commits.
- The single run processor supplies total order and awaits each history commit;
  fire-and-forget database writes are not allowed.
- The UI reads only committed query state. A transport failure does not replace
  that state with an empty result.
- Replay idempotency is limited to event families with stable item/turn keys.
  Live raw deltas have no current upstream sequence/event ID and are consumed
  once in connection order. Recovery uses an authoritative full logical-item
  replacement or starts a new attempt; it never replays raw deltas and never
  deduplicates by display text or a reusable process handle.

One `@MainActor` `ReviewHistoryQuery` owns the published observation generation;
each generation consists of one GRDB `ValueObservation` whose single read
transaction returns the global revision plus the complete loaded-window
workspace/run/effective-log snapshot. Cross-table state is never
published from independent observers. It eagerly hydrates the
existing public `CodexReviewJob.logEntries` surface from capped semantic rows,
retains a projection registry keyed by `ReviewID`, reconciles stable job
instances after observed commits, and applies only a complete snapshot with a
global revision newer than the last published snapshot. Deletions are the
absence of an ID from that complete revision, never an early table callback.
Selection remains entirely in
ReviewUI and merely chooses an already-hydrated job; it does not create a
second log query or persistence owner.

The writer never mutates UI projections directly, so there are not two
competing publication paths. The processor keeps only transient control state
needed to drive the active app-server attempt; sidebar/detail semantics come
from the history query. MCP terminal waiters complete from the committed
transaction result, and MCP read/list operations query committed history. GRDB
observations report failures through an explicit MainActor error callback. The
query retains the last good value and exposes a typed loading/loaded/failed
phase; an error never masquerades as a successful empty query.

The query owns every GRDB `AnyDatabaseCancellable`. `close()` cancels and clears
them before the database owner closes. `deinit` sends the same synchronous cancel
only as a backstop.

`ReviewHistoryQuery.start()` starts all observations and suspends until their
first complete workspace/run/log snapshot or the first error callback. It does
not expose the initial empty stored properties as loaded history.

The loaded ID set grows monotonically for the process lifetime: all active IDs,
the initial top 100 terminal IDs in durable manual display order (whose default
insertion order is recency), every explicitly paged ID, and the selected ID are
never evicted merely because a new review terminalizes. Paging traverses a
separate immutable recency sequence keyed by `(terminalAt, reviewID)` from newest
to oldest. Its cursor is the last scanned key, not the oldest loaded/manual row:
each `loadNextPage()` scan skips already-loaded IDs until it adds one page or
reaches the end. Thus an ancient review manually moved into the initial top 100
cannot cause intervening reviews to be skipped. The paging session records its
start revision/upper key; later terminal rows are already loaded from their
active identity and do not move that cursor. The query then restarts the single
observation for the enlarged loaded-ID set.
The returned `ReviewHistoryPage` reports `addedCount`, `loadedCount`, `hasMore`,
and the next opaque keyset cursor. Manual reorder changes display order but not
the paging cursor. Moving an already loaded old review to the durable top keeps
it loaded immediately and places it inside the next launch's manual-order top
100; new terminal rows never evict an already loaded/selected row.

An enlarged-window observation uses a generation handoff, not an empty reset.
The query keeps the last-good projection and current observation alive while it
starts the replacement for the immutable enlarged ID set. After the replacement
delivers one complete snapshot at least as new as the published revision, the
query atomically installs its generation and cancels the predecessor. Late
callbacks from an older generation are ignored. If replacement startup fails,
the old observation/rows remain active and the paging operation reports a typed
error; it never publishes `[]` during subscription churn.
The loaded-ID set and paging cursor become durable query state only after that
handoff; a failed replacement leaves both at their prior values so retry scans
the same range.

Anchor reorder is one database command. A missing moving ID or a non-`nil`
anchor that is stale, belongs to another workspace/scope, or is not in the
command's canonical order produces a typed no-write error. A `nil` anchor means
the canonical end. Moving an item to its existing position returns `false` and
does not increment the revision; a successful move returns `true` and commits
exactly one global revision. Filtering/grouping only supplies the stable IDs and
never converts a visible index into durable order.

### Transport-loss and retry state machine

The product processor, not the transport, owns what connection loss means for a
review. A recoverable network loss commits the old attempt's transport
interruption and `waitingForConnectivity` while keeping the product review
nonterminal. Connectivity restoration moves through `recovering` and creates a
new generated attempt ID under the same review. A nonrecoverable process/
protocol failure commits a failed product terminal with transport cause. Once
the connection is known dead, the processor does not wait forever for an
upstream turn terminal that cannot arrive. User/MCP cancellation while waiting
or recovering commits requested cancellation and prevents another attempt.

Only one `ReviewExecutionPhase` transition owner may start/recover attempts.
Network monitor events, app-server terminal events, and cancel commands enter
that owner; call sites do not independently restart or rewrite history.

`ReviewStartAdmission` is created once per attempt and is that attempt's
lifecycle owner from the first request-dispatch decision through its canonical
or connection terminal. The AppServer backend's `interruptReview` operation is
request-scoped: success means only that `turn/interrupt` was acknowledged. It
does not wait for a semantic terminal, finish or abandon an event mailbox,
unregister the attempt, create a recovery token, or clean up its thread. The
admission retains the interrupt request Task, terminal-barrier Task, grace Task,
and any force-close Task and joins them before releasing the attempt. There is
no separate backend-owned `beginReviewRecovery` lifecycle shortcut; recovery is
a purpose passed into the same admission-owned interruption operation.

A recoverable transition keeps the current Store event subscription and the
AppServer event session registered while that admission waits. Neither owner
may clear its active subscription ID, cancel the mailbox consumer, mark the
attempt/turn abandoned, or unregister the session merely because the interrupt
request was acknowledged. The matching canonical terminal continues to enter
the Wave 2 reducer through that subscription; a typed connection/process
terminal enters the same admission directly. Only after one of those barriers
has won and every request/force-close handle has joined may the Store detach the
old subscription and the backend finish/unregister the old attempt session.
Recoverable teardown preserves the source thread needed for continuation and
does not run destructive review cleanup.

The event mailbox and Store worker queue preserve a closed typed terminal union
end to end. Verified network outage, owner-forced connection close, unexpected
connection loss, process exit, protocol/routing violation, and owner Task
cancellation remain distinct cases with their original typed payloads. A
mailbox never stores `Error.localizedDescription`/`String` as its failure value,
and the Store never treats a generic stream failure as recoverable merely
because ambient network status is unsatisfied. Only the explicit
recoverable-network case, or an owner-forced close correlated with an
already-admitted recoverable transition, may enter replacement policy. Process
exit, protocol/routing violation, and unclassified connection failure are
nonrecoverable. Unknown
errors are converted once at the transport/router boundary to a typed
nonrecoverable contract failure; formatting occurs only at the UI/log edge.

The recovery barrier produces one typed disposition:

- canonical `completed` or `failed` is a natural product terminal and suppresses
  recovery, even if a recovery request or its acknowledgement arrived first;
- canonical `interrupted`, or a typed connection terminal classified
  recoverable by the fixed trigger policy below, closes only the old attempt and
  permits one replacement while the product review remains nonterminal;
- a nonrecoverable connection/process/protocol terminal closes the product with
  its typed failure and permits no replacement.

The admission installs one `ReviewRecoveryDisposition` before any backend
recovery token is created. Both cases retain the exact resolved old-attempt
run/terminal and request rejection or outcome-unknown diagnostic. The
product-terminal case additionally contains the exact product terminal to
commit; the replacement case contains its trigger but no token. A cancellation
admitted before that disposition is installed joins the same request/barrier and
participates in this one decision; a product-terminal disposition can never be tokenized. For a
replacement disposition, the Store first passes the whole disposition through
the single finish owner. That branch finishes the old attempt while explicitly
keeping the product nonterminal; a product-terminal branch finishes both. Only
the returned replacement candidate may then ask the backend to seal the old
session and create a token. The resulting waiting handoff contains both the
unchanged candidate and token; neither is stored or passed alone. Wave 4 makes
this same finish owner the atomic old-attempt/product commit before token
creation.

If explicit user/MCP/system cancellation is admitted while recovery is waiting
on the old attempt, it joins that admission's already-recorded request/barrier
Task; it does not issue a second interrupt or locally fabricate a terminal. A
natural `completed`/`failed` terminal that wins the owner ordering remains
authoritative. Otherwise an acknowledged recovery interrupt followed by the
interrupted/connection barrier commits the requested product interruption and
suppresses replacement. If the recovery request remained outcome-unknown and
only connection loss satisfied the barrier, the typed transport outcome and
request failure remain visible rather than fabricating requested cancellation;
replacement is still suppressed. Once the old barrier has completed and the
product is merely `waitingForConnectivity`, there is no live attempt to
interrupt; cancellation commits locally and prevents recovery admission.

In particular, outcome-unknown request plus connection terminal plus a joined
explicit cancellation produces a product-terminal transport disposition with
the original request failure as its secondary diagnostic. It does not produce
`.requested`, a recovery token, or a replacement attempt.

“Replacement” in this admission/disposition state machine means one review's
next attempt. It is independent of the one-per-generation AppServer runtime
replacement required after a shared old-runtime close signal.

Each replacement has a newly allocated attempt ID and a newly constructed
`ReviewStartAdmission`. `resumeReviewRecovery` receives that fresh admission and
must ask it immediately before the replacement `review/start` write. The old
terminal admission is immutable and cannot be reset to active or reused for the
new run. The Store publishes the new admission/run pair atomically only after
the old attempt barrier and teardown completed; cancellation before replacement
dispatch is therefore proven by the new admission as `.notSent`.

The Store holds run and admission in one attempt-ownership state, not parallel
`activeRuns` and `reviewStartAdmissions` maps. The state distinguishes initial
start, active `(run, admission)`, resolving disposition, preparing/waiting
handoff, replacement start `(handoff, fresh admission, owned start Task)`, and
terminal. Cancellation before disposition joins the old admission. Cancellation
after a replacement disposition but before/during token preparation suppresses
replacement, joins any owned preparation Task, and never publishes its handoff;
waiting cancellation discards the handoff and commits locally. During rollback
and before replacement `review/start` returns, there is no published active run;
cancellation routes to the fresh candidate admission from the replacement-start
state. Only a successful response creates one immutable new `(run, admission)`
pair and atomically changes replacement-start to active. Failure/cancellation
cleanup receives the explicit old handoff or candidate admission from that
state, never a run from one dictionary and an admission from another.

Initial and replacement starts use one admission-owned registered start handle
and explicit activation gate. `registerStart` records the Task and handle ID, but
the Task first waits on admission state and cannot call backend code. The Store
installs the whole handle in its attempt-ownership state, then calls
`activateStart(handleID)`. Only that exact activation changes pending to active
and releases the Task. Cancellation/terminal between registration, Store
publication, and activation instead resolves the gate with the recorded typed
outcome, so the Task returns without a backend write. Start entry also rejects a
terminal/cancelled admission instead of resetting it to `preparingThread`.
Wrong/stale activation IDs are typed contract failures; repeated activation of
the same live handle is idempotent. This is an explicit state handshake, not an
assumption about when a newly created Task happens to run. Store close/cancel
resolves every pending activation gate and awaits its registered Task, so an
unactivated handle cannot leak or block shutdown.

Wave 3A temporarily retains the existing runtime-stop detachment entry point,
but detachment applies only to the worker Task registry, never semantic attempt
ownership. `cancelAndDetachReviewWorkersForRuntimeStop` moves/cancels the worker
handle while retaining `ReviewAttemptOwnership` until that detached worker has
resolved any pending activation gate to cancellation/terminal, joined its
admission/start work, and removes the same ownership generation on the Store
actor. Test cleanup likewise cancels and
awaits workers before clearing the sole registry. Wave 3B replaces this temporary
Task detachment with the single runtime/store close authority; it is not a
second lifecycle owner or a permanent fallback.

Runtime transitions use this fixed product policy:

| Trigger | Current attempt | Product review | Next attempt | Duration | MCP waiter |
|---|---|---|---|---|---|
| Explicit user/MCP review cancel | await matching interrupted/connection terminal; force-close only after grace | terminal `.interrupted(.requested(source))` | none | exact with upstream end; otherwise labeled lower bound | returns committed interrupted result |
| `store.stop()` / disable runtime | system-request interrupt and same terminal barrier | terminal requested interruption | none | exact or lower bound | returns committed interrupted result before current MCP lease drain/stop; later start uses a new lease |
| `store.restart()` / same-account runtime or executable reset | close old attempt as server/transport interruption | remains nonterminal in `waitingForConnectivity`/`recovering` | one generated attempt after runtime is authoritative | original product timer keeps running; old attempt records its own accuracy | remains pending across attempt generation |
| Account switch, sign-out, selected-account removal, or reconciliation that changes the active credential | user-requested cause for explicit UI action; server cause for external invalidation | terminal interrupted; never continued under a different account | none | exact or lower bound | returns committed interrupted result |
| `.addAccount` staging login with unchanged selection | no effect on shared attempt/runtime | unchanged | none | unchanged | unchanged |
| Recoverable network loss | old attempt closes with transport interruption | remains nonterminal `waitingForConnectivity` | one generated attempt after verified reconnection | product timer keeps running | remains pending |
| Nonrecoverable protocol failure or app-server/process death | matching attempt fails/interruption is committed after connection/worker completion | terminal failed/interrupted according to typed cause | none | exact if supplied by turn; otherwise lower bound | returns committed failure/interruption |
| Application termination | system-request interrupt, terminal barrier, then forced close after grace if needed | terminal requested/transport interruption is committed before DB close | none | exact or lower bound | already-admitted waiter receives committed result or typed close failure |

Because every active review shares one AppServer client, a grace force-close is
a runtime-generation transition, not an attempt-local transport action. Its
ordering is fixed:

1. the target attempt's grace expiry enters the Store runtime owner;
2. before suspension, the Store changes the current generation to
   `transitioning(.recoveryReplacement, ...)`, closes new review/runtime
   admission, and records one replacement Task;
3. the explicit target continues toward its requested terminal, while every
   other active attempt ID in that generation is recorded in the forced-sibling
   recovery set;
4. the old AppServer client/process is force-closed exactly once;
5. each sibling worker consults that set before recording
   `.ownerForcedConnectionClose` as a product terminal and installs
   `.sameAccountRestart` recovery instead; a natural canonical terminal that
   linearized first remains authoritative;
6. if the Store remains `open`, the Host retains the old backend only for
   handoff/cleanup and creates one replacement client/backend pair even when the
   forced-sibling set is empty. The independent app-lifetime MCP owner keeps its
   current listener generation and receives no close/prepare/activate call;
7. after the Store activates and publishes the new AppServer generation, each
   eligible sibling resumes exactly once on the new backend, never on the closed
   old backend. With zero eligible siblings, publication still restores runtime
   availability; and
8. replacement creation/validation failure terminalizes all remaining eligible
   siblings with the same typed failure, publishes the Store runtime as failed,
   and leaves Store review/runtime admission closed. The existing MCP generation
   remains unchanged: a bound listener stays active, while a declared-no-MCP URL
   stays `nil`. Live read/status requests expose the failure and mutation tools
   return the typed runtime-unavailable result.

Once the old AppServer close signal is sent, an `open` Store always creates the
one replacement; sibling count is not a condition. A natural terminal that wins
before any old-runtime close signal means no runtime was lost, so the transition
is cancelled. A concurrent runtime-disable stop or application close suppresses
replacement through its explicit purpose and follows its MCP stop/terminal-
close contract. One replacement per sibling, resuming on the old backend, and
attempt-local retry/guards are rejected because they duplicate or bypass the
shared-resource owner.

An account change never silently becomes network recovery, and an intentional
same-account restart never terminalizes the product merely to simplify runtime
teardown. If recovery admission itself fails, the current row terminalizes with
that typed failure; it does not loop attempts.

### Persistence-failure transition

Any database open/migration/write/observation failure moves the application-
lifetime history owner to `failed` and closes review/UI/MCP mutation admission.
For a failure after live ingestion began, the processor stops consuming new
semantic events, rejects every new mutation with the original typed persistence
error, fails pending MCP waiters with `persistenceUnavailable`, and commands the
backend to interrupt/force-close every active transport and await its real
worker completion. Because the semantic terminal cannot be committed safely,
the in-memory processor does not fabricate or publish one: ReviewUI retains the
last-good rows with a visible failed phase. While failed, any last-good
nonterminal row renders a frozen, labeled lower-bound duration through its
`lastCommittedAt`/`observedThroughAt`; it never continues an `endedAt == nil`
wall-clock timer after the backend has stopped. Start/cancel/reorder/delete and
other mutation affordances are disabled, while read/selection remain available.
The database lifecycle remains unchanged until recovery. A later explicit full history
close/reopen performs startup-orphan recovery from `lastCommittedAt`; no
automatic retry or in-memory fallback continues the review behind SQLite.

If an individual transaction is rejected before commit, its global revision,
run/log rows, and receipts are all unchanged. If a query-generation replacement
alone fails while the existing observation remains healthy, only that paging
operation fails as described above; it does not poison the history owner.

`store.close()` has a separate failed-history branch. Every caller joins the
same close Task, which first joins the persistence-failure transition's
transport/worker close Task, performs no terminal/incomplete semantic write,
cancels query observations, and then physically closes `DatabasePool`. It throws
one `ReviewCloseError` whose aggregate `first` preserves the original
persistence error and whose additional values preserve every later runtime/
query failure in lifecycle order. If physical close also fails, the dedicated
secondary field retains it. Repeated close returns/throws the same complete
recorded result. This branch never re-enters normal close steps that require a
writable history owner.

### Canonical terminal and interrupt reducer (#104, #106)

One attempt-scoped reducer owns the final human result and terminal transition:

1. `ReviewStartResponse(reviewThreadId, turn.id)` fixes the canonical pair for
   the attempt. `item/completed` for that outer review turn with
   `item.type == exitedReviewMode` supplies the authoritative human-readable
   `review` result. Item lifecycle is canonical; the reviewer child thread and
   its structured JSON are excluded by recorded outer-thread/turn/attempt
   identity before content is inspected.
2. `turn/completed` supplies the authoritative terminal status. The pinned
   `ReviewTerminalOutputStrategy.currentV2` may use only the protocol's sparse
   summary field when no canonical `exitedReviewMode.review` item was delivered:
   the completed payload must match the canonical pair and contain exactly one
   nonempty, synchronous `agentMessage` in its documented final-message summary
   position. It never searches the accumulated log, generic `lastAgentMessage`,
   another thread/attempt, or arbitrary content. A reviewer child or internal
   async delivery therefore cannot be a candidate. The streamed
   `exitedReviewMode.review` always wins when both are present. Any future wire
   variant requires a separately versioned strategy and fixture; it is not a
   fallback added at a call site.
3. A `completed` turn without either valid human-result source is a visible
   product failure (`missingFinalReview`), not an empty successful review and not
   a JSON heuristic. `interrupted` maps to the typed interruption cause;
   `failed` preserves the optional upstream error rather than fabricating text.
4. A successful `turn/interrupt` response means only that the matching
   `(threadID, turnID)` cancellation request was accepted. The processor waits
   for that target turn's `turn/completed` or a typed connection terminal before
   committing product terminal and cleaning up. An explicit request rejection
   is the only response path that does not wait for an interrupt terminal.
5. If the matching terminal arrives before the interrupt response, the terminal
   wins and the later success response is an idempotent acknowledgement. An
   identical duplicate terminal is a no-op; a conflicting duplicate is a typed
   contract failure. An explicit interrupt rejection received after terminal
   does not rewrite the committed terminal but is retained as a diagnostic.
6. A request transport error does not itself prove whether interruption was
   accepted. The processor reconciles with the matching turn/connection; a
   definitive connection terminal wins over outcome-unknown request state. If
   the connection remains open without a turn terminal through the injected
   shutdown grace, the close owner force-closes it and waits for the actual
   connection/worker completion before committing forced-shutdown interruption.

No UI, MCP adapter, persistence mapper, or log renderer derives terminal state
or final review text independently of this reducer.

### Ingestion fault containment (#105)

External notifications never reach a production `precondition`/trap. The
decoder/router classifies failure before the reducer mutates history:

| Failure class | Scope and action |
|---|---|
| Unknown method outside review event families | Emit one bounded connection diagnostic and continue. |
| Invalid JSON-RPC framing, missing mandatory routing identity before an attempt can be selected, or one thread/turn identity mapped to conflicting active attempts | Connection-fatal: close that app-server connection, await worker completion, and drive every affected active attempt through the nonrecoverable protocol transition. |
| Known review/item event whose `(threadID, turnID)` selects exactly one current attempt but whose payload is malformed/unsupported | Attempt-fatal: record a bounded typed diagnostic, interrupt that matching turn, and terminalize only that product review as failed after its terminal barrier. Other reviews on the connection continue. |
| Event for a verified older attempt | May update only old-attempt receipt/terminal/diagnostic state; never product output/log/lifecycle. Identical replay is a no-op and conflicting replay is an attempt-local contract error. |
| Conflicting terminal or stable event payload for the current attempt | Attempt-fatal typed contract error; never overwrite the prior committed fact. |

If the identity conflict means the router cannot prove which attempt owns the
event, containment escalates to the connection rather than guessing. If writing
the diagnostic/failure transition itself fails, the persistence-failure
transition above takes precedence.

#### Review command versus standalone process output

The pinned current-v2 review stream uses
`item/commandExecution/outputDelta { threadId, turnId, itemId, delta }`. That
typed outer/turn/item identity is the only command-output delta admitted to a
review attempt in this recovery.

`command/exec/outputDelta { processId, ... }` and
`process/outputDelta { processHandle, ... }` belong to standalone,
connection-scoped APIs. Their handles have no documented namespace or equality
relationship with review `ThreadItem` IDs. ReviewMonitor does not issue those
standalone requests, so unregistered notifications are classified as non-review
traffic and cannot mutate or fail a review. They are not broadcast to active
attempts and are never matched by first string equality.

A future product feature that issues a standalone request must add one request
owner that registers `(connection, handle) -> (reviewID, attemptID, itemID)`
before sending, removes it on response/connection close, and routes base64 bytes
through that exact mapping. That is a new variant/design change, not a Wave 2
fallback. Until then, ReviewMonitor preserves the Unicode `delta` already
normalized by app-server for review command items; it does not base64-decode
unowned standalone chunks.

### Saved-account identity and artifact owner (#97, #107)

App-server `account/read` exposes one observed provider account and ChatGPT
email is nullable; it does not expose a stable account/user ID. Recovery never
derives identity from email, provider name, raw credential bytes, or the fixed
string `"api-key"`.

- The saved-account registry allocates one canonical UUID-backed
  `SavedAccountID` before login dispatch and records it in
  `AuthenticationDiskStateV1.reserved`. Its only valid serialized form is the lowercase
  hyphenated UUID string; generation, raw-value construction, and Codable decode
  all enforce that form. Crash replay of that operation reuses the ID, and the
  public `CodexAccount` normalization therefore preserves exactly the same key.
- Provider is `.chatGPT`, `.apiKey`, or legacy registry/runtime-only
  `.amazonBedrock`. `lastKnownEmail` is optional presentation metadata only. A
  nil read does not erase a previously known email; a new nil-email account
  displays `"ChatGPT"`.
- Equal/nil emails never implicitly merge accounts. Runtime refresh binds the
  observed account to an explicit saved ID or the registry active ID.
- Registry-produced public `CodexAccount` values pass
  `SavedAccountID.rawValue` as their explicit `id`/`accountKey`. The released
  nonoptional email/masked-email surface and initializer remain unchanged; an
  external caller that omits `accountKey` retains its existing normalized-email
  identity behavior. The compatibility label for a registry nil-email account
  is `"ChatGPT"`. Identity/presentation types stay package-only.
- The registry admits at most one API-key provider account. A second API-key
  sign-in/add-account fails before staging creation or secret unwrap. Implicit
  replacement/fingerprint comparison is not supported; remove then add creates
  a new saved ID.
- `.addAccount` for either provider requires an existing active saved ID. With
  no active account it returns a typed invalid-state error, never an implicit
  `.signIn` conversion or automatic activation.
- `CodexReviewAuthModel.hasActiveSavedAccount` is true only when RegistryV2's
  active ID resolves to a ready saved record and the selected public account is
  that projection. A detached/current-session account may keep public
  `isAuthenticated == true` for compatibility but cannot admit `.addAccount`.

Credentials are opaque immutable artifact revisions under
`SavedAccounts/<SavedAccountID>/revisions/<RevisionID>/auth.json`. ReviewMonitor
opens them relative to the reviewed #113 saved-account capability, validates
regular-file identity, owner-only mode/ACL policy, nonempty bounded size,
SHA-256, and byte count, but never decodes secret/JWT/account-ID content. File
and parent directory are fsynced before a revision can be named by the registry.
The authentication disk actor is the sole writer for RegistryV2, immutable
revisions, activation journal, primary runtime lease, and the versioned
authentication state manifest. Each uses descriptor-relative temp write + fsync
+ same-directory `renameat` + directory fsync; corruption or missing references
fail closed rather than becoming an empty registry.

```text
RecoveryV1/SavedAccounts/registry.json
  RegistryV2(schemaVersion, generation, contentHash, activeAccountID?, accounts[])
  account = id, provider, presentation, planType?, artifactRevision(id, sha256,
            byteCount), lastActivatedAt?, cached non-secret metadata
RecoveryV1/SavedAccounts/authentication-state.json
  AuthenticationDiskStateV1(schemaVersion, generation, contentHash, sessionState)
  sessionState = idle
    | staging(
        reserved | leased | outcomeUnknown
        | cleanupRequired(identity + discard|candidate(pending,artifact))
        | cleanupFailed(identity + continuation + typed kind/operation/code)
      )
    | candidate(ready | discardRequired | discardFailed)
RecoveryV1/SavedAccounts/activation-journal.json
  before registry generation/hash, complete desired registry bytes/hash,
  previous shared fingerprint?, desired artifact revision/fingerprint, phase
RecoveryV1/SavedAccounts/runtime-lease.json
  PrimaryRuntimeLeaseV1(schemaVersion, runtime generation, activeAccountID,
    base artifact revision/fingerprint, preallocated writeback revision ID,
    phase: running | writebackPrepared | registryPublished)
RecoveryV1/SavedAccounts/<SavedAccountID>/revisions/<RevisionID>/auth.json
RecoveryV1/LoginStaging/<SessionID>/auth.json
RecoveryV1/CodexHome/auth.json
```

`authentication-state.json` is the only durable owner of pending authentication,
login-staging identity, uncommitted candidate handoff, and cleanup debt. Its
session enum makes impossible combinations unrepresentable and permits at most
one authentication admission.
It stores one validated relative component plus descriptor identity, never an
arbitrary source/destination URL. `RecoveryEnvironmentPlan` and
`PreparedRecoveryEnvironment` do not create a second pending/cleanup manifest.
`contentHash` covers the canonical encoding with its own field omitted.
The primary `runtime-lease.json` is deliberately distinct from
`LoginStagingLease`: the former journals the shared Codex-home working copy;
the latter owns one isolated authentication session's live resources.

The existing unversioned saved-account registry is schema v0. Wave 5 performs
one validated, crash-safe conversion to RegistryV2 before auth/runtime
admission; it never edits v0 in place or treats decode failure as no accounts.
A durable migration journal assigns and preserves generated IDs across crash,
maps `activeAccountKey` only when it identifies exactly one entry, copies each
legacy mutable `auth.json` into one verified immutable revision, and then
atomically publishes v2. The v0 source key is exactly the nonempty result of
`accountKey.map(normalized).flatMap(nonempty)`, otherwise the nonempty normalized
email; if both are empty the entry is invalid. Its directory uses Foundation's
existing percent-encoding with
`CharacterSet.alphanumerics.union("-._~")` (including Unicode alphanumerics) and
special `.`/`..` encoding.
API key and Bedrock therefore resolve their fixed legacy keys rather than email.
No migration path is reconstructed from presentation text. Duplicate normalized keys, ambiguous active mapping,
multiple API-key entries, missing/corrupt referenced artifacts, or unsafe paths
produce a typed auth-migration failure while leaving v0 untouched and durable
review history readable. Existing `.amazonBedrock` entries are preserved as a
registry/runtime-selectable provider (no new login UI); they are not silently
dropped or counted as the API-key slot.

Before copying artifacts, `registry-v0.json` stores immutable original bytes and
the owner durably creates `registry-migration-journal.json`:

```text
source registry SHA-256
phase: prepared | artifactsCopied | v2Published
entries[]: source index, normalized legacy key, encoded source directory,
           assigned SavedAccountID, provider, source artifact relative path,
           desired revision ID/hash/byte count
resolved active SavedAccountID?
complete desired RegistryV2 bytes/hash
```

All assigned IDs and revision IDs are fixed in `prepared`, so every crash replay
reuses them. `artifactsCopied` is written only after all revision files/directories
are durable; `v2Published` follows atomic `registry.json` replacement. Journal
and immutable v0 backup are removed only after v2 reference validation. Existing
numeric/current-main account schema 0/1 import is a separate Wave 7 adapter and
never reuses this in-place RecoveryV1 migration locator.

`.addAccount` closes and awaits the staging app-server, writes one immutable
artifact revision, and atomically adds its metadata while leaving active ID,
shared auth bytes, and runtime generation unchanged. For `.signIn`,
`LoginSession` supplies the authoritative provider result to its lease; the
authentication disk actor durably writes only the preallocated unreferenced
candidate revision and hands `PreparedAuthenticationCandidate` to the Wave 5
activation actor; that actor
invokes the reviewed Wave 3 runtime-transition owner. `LoginSession`
does not create an activation journal or mutate the shared home. The runtime
owner first interrupts/commits affected reviews, closes and joins the old
runtime, writes back its working auth revision, and durably clears the old
runtime lease. It then rereads the latest registry generation and creates the
activation journal containing that exact before state, the desired registry
with candidate, desired artifact fingerprint, and previous active ID. The
journal is the product commit point; startup must forward-complete it before
auth/runtime admission. The owner then applies it to shared
`CodexHome/auth.json` and registry before starting the replacement.
Exactly one `.accountTransition` validates authoritative `account/read` before
runtime publication and durably removes the journal. Third-state journal/
registry/shared-auth combinations fail closed.
After journal commit, an incomplete activation returns
`.committedActivationPending` and blocks new authentication admission; it is
never thrown as an ordinary pre-commit error that the UI could retry with a new
session.

A valid state never has both an old runtime lease and an activation journal:
journal creation is admitted only after durable lease removal. Startup that
finds both treats it as persistence inconsistency and fails auth/runtime
admission rather than guessing an order.

One Wave 5-owned `AuthenticationActivationOperation` actor linearizes the
transferred LoginSession cancellation intent and journal commit while invoking
the reviewed Wave 3 account-transition/close owner:

```text
prepared(candidate, cancellationIntent)
→ quiescingOldRuntime
→ readyToCommit(latestRegistry)
  ├─ cancellation wins → restartingPrevious → discardingCandidate → terminal
  └─ committingJournal → committed → startingReplacement → terminal
```

It installs `committingJournal` synchronously before the first journal-write
await. Before acknowledging a cancellation that wins before that transition,
the actor asks the authentication disk owner to set
`candidate.ready.pending.cancellationIntent = true` durably. No journal is
created. After old-runtime quiescence it starts exactly one replacement for the
previous active account, moves the candidate to `candidate.discardRequired`, and
descriptor-safely removes only that preallocated unreferenced revision. Removal
failure becomes `candidate.discardFailed` and blocks new authentication; it does
not activate the candidate. Startup seeing the durable cancellation intent
never resumes activation: it restores the previous RegistryV2 runtime when
otherwise valid and resumes candidate discard. If that runtime restart fails,
runtime state becomes visibly failed. Cancellation after `committingJournal`
loses to success/activation-pending and cannot rewrite the commit. LoginSession
transfers its root/cancel ownership into this actor and cannot independently
persist cancellation afterward.

On startup, forward-completing an activation journal first consumes any exactly
matching `candidate.ready` handoff, applies desired shared bytes/registry, keeps
the journal, and passes the desired active ID into the one
primary `PreparedRuntime` start. That runtime's authoritative account read is
the validation; only a match publishes the runtime and removes the journal.
Failure retains `.committedActivationPending` and the same ID/journal. It does
not create a second isolated validation runtime or a second primary start.

The shared auth file is a runtime working copy because app-server may refresh
tokens. Before launch, `PrimaryRuntimeLeaseV1` records active saved ID, runtime
generation, base artifact revision/fingerprint, and one preallocated writeback
revision ID. After app-server close, the verified working copy is written only
to that ID, fsynced, and marked `writebackPrepared`; RegistryV2 is then published
to reference it, the lease is marked `registryPublished`, and only then cleared.
Startup validates/completes each file/registry/lease boundary idempotently and
never scans for a latest revision. A leftover running lease reconciles with an
isolated provider read or fails closed; email never decides whether it is a
different account.

#### Login staging lease and cleanup debt

One Wave 5 `LoginStagingLease` actor owns the staging directory capability,
staging runtime/client, every registered reader/writer Task, and one joined
close result. `LoginSession` owns provider semantics and native presentation;
the authentication disk actor owns durable state. Neither may create a parallel
cleanup path.

The in-memory lease state is exact:

```text
preparing(sessionID)                       // no capability published
  -> open(resources, directoryIdentity)    // new tasks may register
  -> closing(resources, one closeTask)     // admission closed before first await
  -> closed(Result<LoginStagingCloseOutcome, LoginStagingCloseError>)
```

Concurrent/repeated close callers join the recorded `closeTask` and receive the
same result. `open` contains the real runtime/client and registered Task handles,
not booleans saying that they were cancelled. Close rejects new tasks, asks the
reviewed Wave 3 runtime handle to close, and joins the client/readers/writers.
For a confirmed provider result, the close Task then asks the authentication
disk actor to copy the opaque staging artifact into an immutable unreferenced
revision at the ID preallocated in `PendingAuthentication`; this disk operation
is one of the lease-owned writers. A crash before/after rename/fsync reopens only
that exact ID and validates or completes it. Only after resource completion and
the candidate write are proven may the actor commit
`staging.cleanupRequired(.candidate(...))` and perform descriptor-relative
removal. After successful removal, it advances to `candidate.ready`;
discard advances to `idle`. For `.addAccount`, the disk actor publishes
RegistryV2 first and clears `candidate.ready` only after the registry durably
references that exact candidate; startup treats an already-matching registry as
idempotent completion. For `.signIn`, `candidate.ready` remains durable while the
Wave 5 activation actor quiesces the old runtime and is cleared only after a
matching activation journal becomes the next durable owner. Startup accepts the
temporary pair only when candidate identity matches exactly, clears the old
state, and forward-completes the journal. A crash before either next-owner commit
therefore resumes `candidate.ready` without the removed staging directory.

An authentication result whose write/outcome is unknown produces
`.retainedForReconciliation(sessionID)` after all live resources close. The
durable state becomes `outcomeUnknown`; the exact manifested directory is kept
for a same-home startup read and new authentication admission remains blocked.
This retention is intentional, not a cleanup success or a log-only warning.

`LoginStagingCloseError` requires one typed primary failure. When resources fail,
the primary is a nonempty aggregate ordered as runtime first, then client/reader/
writer Tasks by registration ordinal, then the close-owned candidate write; no
joined Task failure is lost.
Every later cleanup/debt-persistence failure is preserved in operation order, and
the error records whether the exact durable debt state was written or that write
itself failed. Runtime failure retains `ReviewRuntimeCloseFailure`; other work
retains a typed task owner/operation/code rather than only display text. If
runtime/process completion is not
proven, removal is not attempted. A manifest write failure also prevents
removal because no durable owner would authorize it. An identity/policy mismatch
or descriptor-relative removal failure preserves the directory, atomically
records `cleanupFailed` when possible, blocks authentication admission, and is
returned to normal/application close. No error is reduced to a log message.

Before creating a staging leaf, the authentication disk actor first commits
`staging.reserved` with one generated session ID, candidate account ID,
candidate revision ID, and relative component. It
then creates/reopens the leaf through the login-staging root capability and
commits `staging.leased` with its exact descriptor identity before publishing the lease.
A crash at either boundary therefore resumes the same ID: missing reserved leaf
can be cleared, while an identity-matching leaf is reconciled or removed through
the manifest. A directory with no manifest, or a manifested directory whose
identity changed, is preserved and reported as a typed persistence inconsistency;
it is never guessed to be an orphan and recursively deleted.

Startup opens RegistryV2 and `authentication-state.json` through the descriptor
owner before auth/runtime admission. It forward-completes or reconciles
every `staging` and `candidate` case using the same lease/removal/adoption
primitives. A replay from `staging.leased` uses the preallocated revision ID to
validate or finish an already-renamed candidate before moving to
`cleanupRequired(.candidate)`. Cleanup removes only a manifested,
identity-matching directory when `staging.cleanupRequired` is the sole durable
authority and every live-resource/other-record reference is absent. That state
retains any continuation needed after removal. History remains readable and new
authentication admission remains closed on debt. A prior RegistryV2 account may
start only when RegistryV2/runtime-lease/activation state is independently
authoritative; staging/candidate debt never chooses or changes that account.

### ChatGPT login state machine (#107)

One `LoginSession` owns provider state, the app-server login handle, native
presentation, completion observation, and cancellation intent. Its one
`LoginStagingLease` owns the isolated recovery home capability, staging
app-server/client/readers/writers, and close/removal completion. Authentication
never writes first to the active shared `RecoveryV1/CodexHome`: upstream login
persists credentials before returning success, so doing so would let
`.addAccount` replace the active account before product adoption.

`AuthenticationClosePolicy` injects `providerEventGrace`,
`reconciliationGrace`, and the suspending clock (production defaults 10 seconds
each; tests use controlled gates). A grace expiry triggers staging connection/
process close and a fresh same-home read; it is never treated as success or as
proof of cancellation. Reconciliation expiry records typed outcome-unknown,
retains `AuthenticationDiskStateV1.sessionState.staging(.outcomeUnknown)` plus
staging, joins all session Tasks, and lets
`LoginSession.close()` finish rather than wait indefinitely.

1. Current app-server login start returns typed `loginId` and `authUrl` and
   starts its localhost callback listener.
2. ReviewMonitor presents `authUrl`. `ASWebAuthenticationSession` is a display
   container only; it never forwards a callback URL to Codex and the retired
   `account/login/complete` request is not implemented.
3. Set `prefersEphemeralWebBrowserSession` and presentation context before
   `start()`.
4. Missing native configuration/anchor, `canStart == false`, `start() == false`,
   or presentation-context unavailable opens the same URL in the external
   browser once and continues observing the app-server login.
5. User/native cancellation requests app-server
   `account/login/cancel(loginId)` and awaits its acknowledgement plus the login
   observation Task. `notFound` is a race requiring reconciliation, not proof of
   cancellation. The durable cancellation intent linearizes with the activation
   journal commit: cancellation admitted first prevents ChatGPT artifact
   adoption even if provider success arrives later; a journal committed first
   is success/activation-pending and cannot be relabeled cancelled. Other
   presentation failure is typed and closes the login.
6. Matching successful `account/login/completed` moves to
   `completedSuccessAwaitingPostCompletionAccountUpdate`. A prior
   `account/updated` is ignored because upstream sends completion before
   `auth_manager.reload()`. Only the next typed ChatGPT account update followed
   by `account/read` from the same staging home is authoritative success;
   `email == nil` is valid. Missing/malformed update, read failure, or connection
   loss is outcome-unknown and is reconciled by a fresh app-server read of that
   same staging home, never by resending login. UI callback arrival is never
   success.
7. After authoritative success, close through `LoginStagingLease` with the typed
   adoption disposition. Its close Task joins the app-server, writes the
   immutable candidate, removes the manifested staging directory, and returns
   only after the disk actor reaches and consumes `candidate.ready`. `.signIn`
   then transfers the returned candidate to activation; `.addAccount` leaves the
   existing active ID, shared artifact, and runtime byte-for-byte unchanged.
8. `LoginSession.close()` finishes/cancels presentation, prevents later
   callbacks, requests SDK cancellation when required, awaits its provider root
   Task, and then joins `LoginStagingLease.close()`. Concurrent cancel/close
   callers join the same provider and lease completions.

Staging runtime close uses the same typed process/connection completion
contract as Wave 3. It awaits the real process terminal (force-closing through
the injected policy when needed) before reporting an auth terminal or deleting
staging. Failure is retained as `LoginStagingCloseError.primary` plus exact debt;
during application close it contributes a typed runtime close failure and can
never be reported as a clean close or detached Task.

External-browser open failure, login cancellation failure, stock completion
failure, and account-read failure remain distinct typed errors. A second login
cannot start while one session owns admission.

### API-key credential state machine (#97)

ReviewMonitor owns only the single-use submission, never the credential. The UI
clears its text buffer before awaiting and passes a redacted `CodexReviewAPIKey`
exactly once to the authentication session's isolated staging app-server via
`account/login/start(type: apiKey)`. Observable auth state,
review history, preferences, logs, diagnostics, and crash metadata never retain
the raw value. After that request, only the staging app-server credential store,
then the recovery-owned opaque saved-account artifact and explicitly activated
shared Codex home may persist it, matching the current Codex restart contract.

Upstream sends the immediate `{ type: "apiKey" }` response only after saving the
file credential and reloading auth, but product success still requires the same
staging runtime's authoritative `account/read == .apiKey` plus durable artifact
adoption. The transport owner records write admission as `.notWritten` or
`.mayHaveBeenWritten`. Pre-write cancellation sends no request and cleans up;
post-write cancellation sends no ChatGPT cancel RPC, keeps the root request
Task, and lets confirmed success/read win. A known rejection is no-commit.
Response/notification/connection loss after write is outcome-unknown and uses a
fresh app-server read of the same staging home: `.apiKey` commits, no account is
no-commit, another provider is protocol failure. It never resends or retains the
raw key. If reconciliation is impossible, the durable authentication-state
entry blocks a new authentication attempt until resolved. Concurrent authentication requests
are rejected while the session owns admission. After authoritative read, the
same revision/journal rules apply: `.signIn` activates after durable adoption;
`.addAccount` preserves the existing active artifact/runtime. Staging closes and
deletes only after all writers complete. ReviewMonitor never reloads or decodes
the API key itself.

The secret-bearing API-key request uses `AppServerClient.sendOneShot`; it
allocates one request ID, performs no app-server-overload retry, and calls the
transport's `sendOneShot` once. The process transport atomically calls
`writeGate.admitWrite()` immediately before stdin write. A false decision sends
zero bytes; after true, state remains `.mayHaveBeenWritten` even if write/
response fails. Generic `send` and its overload retry are never used for raw
credentials.

### Startup and shutdown

Startup order:

1. Build `RecoveryEnvironmentPlan` without opening the legacy source. Through
   the reviewed #113 storage actor, walk/create/reopen the managed components and
   produce one `PreparedRecoveryEnvironment`; then construct an inert store with
   a capability-backed `ReviewHistoryConfiguration`. No raw URL opens GRDB or a
   Process.
2. Construct the window/controllers against the inert store. The history shell
   renders `.loading`, not a successful empty list.
3. When `ReviewHistoryConfiguration.startupPreparation` is present,
   `store.start()` invokes only that opaque CodexReview closure before
   observation/runtime admission. The Host-owned coordinator behind it validates
   an existing admission or performs snapshot/import/preferences/auth and returns
   `.ready`, `.authenticationRequired`, or `.authenticationFailed`. A thrown or
   non-history-admitted preparation starts no query, MCP, or app-server.
4. For every returned disposition—including `.authenticationFailed`—run
   startup-orphan recovery, apply optional preview/test bootstrap through
   the writer only to a brand-new empty non-cutover DB, start the history
   subscription, await its first atomic snapshot, and publish
   `.loaded` or a visible typed `.failed` state. A history failure does not
   start MCP or app-server.
5. Resolve the Codex executable once for the app lifetime.
6. For `.ready`/`.authenticationRequired`, before primary runtime/MCP admission,
   have the authentication disk actor open RegistryV2 and the versioned
   pending/debt state through the prepared capabilities, then recover in this
   order:
   migrate RegistryV0→V2; reject the invalid simultaneous old-lease+journal
   state; reconcile a leftover runtime lease; forward-complete an activation
   journal; reconcile the exact reserved/leased/outcome-unknown/cleanup-debt
   staging state; materialize exactly one desired active artifact into the
   shared home; then have the Store call the generation-bearing
   `CodexReviewStoreBackend.prepareRuntime(generation:purpose:)` seam and
   account-read-validate exactly one inert, un-published primary
   `PreparedRuntime` against that artifact. Separately, the stable Host-owned
   `MCPServerLifecycleOwner` prepares one inert MCP listener generation because
   it is currently `stopped`; the AppServer `PreparedRuntime` contains neither
   that generation nor its server URL. Journal completion uses the same prepared
   AppServer runtime and never recopies shared auth after it starts.
   `.authenticationFailed` skips this step and retains the loaded history with a
   visible auth error.
7. Only after history and auth recovery are authoritative, the Store
   revalidates the exact AppServer generation, activates the exact prepared
   handle, revalidates again, and atomically retains it plus its auth/settings
   snapshot. It then activates/binds the exact prepared MCP generation, receives
   the actual non-`nil` bound URL (including an assigned port for configured
   port 0; no-MCP test/preview composition instead returns `nil`),
   revalidates that same MCP generation, and only then publishes the URL and
   opens MCP network admission. Process launch performs the #113 last-moment
   executable/home capability revalidation. There is no second primary start.
   Auth recovery, either generation revalidation, or activation failure closes/
   admission-stops and awaits every resource its transition acquired exactly
   once; no stale AppServer snapshot, pre-bind URL, or `:0` URL is published.

Preview/XCTest compositions that intentionally keep the embedded runtime inert
still execute steps 1–4 against a unique temporary database. Their synchronous
factory returns an inert `.loading` store; component/app lifecycle owns the
async `start()` Task and selects seeded content only after the first query
snapshot. There is no direct preview mutation of `jobs`/`workspaces` and no
global/default preview database.

History visibility is independent of transport and authentication gates.
`serverState` controls command availability/status, and authentication controls
review/account actions, but neither replaces a loaded history sidebar/detail
with an unavailable or sign-in root. `ReviewHistoryQuery.Phase` alone selects
history loading/error/loaded/empty presentation. Signing in can be presented in
the account pane or as an action affordance while prior review history remains
readable.

`store.stop()` and `store.restart()` operate below the history lifetime. Stop
also drains/physically stops the current MCP lease but keeps its app-lifetime
owner reusable so later `start()` can create a new lease; restart and
recoveryReplacement retain the current MCP lease. Neither operation closes
history or its queries. `store.close()` is the domain/runtime lifetime authority
and terminalizes the MCP owner. The application composition owner performs
`await windowController.closeAndWait()` first so ReviewUI cancels and awaits its
own render/selection tasks, and only then performs `try await store.close()`.
The store does not reach upward to close ReviewUI.

`closeAndWait()` quiesces UI tasks/observations but preserves the last rendered
snapshot until the application termination decision. If `store.close()` throws,
ReviewMonitor presents one explicit application-owned alert: **Cancel Quit** is
the default and replies `false`, retaining the frozen last-good/error UI with
all mutation admission closed; **Quit Anyway** replies `true` only after the
user explicitly accepts the risk that the latest state/resource close was not
confirmed. No close error silently becomes successful termination. Repeated
Quit joins the recorded close result and presents the same decision rather than
starting a second shutdown sequence.

The existing nonthrowing lifecycle methods keep source compatibility after
close: `start()` and `restart()` are documented no-ops once closing begins,
`stop()` during close joins the runtime-stop portion and is a no-op after closed,
and review/MCP mutations use their existing throwing surface to report the typed
closed error. None of these methods reconstructs a second live owner after app-
lifetime close.

`CodexReviewStore` owns one app-lifetime state and one recorded close Task for
both normal and failed-history shutdown:

```text
open(
  appServerGeneration,
  appServer: stopped
    | acquiring(ownedTask)
    | running(preparedRuntime)
    | transitioning(purpose, ownedTask, forcedSiblingAttemptIDs)
    | failed(ReviewLifecycleResourceFailureAggregate, admission: closed),
  mcpServerOwner: one stable app-lifetime owner identity
)
  -> closing(invalidatedAppServerGeneration, closeTask)
  -> closed(Result<Void, ReviewCloseError>)
```

The Host-owned MCP owner has one independent state, not mirrored Store flags:

```text
stopped
  -> preparing(generation, ownedTask)
  -> running(generation, bound(oneLease) | declaredNoMCP)
  -> stopping(ownedTask)
  -> stopped

stopped | preparing | running | stopping
  -> closing(oneCloseTask)
  -> closed(recordedResult)
```

The owner identity spans the app lifetime, while runtime-disable stop/later
start use sequential listener leases (or explicit no-MCP generations). There is
never more than one preparing/running/stopping lease.

The first `close()` installs `closing` and invalidates the runtime generation
before its first suspension. Concurrent/repeated `close()` callers join that
same Task/result; `stop()` during close joins the Task's runtime-stop stage.
Every `start()`/`restart()` operation captures the open generation before an
external await and revalidates it afterward. A stale late completion cannot
publish runtime/history/observation state or start another generation; any
resource it acquired is transferred to the installed close Task and awaited
there. Normal and persistence-failed close are branches of this one authority,
not separate caller-owned shutdown sequences. Wave 4 inserts durable terminal,
query, and database stages into the same Task rather than adding another close
owner.

AppServer preparation is inert and never mutates Store state during its awaits.
The Store registers the acquisition Task before its first external await, then
revalidates the exact `ReviewRuntimeGeneration` after preparation and after
`RuntimeLifecycleHandle.activate()`. Only it atomically retains the handle and
publishes the auth/settings-only `RuntimePublicationSnapshot`. `PreparedRuntime`
and its handle can reach no MCP owner, listener, lease, or server URL. A stale
prepared handle first closes its AppServer admission, sends every throwing
client/process close signal before its combined physical completion wait, and
always calls the throwing idempotent completion proof; its snapshot is never
published.

Initial `start()` and `start()` after a runtime-disable `stop()` separately ask
the stable MCP owner to prepare one inert `MCPServerGeneration`. After exact
generation revalidation and AppServer publication, the Store activates that
exact MCP generation. Binding completes inside `activate`, which returns the
actual `MCPServerPublicationSnapshot`; after revalidating the same MCP generation
again, the Store publishes that returned optional URL. A Live owner must return
non-`nil`; an explicit no-MCP Direct/Preview/Testing owner returns `nil` and may
not synthesize a default/loopback URL. `prepare()` has no publication snapshot,
so port-0 configuration cannot leak an unbound `:0` URL. Stale preparation/
activation is stopped/awaited and never published. `restart()` is one recorded
transition Task, not `await stop(); await start()`.

The ownership boundary is exact:

- the Store close Task owns and awaits its runtime transition/acquisition Tasks,
  review workers/admissions, rate-limit driver/in-flight refresh, and Store
  attempt/cleanup Tasks;
- the replaceable AppServer handle owns only Host auth observation, transport
  reader, notification router, backend event sessions, client, and process; and
- the app-lifetime MCP owner owns only its generation/lease, listener, protocol
  sessions, network admission, and admitted-handler registry.

The private AppServer notification router and review-event sessions cannot be
awaited from Host. Wave 3B therefore adds one package lifecycle seam to their
existing owner, `AppServerCodexReviewBackend`. Before its first await, that seam
is called after AppServer generation admission closes, so the set is finite. It
captures the exact `notificationRouterTask` and current sessions in a lifecycle-
only registration ordinal; it invokes the existing throwing client close, then
regardless of that result directly awaits
the captured router Task and finishes/awaits the captured sessions. It returns
only after semantic shutdown and reports every resource failure through
`ReviewLifecycleResourceFailureAggregate`. It never polls a Bool or uses
`Task.yield()` as completion proof. Decoder/reducer/routing policy and
`ReviewAttemptProcessor.swift` remain unchanged.

Within a bound running MCP lease, `accepting(admittedHandlerRegistry)` becomes
`stopping(networkAdmissionClosed, finiteAdmittedHandlers)` and then `stopped`;
an explicit no-MCP running generation stops without fabricating a listener;
application close instead becomes terminal `closing` and `closed`. The owner
registers before dispatch, removes only after completion, rejects requests that
linearize after admission close, and drains the finite registry before
listener/session disposal. Untracked NIO-created handler Tasks are removed.

`restartSameAccount` and `recoveryReplacement` preserve the current running MCP
generation without closing admission or creating a second lease. Runtime-disable
`stop()` closes/drains/physically stops the current lease and leaves the owner
reusable at `stopped`; a later released `start()` prepares a new lease.
Application `close()` terminalizes the owner and forbids later prepare/activate.

Normal Store close order after UI close is exact:

1. Before the first suspension, install Store `closing` and synchronously close
   Store mutation/review/runtime admission. Then close AppServer generation
   admission and ask the MCP owner to close listener/network admission as its
   first mutation before any handler-drain await.
2. Request active review cancellation as required by the transition purpose.
3. Wait for the authoritative turn terminal or a typed connection terminal.
4. Commit the final/incomplete lifecycle state, await all history writes, then
   publish terminal state and finish admitted review/MCP waiters. In Wave 3B
   this is the in-memory finish insertion point; Wave 4 supplies the durable
   commit without changing the owner or surrounding order.
5. Ask the MCP owner to drain every already-admitted handler in registration
   order, send all listener/session terminal-close signals, and await physical
   MCP completion. Record every signal/drain/wait failure and continue.
6. The Store close Task cancels and awaits every Store-owned runtime transition/
   acquisition, review worker/admission, rate-limit driver/in-flight refresh,
   and Store attempt/cleanup Task.
7. Only after Store cleanup, call the throwing AppServer
   `RuntimeLifecycleHandle.close(purpose:)`. Its one recorded Task issues the
   client/process close signal through the backend owner seam before directly
   awaiting its captured router/session handles; the method may
   then join physical client/process/reader and all Host auth/router/event-
   session completion before returning or throwing, matching the existing
   AppServer client/transport contract.
8. Regardless of step 7 success, call the throwing `waitUntilClosed()` to join
   that exact recorded Task/result and prove Host auth observation, reader,
   router, event-session, client, and process completion. Do not append a
   replayed step-7 failure twice.
9. Invalidate the query generation and close the store-owned history query
   subscriptions.
10. Close the database, assemble the complete result, and release the owner.

Wave 3B ends after step 8 and records one replayable close result. Wave 4 moves
that final recording after the history/query/database work shown in steps 4, 9,
and 10 within the same Task; it does not create a second shutdown sequence.

Step 3 uses an injected `ReviewRuntimeClosePolicy.terminalGrace` (production default
10 seconds; tests use a fake clock). Expiry is a force-close trigger, never proof
of completion: the Store invokes the old handle's combined transport/process/
Host close and separately awaits every Store-owned review worker, then commits
`.interrupted(.transport(message: forcedShutdown))` with the last committed
timestamp as the duration lower bound. A real matching turn terminal that
committed first remains authoritative. Force-close failure is a typed close
failure and cannot be reported as a clean shutdown; there is no second timeout
that abandons live tasks or database writes.

The forced branch differs at the semantic publication boundary: grace expiry
calls the exact old AppServer handle's throwing combined close; its recorded
Task sends the close signal before physical completion waiting. The Store
records that result once, then calls the throwing idempotent completion proof and
separately awaits affected Store-owned review workers. Only after Host
connection/process termination and no worker can publish upstream terminal does
the Store commit/publish the forced transport interruption and finish waiters.
It then resumes
MCP drain and remaining Store cleanup; normal close joins the already-recorded
AppServer combined-close result rather than signaling twice. A canonical terminal
that already committed remains authoritative.

The Store close Task is the only error assembler. It appends every typed failure
in the selected branch's declared order—the numbered normal order or the forced
signal/wait-before-publication sequence; within a concurrently joined Store or
Host stage, registration ordinal—not completion timing—defines order. The
nonempty `ReviewCloseFailureAggregate` stores `first` plus every
`additionalInLifecycleOrder`. A failure never skips a later close/wait stage.
Wave 3B cannot generate persistence failure, so
`secondaryPhysicalDatabaseClose` is `nil`. In the future failed-history branch,
the original persistence failure stays in the aggregate and only an additional
physical database-close failure uses the secondary field; physical close as the
sole failure is the aggregate's `.persistence(.close)` first value. MCP drain/
listener, Store worker/rate-limit/cleanup, AppServer signal, and Host auth/
reader/router/session/client/process failures are never log-only. Every close
caller receives the same recorded result. Store review-worker/attempt-cleanup
failures remain the existing Wave 3A `ReviewRuntimeCloseFailure`; Wave 3B MCP/
rate-limit/Host lifecycle failures use only
`ReviewLifecycleResourceFailureAggregate`.

`deinit` only cancels synchronous observation tokens as a backstop. It is not
the owner of async shutdown.

### Legacy import contract (#108)

The importer recognizes only pinned current-main inputs and never scans content
heuristically for something that merely looks like a review.

Issue #108 consumes the reviewed #113 descriptor core for both its read-only
source walk and every RecoveryV1 destination mutation. Locator URLs are input
descriptions only. The snapshotter opens the selected source from an explicit
trusted ancestor component by component, records descriptor identity in its
manifest, and performs allowlisted reads/copies relative to those descriptors.
The cutover coordinator receives the already prepared destination capabilities;
it never reconstructs a writable destination from the source or a canonical URL.

`CurrentMainSourceLocator` reproduces the pinned current-main root precedence in
one versioned adapter. An absent old preference means `.defaults`; a present
malformed preference is a typed migration refusal rather than a guessed root.
Use a valid nonempty normalized legacy
`codexReview.runtimePreferences.codexHomePath`, otherwise current-main
`CODEX_HOME`, otherwise nonempty environment `HOME/.codex_review`, otherwise
the FileManager user Application Support `CodexReviewMonitor` directory, and
finally `homeDirectoryForCurrentUser/.codex_review`. Each candidate string is
only a locator description: the snapshotter opens it component by component from
its declared trusted ancestor and compares descriptor ancestry/identity against
the prepared destination. Every custom root, not only the default, enters that
source/destination rejection boundary. A spelling/canonicalization result never
authorizes overlap or traversal.

The snapshot allowlist is exact. Unknown `*.sqlite*` means a newer unsupported
layout and fails closed.

```text
installation_id
review-thread-retention.json
sessions/**/rollout-*.jsonl[.zst]
archived_sessions/**/rollout-*.jsonl[.zst]
sqlite/state_5.sqlite[-wal|-shm]
sqlite/logs_2.sqlite[-wal|-shm]
sqlite/goals_1.sqlite[-wal|-shm]
sqlite/memories_1.sqlite[-wal|-shm]
sqlite/queue_1.sqlite[-wal|-shm]
sqlite/thread_history_1.sqlite[-wal|-shm]
accounts/registry.json
accounts/mutation-journal.json
accounts/reconciliation-debt.json
accounts/temporary-home-cleanup-debt.json
provider-filtered accounts/<encoded-key>/auth.json
provider-filtered accounts/<encoded-key>/revisions/<revision>.json
provider-filtered shared auth.json
```

Review semantics come only from `state_5`, `thread_history_1`, and referenced
rollouts; the other database cohorts are copied for snapshot/rollback integrity
and never interpreted as reviews. Account registry/debt JSON is copied exactly.
After decoding provider metadata, only ChatGPT/Bedrock opaque artifact paths are
admitted; API-key shared/account/revision paths are excluded before any open,
copy, read, or hash. There is no recursive source-root/accounts copy. Credential
files are handled only by the typed auth adapter below. UserDefaults
input is limited to bundle-domain values `codexReview.runtimePreferences`
(`Data`) and `CodexReviewKit.ReviewMonitor.sidebarReviewChatFilter` (`String`);
the full plist and existing window frame are not copied.

Import preflight requires a quiescent source. The current-main ReviewMonitor,
its app-server, and all known source-database writers must be stopped; the
importer verifies that no writer holds the source database/home. It then copies
only the exact allowlisted/provider-filtered files, relevant preference values,
and every SQLite database together with its WAL/SHM at one verified quiescent
boundary. It records before and after manifests and admits parsing only when
they match. Journal/debt recovery and SQLite validation run on the staging copy,
never the source. An active or changing source produces a typed refusal with no
destination mutation. It never guesses that a directory copy taken during
writes is consistent.

`CurrentMainSourceSnapshotter` rejects another
`lynnpd.CodexReviewMonitor` process and uses `/usr/sbin/lsof` machine-readable
output twice (preflight and post-copy). The snapshotter compares lsof device/
inode fields with the already opened manifest capabilities: any open FD matching
a known SQLite/WAL/SHM identity or any writable FD matching another allowlisted
source is a typed refusal including PID and command. Lsof path spelling is
diagnostic only and cannot establish a match or exemption. App-server ownership
is proved by actual descriptor identity, not process-name/path matching. Old
UserDefaults values are exact-compared before/after. The importer never opens
source SQLite because even a read can mutate WAL shared memory.

For each quiescent SQLite cohort it byte-copies main/WAL/SHM into raw staging,
verifies the complete before/after source manifest, then runs `sqlite3_backup`
and `quick_check` on the staging copy. Direct online backup from the source is
not an approved active-writer/read path. The deterministically sorted manifest records
relative path, file type/mode/size, non-secret SHA-256, sidecar existence,
preference hashes, and adapter/importer version. Credential digests never enter
the source fingerprint or cutover manifest; API-key artifact bytes are not
copied, read, or hashed.

- Source fingerprint: SHA-256 of a length-prefixed tuple containing
  `"current-main-source-v2"`, lowercase installation UUID, account schema token
  `absent|0|1`, and the opened legacy-root volume identifier + inode identity;
  path spelling/canonical URL and credential bytes do not enter the fingerprint
  or manifest.
- Eligible review: `thread_source == user`, non-SubAgent/internal source, stable
  outer thread/turn identity, same-pair stable `enteredReviewMode` and
  `exitedReviewMode`, matching typed turn terminal, and one nonempty canonical
  `exitedReviewMode.review`. Reviewer/compact/spawn/memory/other subagents are
  excluded by metadata before content inspection. Thread-only, missing/cross-
  turn/multiple marker rows are typed skip/failure manifest entries.
- Deterministic IDs use canonical length-prefixed tuples. `reviewDigest` is
  SHA-256 of source fingerprint + outer thread ID + review turn ID;
  `ReviewID = legacy-v1:<hex>` and
  `ReviewAttemptID = legacy-attempt-v1:<hex>`. Effective log IDs add upstream
  item ID and semantic subindex. Content, email, and process handle are never
  identity. Re-running addresses the same rows.
- Duration precedence is nonnegative upstream `durationMs` exact, valid
  start/completion exact, start→last committed event lower bound, otherwise
  unavailable. Wave 4 stores an exact-duration scalar when timestamps are
  absent; it never back-calculates `endedAt` or substitutes thread recency.
- Logs: normalize eligible outer-turn events through the same pinned reducer as
  live ingestion. Never import reviewer child JSON as user content.
- Auth: the #108 adapter accepts current-main numeric account schema 0/1 and
  produces typed ChatGPT/API-key/Bedrock inputs, never a source path. ChatGPT/
  Bedrock opaque artifacts enter Wave 5 immutable revision/RegistryV2 import;
  active ChatGPT materializes only through the activation journal and current
  app-server read. Invalid/expired artifacts require normal sign-in without
  discarding imported history. API-key bytes are never copied/read/hashed; only
  non-secret “reauthentication required” metadata enters the cutover manifest,
  no placeholder RegistryV2 account is created, and a legacy active API key
  starts signed out for #97 single-use input. External cleanup debt is a typed
  refusal and never authorizes deleting the legacy path.
- The adapter submits one ordered `CurrentMainSavedAccountBatchImport` with
  source fingerprint/schema/legacy active key. The Wave 5 registry actor alone
  assigns crash-stable saved IDs, writes its migration journal, maps active key,
  and commits the batch. Missing/invalid ChatGPT/Bedrock credentials use the
  reauthentication case and create no ready RegistryV2 record; their sanitized
  metadata remains in the cutover manifest. `VerifiedOpaqueArtifact` can only
  be constructed by the snapshotter beside its fileprivate initializer after
  descriptor identity/policy/hash validation. Cutover crash resume asks that snapshotter to
  revalidate the verified snapshot and reconstruct the in-memory value; secret
  digests are not persisted in the cutover manifest and Wave 5 has no second
  factory.
- Preferences: validate and import only MCP host/persisted port/path, Codex
  executable path, and the sidebar filter mapping `all|running|latestFinished`
  from the old key to the new key. Do not import Codex home/history/source paths
  or process-only test port. Legacy values remain unchanged; a different
  existing destination value is a conflict, never an automatic merge.

`ReviewCreation` imports canonical outer cwd as workspace (missing/invalid is a
failure), a non-authorizing audit session ID
`legacy-session-v1:<source-fingerprint-prefix>`, the entered-review text as
target display summary without guessing a git target, optional model from outer
metadata, no email/account binding, and default recency/manual order from
terminal or observed-through time plus `ReviewID`. Terminal summary/result come
from the typed reducer, not creation. Wave 4 `reviewRuns` includes nullable
`durationExactMs` alongside start/end/observed-through and accuracy so a valid
duration-only import is representable.

Live and import share one extracted current-v2 item/terminal normalizer and Wave
4 writer primitive; there is no import-only reducer. Stable completed items are
fed in source rollout/event ordinal and original turn-item order, with semantic
subindex only inside one source item; they are never sorted by item ID. Canonical marker/companion
suppression, grouped replacement, and 256 KiB policy run once in the writer.
Reviewer child JSON never enters the reducer.

Compressed `.jsonl.zst` is required. The standard adapter creates a sanitized
home from the verified snapshot. The snapshot manifest records each enumerated
rollout's exact source-field spelling together with its descriptor-derived
relative component sequence and copied-file capability. The adapter accepts
only an exact manifest key and substitutes that capability; it never canonicalizes
an arbitrary rollout path, proves containment by prefix, or heuristically
rebases an outside path. The adapter omits source auth/config/AGENTS,
launches the single Wave 5-resolved pinned Codex executable, and performs exact-
ID `thread/read { threadId, includeTurns: true }` only for outer IDs enumerated
from staging state DB—not `thread/list`. Initialize uses client name
`codex_review_import` plus importer version and requires response `codexHome` to
equal the sanitized root, platform family/OS to be `unix`/`macos`, and parsed
user-agent CLI version to equal the pinned resolved executable version. It
awaits process/readers/writers on close. The first
Wave 7B1 gate must prove auth-free exact reads for plain/compressed and legacy/
paginated fixtures. Failure is a topology gate for a zstd dependency or Rust
helper, not permission to ignore compressed history.

`legacyKey = outer-review-v1:<hex(reviewDigest)>`. `sourceContentHash` is
SHA-256 of a length-prefixed canonical semantic source tuple: importer schema,
outer IDs/source metadata, ordered rollout event ordinal + method + stable item
ID + sorted-key JSON payload, typed terminal, and raw duration/timestamp inputs.
It excludes filesystem staging paths, initialize/user-agent text, field order,
and other volatile app-server response data. The same verified source therefore
hashes identically across replay and compressed/plain adapter paths.

Clearly non-review metadata (subagent/internal source or no entered-review
evidence) is an ineligible skip. Once same-pair entered-review evidence exists,
missing exit/terminal, cross-turn or multiple markers, invalid result, or other
ownership conflict is an eligible import failure and blocks admission; it is
never downgraded to a skip.

Each legacy review imports in one SQLite transaction with a unique
`(sourceFingerprint, legacyKey, importerVersion)` manifest row. Identical
committed imports with the same source content hash are no-ops. The same import
key with a different content hash is a typed conflict and performs no write. A
successful review and its success manifest commit atomically. If that
transaction rolls back, a separate failure-record transaction stores only the
deterministic key, source hash, importer/schema version, and typed failure—never
partial review rows. Source files remain unchanged. The original source and its
preflight hash manifest are the rollback point, so deleting the recovery
destination and rerunning import is always possible.
An identical failure row remains retryable; a same-key/different-hash failure is
still a no-write conflict. If even the sanitized failure transaction fails, one
typed error retains primary import and secondary recording failures and cutover
admission stays closed. Any unresolved eligible review failure prevents final
admission; documented ineligible skips do not.

The cutover journal enumerates every destination leaf it may create or replace:

```text
MigrationSnapshots/current-main-v1/<snapshot-id>/
review-history.sqlite[-wal|-shm]
SavedAccounts/ RegistryV2 artifacts/journals
CodexHome/auth.json
codexReview.recoveryV1.runtimePreferences
CodexReviewKit.ReviewMonitor.sidebarJobFilter
cutover-journal.json
cutover-admission.json
snapshotVerified → historyImported → preferencesCommitted
                 → authConverted | authenticationRequired | authFailed
                 → historyAdmitted(authDisposition)
                 → runtimeAdmitted  // only converted/required
```

Admission is the final fsynced atomic rename. An identical completed source/
snapshot resumes normally; an incomplete same-snapshot journal resumes
idempotently. A different source, untracked destination history/RegistryV2, or
different preexisting destination preference is a typed conflict. Import
finishes before the first history query snapshot. History remains readable on
auth failure; `.authenticationFailed` still permits the first history query but
MCP/primary app-server remain closed. Recovery development data is never implicitly
merged with legacy import.

`RecoveryCutoverCoordinator` runs after `PreparedRecoveryEnvironment` exists but before
the first history query/runtime admission. It snapshots first, opens/migrates
the history writer for import without starting observation, commits history,
preferences, and typed auth conversion, atomically writes admission, then lets
the normal startup owner begin the first query snapshot and auth/runtime
recovery. `authenticationRequired` is a history/runtime-admitted signed-out
state; corruption/debt is `authenticationFailed`, history-admitted but never
runtime-admitted until repaired.

Before admission, rollback deletes only journal-enumerated destination leaves
and restores a new preference only if its bytes still equal the migration write;
the verified snapshot and legacy source remain. After admission/live use, the
owner awaits UI/store/runtime/query/DB close and atomically renames RecoveryV1
within the same parent directory to
`RecoveryV1-Rollback-<UTC-timestamp>-<UUID>` before conditionally restoring
preferences. Rename failure leaves RecoveryV1 and preferences unchanged and is
typed; no copy/delete fallback crosses volumes.
There is no reverse import or legacy-source write. Post-cutover reviews remain
in the archive and can be used for a later forward cutover.

## 5. API-first sketch

The released v0.6.2 public review/MCP surface remains primary. Persistence is a
package implementation detail. New domain values cross actor boundaries as
immutable `Sendable` values.

```swift
package struct ReviewID: RawRepresentable, Hashable, Sendable, Codable {
    package let rawValue: String
}

package struct ReviewHistoryCommit: Sendable {
    package let revision: UInt64
    package let review: ReviewJobSnapshot
    package let logChanges: [ReviewLogChange]
}

package enum ManagedACLState: String, Sendable, Hashable, Codable {
    case absent
}

package struct FilesystemIdentity: Sendable, Hashable, Codable {
    package let volumeIdentifier: String
    package let device: UInt64
    package let inode: UInt64
    package let fileType: UInt16
    package let ownerUID: UInt32
    package let mode: UInt16
    package let acl: ManagedACLState
    package let policyVersion: Int
}

// Opaque token. RecoveryDescriptorFileSystem retains the descriptor and parent
// chain; consumers never receive or close the raw file descriptor.
package struct DirectoryCapability: Sendable, Hashable {
    fileprivate let token: UInt64
    package let identity: FilesystemIdentity
    package let redactedDiagnostic: String
}

package struct ManagedFileCapability: Sendable, Hashable {
    package let parent: DirectoryCapability
    package let component: String
    fileprivate init(parent: DirectoryCapability, component: String)
}

package struct ReadOnlyDirectoryCapability: Sendable, Hashable {
    fileprivate let token: UInt64
    package let identity: FilesystemIdentity
    package let redactedDiagnostic: String
}

package struct ReadOnlyFileCapability: Sendable, Hashable {
    fileprivate let token: UInt64
    package let identity: FilesystemIdentity
    package let redactedDiagnostic: String
}

package struct AbsoluteComponentPath: Sendable {
    package let components: [String]
    // Parses an absolute locator at the input boundary; rejects empty, dot,
    // dot-dot, and slash-containing components. It performs no I/O/authorization.
    package init(validatingAbsoluteLocator: String) throws
}

package struct ReadOnlySourcePolicy: Sendable {
    package let allowedMountIdentities: Set<String>
    package let requiredOwnerUID: UInt32?
}

package struct ReadOnlySourceAllowlist: Sendable {
    package let adapterVersion: Int
    package let rules: [ReadOnlySourceRule]
}

package enum ReadOnlySourceRule: Sendable {
    case exactFile([String])
    case rolloutTree(root: [String], allowedSuffixes: Set<String>)
}
package struct ReadOnlySourceEntry: Sendable {
    package let relativeComponents: [String]
    package let capability: ReadOnlyFileCapability
}

package struct VerifiedSourceFileSnapshot: Sendable {
    package let identity: FilesystemIdentity
    package let byteCount: Int64
    package let sha256: String
}

package struct DescriptorCopyReceipt: Sendable {
    package let sourceBefore: VerifiedSourceFileSnapshot
    package let sourceAfter: VerifiedSourceFileSnapshot
    package let destinationIdentity: FilesystemIdentity
    package let copiedByteCount: Int64
    package let sha256: String
}

package struct ExecutableCapability: Sendable, Hashable {
    fileprivate let token: UInt64
    package let identity: FilesystemIdentity
    package let redactedDiagnostic: String
}

package struct ExecutableTrustPolicy: Sendable {
    package let allowedBundleIdentifiers: Set<String>
    package let permitsExplicitConfiguredPath: Bool
}

package struct RecoveryEnvironmentPlan: Sendable {
    package static func production(
        runtimePreferences: CodexReviewRuntime.Preferences
    ) -> Self
    package func prepare(
        using fileSystem: RecoveryDescriptorFileSystem
    ) async throws -> PreparedRecoveryEnvironment
}

package struct PreparedRecoveryEnvironment: Sendable {
    package let fileSystem: RecoveryDescriptorFileSystem
    package let recoveryRoot: DirectoryCapability
    package let codexHome: DirectoryCapability
    package let loginStagingRoot: DirectoryCapability
    package let savedAccountsRoot: DirectoryCapability
    package let historyDatabase: ManagedFileCapability
}

package actor RecoveryDescriptorFileSystem {
    // Starts at the actor's already-opened system root/trusted descriptor and
    // walks every component; the locator never becomes authority.
    package func openReadOnlyDirectory(
        _ path: AbsoluteComponentPath,
        policy: ReadOnlySourcePolicy
    ) throws -> ReadOnlyDirectoryCapability
    package func enumerateAllowlistedSource(
        in root: ReadOnlyDirectoryCapability,
        allowlist: ReadOnlySourceAllowlist
    ) throws -> [ReadOnlySourceEntry]
    package func snapshot(
        _ source: ReadOnlyFileCapability,
        maximumByteCount: Int64
    ) throws -> VerifiedSourceFileSnapshot
    package func revalidate(
        _ source: ReadOnlyFileCapability,
        against snapshot: VerifiedSourceFileSnapshot
    ) throws
    package func copyVerified(
        _ source: ReadOnlyFileCapability,
        expectedSource: VerifiedSourceFileSnapshot,
        to destination: ManagedFileCapability
    ) throws -> DescriptorCopyReceipt
    package func managedFile(
        named component: String,
        in parent: DirectoryCapability
    ) throws -> ManagedFileCapability
    package func resolveExecutable(
        describedBy url: URL,
        policy: ExecutableTrustPolicy
    ) throws -> ExecutableCapability
    package func createDirectory(
        named component: String,
        in parent: DirectoryCapability
    ) throws -> DirectoryCapability
    package func read(
        _ file: ManagedFileCapability,
        maximumByteCount: Int
    ) throws -> Data
    package func replaceAtomically(
        _ file: ManagedFileCapability,
        with bytes: Data
    ) throws
    package func removeManifestedTree(
        _ directory: DirectoryCapability,
        expectedIdentity: FilesystemIdentity
    ) throws
    package func removeManifestedFile(
        _ file: ManagedFileCapability,
        expectedIdentity: FilesystemIdentity
    ) throws
    // Wave 4 adds this target-local adapter. Revalidation and the GRDB
    // constructor execute inside the actor; no URL is returned to the caller.
    package func openHistoryDatabase(
        _ target: ManagedFileCapability,
        configuration: ReviewHistoryDatabaseOpenConfiguration
    ) throws -> ReviewHistoryDatabase
    // Issue #113 supplies this generic Foundation Process adapter. It configures
    // and calls Process.run inside the actor, returning only the owned
    // process/pipe handle; executable/home URLs never cross the boundary.
    package func launchProcess(
        executable: ExecutableCapability,
        codexHome: DirectoryCapability,
        request: CapabilityProcessLaunchRequest
    ) throws -> CapabilityProcess
}

package enum RecoveryPathOnlyConsumer: Sendable {
    case grdbOpen
    case processLaunch
}

package struct ReviewHistoryDatabaseOpenConfiguration: Sendable {
    package let foreignKeysEnabled: Bool
    package let writeAheadLoggingEnabled: Bool
}

package actor ReviewHistoryDatabase {
    // Package persistence extensions expose domain transactions/observations,
    // never the GRDB writer.
}

package struct CapabilityProcessLaunchRequest: Sendable {
    package let arguments: [String]
    package let environment: [String: String]
}

package actor CapabilityProcess: RuntimeLifecycleHandle {
    // Owns Process and pipe handles needed by AppServerProcessTransport.
    package func activate() async throws
    package func closeAdmission() async
    package func close(purpose: ReviewRuntimeTransitionPurpose) async throws
    package func waitUntilClosed() async throws
}

package struct ReviewHistoryConfiguration: Sendable {
    package let fileSystem: RecoveryDescriptorFileSystem
    package let database: ManagedFileCapability
    package let initialTerminalReviewLimit: Int
    package let bootstrap: ReviewHistoryBootstrap?
    package let startupPreparation: ReviewHistoryStartupPreparation?
}

package enum ReviewHistoryStartupDisposition: Sendable {
    case ready
    case authenticationRequired
    case authenticationFailed(String)
}

package struct ReviewHistoryStartupPreparation: Sendable {
    package let run: @Sendable (
        ReviewHistoryStore
    ) async throws -> ReviewHistoryStartupDisposition
}

package struct ReviewHistoryBootstrap: Sendable {
    package let mutations: [ReviewBootstrapMutation]
}

package struct ReviewBootstrapMutation: Sendable {
    package let reviewID: ReviewID
    package let mutation: ReviewHistoryMutation
}

package enum ReviewPersistenceError: LocalizedError, Sendable {
    case capability(RecoveryFilesystemError)
    case open(String)
    case migration(String)
    case read(String)
    case write(String)
    case close(String)
}

package enum RecoveryFilesystemError: LocalizedError, Sendable {
    case invalidComponent(String)
    case untrustedAncestor(String)
    case symbolicLink(String)
    case mountBoundary(String)
    case ownership(String)
    case permissions(String)
    case accessControlList(String)
    case identityChanged(String)
    case pathOnlyRevalidation(RecoveryPathOnlyConsumer, String)
    case operation(String)
}

// Wave 3A declaration in ReviewAttemptProcessor.swift. Wave 3B does not edit it.
package enum ReviewRuntimeCloseFailure: LocalizedError, Equatable, Sendable {
    case connection(String)
    case process(String)
    case worker(String)
    case cleanup(String)
    case mcpHandlerDrain(String)
}

// Wave 3B declaration in ReviewRuntimeLifecycle.swift.
package enum ReviewLifecycleResourceFailure: LocalizedError, Equatable, Sendable {
    case client(String)
    case process(String)
    case authenticationObservation(String)
    case reader(String)
    case router(String)
    case session(String)
    case rateLimit(String)
    case mcpHandlerDrain(String)
    case mcpServer(String)
}

package struct ReviewLifecycleResourceFailureAggregate: LocalizedError, Sendable {
    package let first: ReviewLifecycleResourceFailure
    package let additionalInLifecycleOrder: [ReviewLifecycleResourceFailure]
}

package enum ReviewClosePrimaryFailure: LocalizedError, Sendable {
    case interruptRequest(ReviewInterruptRequestFailure)
    case attemptRuntime(ReviewRuntimeCloseFailure)
    case lifecycleResources(ReviewLifecycleResourceFailureAggregate)
    case persistence(ReviewPersistenceError)
}

package struct ReviewCloseFailureAggregate: LocalizedError, Sendable {
    package let first: ReviewClosePrimaryFailure
    package let additionalInLifecycleOrder: [ReviewClosePrimaryFailure]
}

package struct ReviewCloseError: LocalizedError, Sendable {
    package let failures: ReviewCloseFailureAggregate
    package let secondaryPhysicalDatabaseClose: ReviewPersistenceError?
}

package struct ReviewHistoryPage: Sendable, Equatable {
    package let hasMore: Bool
    package let addedCount: Int
    package let loadedCount: Int
    package let cursor: String?
}

package enum ReviewHistoryOrderingError: LocalizedError, Sendable {
    case movingReviewNotFound(ReviewID)
    case movingWorkspaceNotFound(String)
    case staleReviewAnchor(ReviewID)
    case staleWorkspaceAnchor(String)
}

package enum ReviewHistoryMutation: Sendable {
    case create(ReviewCreation)
    case apply(ReviewEvent, attempt: ReviewAttemptID)
    case requestCancellation(ReviewCancellation)
    case finish(attempt: ReviewAttemptID, terminal: ReviewTerminal)
    case deleteTerminalReview
}

package struct LegacyImportSource: Sendable {
    package let fingerprint: String
    package let importerVersion: Int
    package init(fingerprint: String, importerVersion: Int)
}

package enum ReviewImportedDuration: Sendable {
    case exact(milliseconds: Int64)
    case lowerBound(startedAt: Date, observedThroughAt: Date)
    case unavailable
}

package struct LegacyReviewImport: Sendable {
    package let source: LegacyImportSource
    package let outerThreadID: String
    package let reviewTurnID: String
    package let sourceContentHash: String
    package let creation: ReviewCreation
    package let events: [ReviewEvent]
    package let terminal: ReviewTerminal
    package let duration: ReviewImportedDuration
    package init(
        source: LegacyImportSource,
        outerThreadID: String,
        reviewTurnID: String,
        sourceContentHash: String,
        creation: ReviewCreation,
        events: [ReviewEvent],
        terminal: ReviewTerminal,
        duration: ReviewImportedDuration
    )
}

package enum LegacyReviewImportOutcome: Sendable {
    case imported(ReviewHistoryCommit)
    case alreadyImported(ReviewID)
}

package enum LegacyReviewImportError: LocalizedError, Sendable {
    case conflictingSourceHash(ReviewID)
    case importFailed(primary: String)
    case importAndFailureRecordFailed(primary: String, secondary: String)
}

// CodexReviewHost owns the concrete cutover implementation and injects only
// ReviewHistoryStartupPreparation into the lower CodexReview store.
package struct RecoveryCutoverConfiguration: Sendable {
    package let preparedEnvironment: PreparedRecoveryEnvironment
    package let legacyPreferencesDomain: String
    package let importerVersion: Int
    package init(
        preparedEnvironment: PreparedRecoveryEnvironment,
        legacyPreferencesDomain: String,
        importerVersion: Int
    )
}

package actor RecoveryCutoverCoordinator {
    package func startupPreparation(
        configuration: RecoveryCutoverConfiguration
    ) -> ReviewHistoryStartupPreparation
    package func rollbackToCurrentMain() async throws -> URL
}

public enum ReviewTerminalKind: String, Codable, Sendable, Hashable {
    case completed
    case interrupted
    case failed
}

public enum ReviewInterruptionCause: Codable, Sendable, Hashable {
    case requested(ReviewCancellation)
    case server(message: String?)
    case transport(message: String)
    case previousProcessExit
}

public enum ReviewTerminalRecord: Codable, Sendable, Hashable {
    case completed
    case interrupted(ReviewInterruptionCause)
    case failed(message: String?)

    public var kind: ReviewTerminalKind { get }
}

// Exact concrete nested declaration after the additive change. Existing
// ReviewJobCore.Run, Output, and outer members are unchanged.
public struct ReviewJobCore: Codable, Sendable, Hashable {
    public struct Lifecycle: Codable, Sendable, Hashable {
        public internal(set) var status: ReviewJobState
        public internal(set) var exitCode: Int?
        public internal(set) var startedAt: Date?
        public internal(set) var endedAt: Date?
        public internal(set) var cancellation: ReviewCancellation?
        public internal(set) var errorMessage: String?
        public internal(set) var terminal: ReviewTerminalRecord?

        // The v0.6.2 public initializer signature remains exact.
        public init(
            status: ReviewJobState,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            cancellation: ReviewCancellation? = nil,
            errorMessage: String? = nil
        ) {
            self.status = status
            self.exitCode = exitCode
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.cancellation = cancellation
            self.errorMessage = errorMessage
            self.terminal = nil
        }

        package init(
            status: ReviewJobState,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            cancellation: ReviewCancellation? = nil,
            errorMessage: String? = nil,
            terminal: ReviewTerminalRecord?
        ) {
            self.init(
                status: status,
                exitCode: exitCode,
                startedAt: startedAt,
                endedAt: endedAt,
                cancellation: cancellation,
                errorMessage: errorMessage
            )
            self.terminal = terminal
        }
    }
}

package enum ReviewDurationPresentation: Sendable, Equatable {
    case running(since: Date)
    case exact(Duration)
    case lowerBound(Duration)
    case unavailable
}

package struct ReviewRuntimeGeneration: Hashable, Sendable {
    package let rawValue: UInt64
}

package struct RuntimePublicationSnapshot: Sendable {
    package let authentication: CodexReviewBackendModel.Auth.Snapshot
    package let settings: CodexReviewSettings.Snapshot
}

package struct MCPServerGeneration: Hashable, Sendable {
    package let rawValue: UInt64
}

package struct MCPServerPublicationSnapshot: Sendable {
    // nil only for a composition that explicitly has no MCP capability.
    // A Live owner that binds must return the actual non-nil URL.
    package let serverURL: URL?
}

package struct PreparedMCPServer: Sendable {
    package let generation: MCPServerGeneration
}

package enum ReviewRuntimeTransitionPurpose: Sendable {
    case stop
    case restartSameAccount
    case accountTransition
    case applicationClose
    case recoveryReplacement
}

package protocol RuntimeLifecycleHandle: Sendable {
    // One replaceable AppServer generation only. No MCP or Store-owned Task.
    func activate() async throws
    // Closes only Host AppServer request/session admission.
    func closeAdmission() async
    // Through the AppServer owner seam, one recorded Task sends the client/
    // process close signal, then directly joins captured router/session handles
    // plus all Host completion.
    func close(purpose: ReviewRuntimeTransitionPurpose) async throws
    // Idempotently joins/replays that exact close result; never initiates close
    // or adds a second failure.
    func waitUntilClosed() async throws
}

package struct PreparedRuntime: Sendable {
    package let snapshot: RuntimePublicationSnapshot
    package let handle: any RuntimeLifecycleHandle
}

// CodexReviewAppServer owner seam. Captures concrete Task/session handles,
// invokes client.close(), and directly joins them without polling/yield.
// Failures are ReviewLifecycleResourceFailureAggregate.
package extension AppServerCodexReviewBackend {
    package func closeAndWaitForOwnedLifecycle() async throws
}

package protocol MCPServerLifecycleOwner: Sendable {
    // One owner identity spans the app lifetime; each stop/later-start uses a
    // new listener or declared-no-MCP generation.
    func prepare() async throws -> PreparedMCPServer
    // Live bind returns the actual non-nil URL (including assigned port 0).
    // A declared no-MCP Direct/Preview/Testing owner returns nil, no placeholder.
    func activate(
        _ generation: MCPServerGeneration
    ) async throws -> MCPServerPublicationSnapshot
    // Network admission close is the first owner mutation before handler drain.
    func closeAdmission() async
    func drainAdmittedHandlers() async throws
    // Nonterminal runtime-disable lifecycle.
    // Attempts all listener/session close signals, then returns/throws.
    func stop() async throws
    // Begins only after stop signaling; awaits physical completion.
    func waitUntilStopped() async throws
    // Terminal application lifecycle.
    // Attempts all listener/session close signals, then returns/throws.
    func close() async throws
    // Begins only after close signaling; awaits physical completion.
    func waitUntilClosed() async throws
}

package struct ReviewRuntimeClosePolicy: Sendable {
    package let terminalGrace: Duration
    package let sleep: @Sendable (Duration) async throws -> Void
    package static let production = Self(
        terminalGrace: .seconds(10),
        sleep: { duration in try await ContinuousClock().sleep(for: duration) }
    )
}

package enum ReviewExecutionPhase: Sendable, Equatable {
    case active(ReviewAttemptID)
    case waitingForConnectivity(previousAttempt: ReviewAttemptID)
    case recovering(previousAttempt: ReviewAttemptID)
    case terminal(ReviewTerminalRecord)
}

package actor ReviewHistoryStore {
    package init(configuration: ReviewHistoryConfiguration)
    package func open() async throws
    package func apply(
        _ mutation: ReviewHistoryMutation,
        to reviewID: ReviewID
    ) async throws -> ReviewHistoryCommit
    // Owns the atomic success row and sanitized retryable failure-row
    // transaction; callers never write reviewImports independently.
    package func importLegacy(
        _ value: LegacyReviewImport
    ) async throws -> LegacyReviewImportOutcome
    package func close() async throws
}

@MainActor
@Observable
package final class ReviewHistoryQuery {
    package enum Phase {
        case loading
        case loaded
        case failed(ReviewPersistenceError)
    }

    package private(set) var phase: Phase { get }
    package private(set) var workspaces: [CodexReviewWorkspace] { get }
    package private(set) var jobs: [CodexReviewJob] { get }
    package func start() async throws
    package func loadNextPage() async throws -> ReviewHistoryPage
    package func close()
}

@MainActor
@Observable
public final class CodexReviewStore {
    package let historyQuery: ReviewHistoryQuery
    public var workspaces: Set<CodexReviewWorkspace> { get }
    package var orderedWorkspaces: [CodexReviewWorkspace] { get }
    public var jobs: Set<CodexReviewJob> { get }  // computed from historyQuery.jobs
    package var orderedJobs: [CodexReviewJob] { get }
    public func start(forceRestartIfNeeded: Bool = false) async
    public func stop() async  // stops AppServer + current MCP lease; owners/history stay open
    public func restart() async  // replaces AppServer generation; retains MCP lease
    public func waitUntilStopped() async  // both AppServer and current MCP lease completed
    public func close() async throws  // app-lifetime close; awaits queries + history + runtime

    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request
    ) async throws -> CodexReviewAPI.Read.Result
    package func startReview(
        sessionID: String,
        request: CodexReviewAPI.Start.Request,
        waitTimeout: Duration
    ) async throws -> CodexReviewAPI.Read.Result
    package func awaitReview(
        sessionID: String?,
        jobID: String,
        timeout: Duration? = nil
    ) async throws -> CodexReviewAPI.Read.Result
    package func readReview(
        sessionID: String?,
        jobID: String,
        logFilter: CodexReviewAPI.Log.Filter = .defaultSetting,
        logPage: CodexReviewAPI.Log.PageRequest = .default
    ) async throws -> CodexReviewAPI.Read.Result
    package func listReviews(
        sessionID: String?,
        cwd: String? = nil,
        statuses: [ReviewJobState]? = nil,
        limit: Int? = nil
    ) async throws -> CodexReviewAPI.List.Result
    package func cancelReview(
        jobID: String,
        sessionID: String,
        cancellation: ReviewCancellation = .system()
    ) async throws -> CodexReviewAPI.Cancel.Outcome
    package func closeSession(
        _ sessionID: String,
        reason: ReviewCancellation = .sessionClosed()
    ) async
    package func deleteReviewHistory(jobID: String) async throws
    package func reorderWorkspaces(
        cwds: [String],
        beforeCWD: String?
    ) async throws -> Bool
    package func reorderJob(
        id: String,
        inWorkspace cwd: String,
        beforeJobID: String?
    ) async throws -> Bool
    package func job(id: String) -> CodexReviewJob?
}

// CodexReviewHost
public extension CodexReviewStore {
    // Exact v0.6.2 overload retained. It delegates to the recovery-owned default.
    static func makeLiveStore(
        runtimePreferences: CodexReviewRuntime.Preferences = .defaults,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration? = nil,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory =
            CodexReviewNativeAuthentication.WebSessions.system
    ) -> CodexReviewStore

}

package extension CodexReviewStore {
    // Composition/test seam. The environment was already descriptor-prepared.
    static func makeLiveStore(
        runtimePreferences: CodexReviewRuntime.Preferences,
        preparedEnvironment: PreparedRecoveryEnvironment,
        nativeAuthenticationConfiguration: CodexReviewNativeAuthentication.Configuration?,
        webAuthenticationSessionFactory: @escaping CodexReviewNativeAuthentication.WebSessionFactory
    ) -> CodexReviewStore
}

// CodexReview domain package contract consumed by CodexReviewHost.
package struct CodexReviewAPIKey: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    package init(validating value: String) throws
    package func withValue<Result: Sendable>(
        _ operation: @Sendable (String) async throws -> Result
    ) async rethrows -> Result
}

package struct SavedAccountID: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String
    package init()
    package init?(rawValue: String)
    package init(from decoder: any Decoder) throws
    package func encode(to encoder: any Encoder) throws
}

package enum SavedAccountProvider: String, Codable, Sendable {
    case chatGPT
    case apiKey
    case amazonBedrock
}

package struct SavedAccountPresentation: Codable, Equatable, Sendable {
    package var lastKnownEmail: String?
    package init(lastKnownEmail: String?)
}

package enum ObservedCodexAccount: Equatable, Sendable {
    case chatGPT(email: String?, planType: String)
    case apiKey
    case amazonBedrock
}

package struct CodexAuthObservation: Equatable, Sendable {
    package let account: ObservedCodexAccount?
    package let requiresOpenAIAuth: Bool
    package init(account: ObservedCodexAccount?, requiresOpenAIAuth: Bool)
}

package enum AuthenticationWriteAdmission: Sendable, Equatable {
    case notWritten
    case mayHaveBeenWritten
}

package actor AuthenticationWriteGate {
    package init()
    package func requestCancellation() -> AuthenticationWriteAdmission
    // Called by transport immediately before stdin write. True irreversibly
    // transitions to mayHaveBeenWritten; false proves cancellation prevented it.
    package func admitWrite() -> Bool
    package func snapshot() -> AuthenticationWriteAdmission
}

// CodexReviewAppServer. Secret-bearing requests use only this non-retrying path.
package extension AppServerClient {
    func sendOneShot<Request: AppServerAPI.Request>(
        _ request: Request,
        writeGate: AuthenticationWriteGate
    ) async throws -> Request.Response
}

package enum JSONRPC {
    package protocol Transport: Sendable {
        // Existing send/notify/stream/close requirements remain unchanged.
        func sendOneShot(
            _ request: Request,
            writeGate: AuthenticationWriteGate
        ) async throws -> Data
    }
}

package struct AuthenticationClosePolicy: Sendable {
    package let providerEventGrace: Duration
    package let reconciliationGrace: Duration
    package let sleep: @Sendable (Duration) async throws -> Void
    package init(
        providerEventGrace: Duration,
        reconciliationGrace: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    )
}

package enum AuthenticationIntent: String, Sendable, Codable {
    case signIn
    case addAccount
}

package struct PendingAuthentication: Sendable, Codable {
    package let sessionID: String
    package let candidateAccountID: SavedAccountID
    package let candidateRevisionID: String
    package let intent: AuthenticationIntent
    package let provider: SavedAccountProvider
    package let previousActiveAccountID: SavedAccountID?
    package let cancellationIntent: Bool
}

// Sanitized reservation input. The raw API key stays in LoginSession and never
// crosses the authentication-disk actor boundary.
package struct AuthenticationStagingRequest: Sendable {
    package let intent: AuthenticationIntent
    package let provider: SavedAccountProvider
}

package enum AuthenticationOutcomeUnknownReason: Sendable, Codable {
    case providerEventGraceExpired
    case responseLostAfterWrite
    case connectionLostAfterWrite
    case accountReadFailed(String)
}

package struct LoginStagingResourceSnapshot: Sendable {
    package let sessionID: String
    package let identity: FilesystemIdentity
}

package struct LoginStagingOwnedResources: Sendable {
    package let snapshot: LoginStagingResourceSnapshot
    fileprivate let directory: DirectoryCapability
    fileprivate let runtime: (any RuntimeLifecycleHandle)?
    fileprivate let clientTasks: [Task<Void, Error>]
    fileprivate let readerTasks: [Task<Void, Error>]
    fileprivate let writerTasks: [Task<Void, Error>]
}

package struct PreparedAuthenticationArtifact: Sendable, Codable {
    package let revisionID: String
    package let sha256: String
    package let byteCount: Int
    package let revisionDirectoryIdentity: FilesystemIdentity
    package let fileIdentity: FilesystemIdentity
    package let provider: SavedAccountProvider
    package let presentation: SavedAccountPresentation
}

package enum LoginStagingCloseDisposition: Sendable {
    case discard
    case adopt(ObservedCodexAccount)
    case outcomeUnknown(AuthenticationOutcomeUnknownReason)
}

package enum LoginStagingTaskOwner: String, Sendable {
    case client
    case reader
    case writer
    case candidateWrite
}

package struct LoginStagingOwnedTaskFailure: LocalizedError, Sendable {
    package let owner: LoginStagingTaskOwner
    package let operation: String
    package let code: Int?
    package let message: String
}

package enum AuthenticationPersistenceFailure: LocalizedError, Sendable {
    case read(operation: String, code: Int?, message: String)
    case write(operation: String, code: Int?, message: String)
    case synchronization(operation: String, code: Int?, message: String)
}

package enum LoginStagingResourceCloseFailure: LocalizedError, Sendable {
    case runtime(ReviewRuntimeCloseFailure)
    case ownedTask(LoginStagingOwnedTaskFailure)
}

package struct LoginStagingResourceFailureAggregate: LocalizedError, Sendable {
    package let first: LoginStagingResourceCloseFailure
    package let additionalInRegistrationOrder: [LoginStagingResourceCloseFailure]
}

package enum LoginStagingCleanupFailure: LocalizedError, Sendable {
    case manifest(AuthenticationPersistenceFailure)
    case identity(RecoveryFilesystemError)
    case removal(RecoveryFilesystemError)
    case finalization(AuthenticationPersistenceFailure)
}

package enum AuthenticationCleanupFailureKind: String, Sendable, Codable {
    case resourceClose
    case candidateWrite
    case manifest
    case identity
    case removal
    case finalization
}

package struct AuthenticationCleanupFailureRecord: Sendable, Codable {
    package let kind: AuthenticationCleanupFailureKind
    package let operation: String
    package let code: Int32?
}

package struct PendingAuthenticationCandidate: Sendable, Codable {
    package let pending: PendingAuthentication
    package let artifact: PreparedAuthenticationArtifact
}

package enum LoginStagingCleanupContinuation: Sendable, Codable {
    case discard
    case candidate(PendingAuthenticationCandidate)
}

package enum LoginStagingDiskState: Sendable, Codable {
    case reserved(PendingAuthentication, component: String)
    case leased(PendingAuthentication, component: String, identity: FilesystemIdentity)
    case outcomeUnknown(
        PendingAuthentication,
        component: String,
        identity: FilesystemIdentity,
        reason: AuthenticationOutcomeUnknownReason
    )
    case cleanupRequired(
        component: String,
        identity: FilesystemIdentity,
        continuation: LoginStagingCleanupContinuation
    )
    case cleanupFailed(
        component: String,
        identity: FilesystemIdentity,
        continuation: LoginStagingCleanupContinuation,
        failure: AuthenticationCleanupFailureRecord
    )
}

package enum CandidateAuthenticationDiskState: Sendable, Codable {
    case ready(PendingAuthenticationCandidate)
    case discardRequired(PendingAuthenticationCandidate)
    case discardFailed(
        PendingAuthenticationCandidate,
        failure: AuthenticationCleanupFailureRecord
    )
}

package enum AuthenticationDiskSessionState: Sendable, Codable {
    case idle
    case staging(LoginStagingDiskState)
    case candidate(CandidateAuthenticationDiskState)
}

package struct AuthenticationDiskStateV1: Sendable, Codable {
    package let schemaVersion: Int
    package let generation: UInt64
    package let contentHash: String
    package let sessionState: AuthenticationDiskSessionState
}

package enum PrimaryRuntimeLeasePhase: String, Sendable, Codable {
    case running
    case writebackPrepared
    case registryPublished
}

package struct PrimaryRuntimeLeaseV1: Sendable, Codable {
    package let schemaVersion: Int
    package let runtimeGeneration: UInt64
    package let activeAccountID: SavedAccountID
    package let baseRevisionID: String
    package let baseFingerprint: String
    package let writebackRevisionID: String
    package let phase: PrimaryRuntimeLeasePhase
}

package actor AuthenticationDiskStore {
    package init(
        fileSystem: RecoveryDescriptorFileSystem,
        savedAccountsRoot: DirectoryCapability,
        loginStagingRoot: DirectoryCapability,
        codexHome: DirectoryCapability
    )
    // Reserves durable state, creates/reopens the child through the descriptor
    // owner, records identity, and only then returns the published lease.
    package func reserveAndPrepareLoginStaging(
        request: AuthenticationStagingRequest
    ) async throws -> LoginStagingLease
    package func recoverPendingAuthentication() async throws
}

package actor LoginStagingLease {
    package enum State: Sendable {
        case preparing(sessionID: String)
        case open(LoginStagingOwnedResources)
        case closing(
            LoginStagingOwnedResources,
            Task<Result<LoginStagingCloseOutcome, LoginStagingCloseError>, Never>
        )
        case closed(Result<LoginStagingCloseOutcome, LoginStagingCloseError>)
    }

    package func installRuntime(_ runtime: any RuntimeLifecycleHandle) throws
    package func registerClient(_ task: Task<Void, Error>) throws
    package func registerReader(_ task: Task<Void, Error>) throws
    package func registerWriter(_ task: Task<Void, Error>) throws
    package func close(
        disposition: LoginStagingCloseDisposition
    ) async -> Result<LoginStagingCloseOutcome, LoginStagingCloseError>
}

package enum LoginStagingCloseOutcome: Sendable {
    case discarded
    case preparedForActivation(PreparedAuthenticationCandidate)
    case added(SavedAccountID)
    case retainedForReconciliation(sessionID: String)
}

package enum LoginStagingClosePrimaryFailure: LocalizedError, Sendable {
    case resources(LoginStagingResourceFailureAggregate)
    case cleanup(LoginStagingCleanupFailure)
}

package enum LoginStagingCloseSecondaryFailure: LocalizedError, Sendable {
    case cleanup(LoginStagingCleanupFailure)
    case debtPersistence(AuthenticationPersistenceFailure)
}

package enum LoginStagingDebtDisposition: Sendable {
    case recorded(AuthenticationDiskSessionState)
    case recordingFailed(
        lastKnownState: AuthenticationDiskSessionState,
        failure: AuthenticationPersistenceFailure
    )
}

package struct LoginStagingCloseError: LocalizedError, Sendable {
    package let primary: LoginStagingClosePrimaryFailure
    package let secondary: [LoginStagingCloseSecondaryFailure]
    package let debt: LoginStagingDebtDisposition
}

package enum CodexReviewAuthenticationFailure: LocalizedError, Sendable {
    case alreadyInProgress
    case apiKeyAccountAlreadyExists
    case addAccountRequiresActiveSavedAccount
    case presentation(String)
    case providerCompletion(String)
    case accountRead(String)
    case protocolMismatch(String)
    case outcomeUnknown(sessionID: String)
    case registryMigration(String)
    case persistenceInconsistent(String)
    case loginStagingClose(LoginStagingCloseError)
    case authenticationDebt(String)
}

package struct PreparedAuthenticationCandidate: Sendable {
    package let sessionID: String
    package let savedAccountID: SavedAccountID
    package let provider: SavedAccountProvider
    package let presentation: SavedAccountPresentation
    package let artifactRevisionID: String
    package let artifactSHA256: String
    package let artifactByteCount: Int
    package init(
        sessionID: String,
        savedAccountID: SavedAccountID,
        provider: SavedAccountProvider,
        presentation: SavedAccountPresentation,
        artifactRevisionID: String,
        artifactSHA256: String,
        artifactByteCount: Int
    )
}

// CodexReviewHost migration/auth contract.
package struct LegacyAccountMetadata: Sendable {
    package let sourceAccountKey: String?
    package let lastKnownEmail: String?
    package let planType: String?
    package init(sourceAccountKey: String?, lastKnownEmail: String?, planType: String?)
}

package struct VerifiedOpaqueArtifact: Sendable {
    package let file: ManagedFileCapability
    package let sha256: String
    package let byteCount: Int
    // Defined beside CurrentMainSourceSnapshotter; no package/public initializer.
    fileprivate init(file: ManagedFileCapability, sha256: String, byteCount: Int)
}

package enum CurrentMainCredentialImport: Sendable {
    case verified(VerifiedOpaqueArtifact)
    case reauthenticationRequired(reason: String)
}

package enum CurrentMainSavedAccountImport: Sendable {
    case chatGPT(metadata: LegacyAccountMetadata, credential: CurrentMainCredentialImport)
    case apiKeyReauthenticationRequired(metadata: LegacyAccountMetadata)
    case amazonBedrock(metadata: LegacyAccountMetadata, credential: CurrentMainCredentialImport)
}

package struct CurrentMainSavedAccountBatchImport: Sendable {
    package let sourceFingerprint: String
    package let numericSchemaVersion: Int
    package let entriesInSourceOrder: [CurrentMainSavedAccountImport]
    package let legacyActiveAccountKey: String?
    package init(
        sourceFingerprint: String,
        numericSchemaVersion: Int,
        entriesInSourceOrder: [CurrentMainSavedAccountImport],
        legacyActiveAccountKey: String?
    )
}

package struct CurrentMainSavedAccountImportOutcome: Sendable {
    package let importedAccountIDs: [SavedAccountID]
    package let activeAccountID: SavedAccountID?
    package let authenticationRequired: Bool
}

package extension AuthenticationDiskStore {
    package func importCurrentMainAccounts(
        _ batch: CurrentMainSavedAccountBatchImport
    ) async throws -> CurrentMainSavedAccountImportOutcome
}

package enum CodexReviewAuthenticationResult: Sendable {
    case signedIn(SavedAccountID)
    case added(SavedAccountID)
    case cancelled
    case committedActivationPending(SavedAccountID, message: String)
}

package enum CodexReviewAuthenticationMethod: Sendable {
    case chatGPT
    case apiKey(CodexReviewAPIKey)
}

package enum CodexReviewAuthenticationRequest: Sendable {
    case signIn(using: CodexReviewAuthenticationMethod)
    case addAccount(using: CodexReviewAuthenticationMethod)
}

package extension CodexReviewAuthModel {
    var hasActiveSavedAccount: Bool { get }
}

package extension CodexReviewStore {
    @discardableResult
    func performPrimaryAuthenticationAction(
        _ request: CodexReviewAuthenticationRequest
    ) async throws -> CodexReviewAuthenticationResult
}

@MainActor
package protocol CodexReviewStoreBackend: CodexReviewSettingsBackend, Sendable {
    // Existing non-runtime/non-auth requirements remain unchanged. Runtime
    // construction is inert and never receives the Store to mutate.
    // Stable identity for the Store lifetime; never constructs a new owner on get.
    var mcpServerLifecycle: any MCPServerLifecycleOwner { get }

    func prepareRuntime(
        generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) async throws -> PreparedRuntime

    // Retired parallel signIn/addAccount requirements are removed from the
    // protocol body.
    func authenticate(
        auth: CodexReviewAuthModel,
        request: CodexReviewAuthenticationRequest
    ) async throws -> CodexReviewAuthenticationResult
}

// CodexReviewHost
package struct CodexExecutableResolver: Sendable {
    package struct Configuration: Sendable {
        package let homeDirectoryURL: URL
        package let systemApplicationsDirectoryURL: URL
        package let fallbackExecutableDirectories: [URL]
    }

    package init(
        configuration: Configuration,
        fileSystem: RecoveryDescriptorFileSystem,
        trustPolicy: ExecutableTrustPolicy
    )
    package func resolve(
        configuredPath: String?,
        environment: [String: String]
    ) async throws -> ExecutableCapability
}

package extension AppServerProcessTransport {
    package struct Configuration: Sendable {
        package let executable: ExecutableCapability
        package let arguments: [String]
        package let environment: [String: String]
        package let codexHome: DirectoryCapability
        package let fileSystem: RecoveryDescriptorFileSystem

        // There is no optional executable or discovery fallback initializer.
        package init(
            executable: ExecutableCapability,
            arguments: [String]? = nil,
            environment: [String: String],
            codexHome: DirectoryCapability,
            fileSystem: RecoveryDescriptorFileSystem
        ) throws
    }
}

// ReviewUI
@MainActor
public final class ReviewMonitorWindowController: NSWindowController {
    public func closeAndWait() async
}
```

`ReviewInterruptRequestFailure` retains the original request rejection or
outcome-unknown category/code/message plus any secondary barrier diagnostic.
Wave 3A's unchanged `ReviewRuntimeCloseFailure` remains the attempt processor's
connection/process/worker/cleanup/MCP-barrier vocabulary. Wave 3B's separate
`ReviewLifecycleResourceFailure` distinguishes app-lifetime MCP, rate-limit, and
Host auth/reader/router/session/client/process origins. A lifecycle method with
multiple failures returns its nonempty aggregate; the Store carries that value
as `.lifecycleResources(...)` and existing 3A values as `.attemptRuntime(...)`
inside one `ReviewCloseFailureAggregate` in fixed stage/registration order. A
later failure is never overwritten or log-only, and Wave 3B does not edit
`ReviewAttemptProcessor.swift`. `ReviewClosePrimaryFailure` also admits future
persistence stages. The optional secondary field is reserved only for an
additional physical database-close failure; physical close as the sole failure
is the aggregate's `.persistence(.close)` first value. The same complete
`ReviewCloseError` value is rethrown to every joined caller.

No public or cross-target API names GRDB or `DatabaseWriter`.
`ReviewHistoryConfiguration` is the only composition seam; the persistence
folder resolves its managed-file capability to the concrete connection and GRDB
observations only inside a last-moment revalidation handoff.

`CodexReviewHost` keeps the existing non-throwing public `makeLiveStore`
overload byte-for-byte at the declaration level. It delegates to the safe
RecoveryV1 plan and defers descriptor preparation plus database open/migration
to `store.start()`, where failure becomes visible store state. Package/test
composition may inject a `PreparedRecoveryEnvironment`; there is no new public
raw-history-URL overload. This preserves function references/API-digester
identity without trapping or silently constructing an empty history.

The observable `CodexReviewJob` instances are stable query projections. The
history query owns the only projection registry, updates an existing instance
in place for the same review ID, and rebuilds the registry from SQLite at
startup. `CodexReviewStore.jobs` and `orderedJobs` are computed views of that
registry, never stored membership.

The public `jobs` collection represents the currently loaded history window,
not an unbounded eager copy of the database. It always includes all nonterminal
reviews and initially the newest 100 terminal reviews; ReviewUI pagination grows
the window. This is an intentional compatibility clarification required by
durable history. A separate SwiftPM consumer fixture pins it.

`workspaces` and `orderedWorkspaces` are likewise computed from the query's one
stable workspace registry. A workspace appears when it owns at least one loaded
review; empty workspace rows are not exposed. Paging a first review for an older
workspace adds that stable workspace projection in the same snapshot revision.

`CodexReviewJob.logEntries` remains the released read surface, but no store or
backend method mutates it. `ReviewHistoryQuery` applies committed effective rows
to each stable job in place, so unselected and selected jobs share the same fresh
projection. Its internal GRDB fetched values are query transport
artifacts, not second exposed log models. MCP read pages query SQLite directly.

The published `ReviewJobState` cases remain unchanged to avoid adding a case to
an externally exhaustively switched enum. `ReviewJobCore.Lifecycle` gains an
additive optional `ReviewTerminalRecord`, and MCP lifecycle/results expose the
same terminal kind/cause additively. `.completed` maps to `.succeeded` and
`.failed` maps to `.failed`. An `.interrupted(.requested(...))` maps to
`.cancelled` and retains the actual request authority. Spontaneous server,
transport, or previous-process interruption maps to legacy `.failed` without
fabricating a cancellation record, while terminal kind/cause remains
`interrupted` for Swift/UI/MCP consumers. No code infers interruption from
display text.

The existing public `Lifecycle.init(status:exitCode:startedAt:endedAt:cancellation:errorMessage:)`
symbol and function-reference shape remain exact and initialize `terminal` to
`nil`. A package-only initializer admits a validated terminal for the reducer
and history query. Missing `terminal` while decoding an old Codable payload is
the one compatibility input; newly committed terminal lifecycle rows require a
non-`nil` record that agrees with status.

Row/API duration uses `ReviewDurationPresentation`, not the legacy rule
"missing endedAt means still running." Terminal rows with exact start/end use
`.exact`; recovered orphan rows use `.lowerBound` from start through
`observedThroughAt`; terminal rows without either boundary use `.unavailable`.

### Failure model

- Recovery descriptor preparation/revalidation failure: typed filesystem error
  with operation, policy, and redacted diagnostic identity; no Process, MCP,
  authentication, GRDB, or destination mutation is admitted. There is no
  canonical-URL or path-prefix fallback.
- A partial static RecoveryV1 preparation is reopened by fixed component name
  and descriptor identity on the next preparation attempt. In-process rollback
  removes only leaves created and retained in that preparation receipt; rollback
  failure is returned alongside the primary preparation failure. It never
  creates authentication cleanup debt.
- Login staging close/cleanup failure: the lease returns one replayable typed
  close result and the authentication disk actor persists the exact session
  state/debt. Unconfirmed resource completion or an unmanifested/changed
  identity preserves the directory and blocks new auth; no Environment helper
  deletes it and no layer reports clean close.
- Database open/migration/commit/query failures: typed persistence error,
  fail-closed transition, visible last-good recovery UI, and no empty-history or
  in-memory fallback.
- Missing review/attempt/event identity: typed ingestion contract error at the
  decoder/router boundary with the attempt-vs-connection containment table
  above.
- App-server transport loss: current live attempt becomes failed/interrupted as
  the runtime transition table dictates; committed history remains visible.
- Unknown notification outside known review event families: one bounded
  diagnostic and continue. Known malformed events follow the explicit
  attempt/connection containment table. Neither path fabricates success or
  traps on external input.
- Closed store/history: typed closed error for new work; repeated close is a
  documented no-op returning the same completion. The package history close is
  throwing because GRDB close can fail. Public `CodexReviewStore.close()` awaits
  it and propagates a typed close failure to the application lifecycle owner,
  which records it in diagnostics and decides whether termination may continue.
  No layer silently claims a clean stop.

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
let plan = RecoveryEnvironmentPlan.production(runtimePreferences: preferences)
let preparedEnvironment = try await plan.prepare(using: recoveryFileSystem)
let store = CodexReviewStore.makeLiveStore(
    runtimePreferences: preferences,
    preparedEnvironment: preparedEnvironment,
    nativeAuthenticationConfiguration: nativeAuthentication,
    webAuthenticationSessionFactory: webSessions
)
await store.start()  // revalidates, opens/migrates/hydrates, then admits app-server

sidebar.bind(to: store.orderedJobs)
guard let job = store.job(id: selection.reviewID) else { return }
detail.bind(to: job)
```

The actual native controller continues to observe the stable store/job objects;
the difference is that membership/content are hydrated from committed history,
not app-server fetches. Selection changes only which stable hydrated job the
detail renderer observes.

### MCP consumer

```swift
let terminal = try await store.startReview(
    sessionID: sessionID,
    request: request
)
return ReviewStartResult(
    jobID: terminal.jobID,
    output: terminal.core.reviewText
)
```

`startReview(sessionID:request:)` already waits for terminal in the published
v0.6.2 flow; the MCP adapter does not add a second wait. UI and MCP do not
reconstruct terminal output independently.

The additive MCP field is exactly `lifecycle.terminal`. It is `null` while
nonterminal and one of:

```json
{ "kind": "completed" }
{ "kind": "failed", "message": "...|null" }
{
  "kind": "interrupted",
  "cause": {
    "kind": "requested|server|transport|previousProcessExit",
    "source": "userInterface|mcpClient|sessionClosed|system|null",
    "message": "...|null"
  }
}
```

The associated-value Swift enum validates this shape before encoding, so
completed+cause and interrupted-without-cause are unrepresentable.

Client wait behavior remains explicit: Claude-identified `review_start` waits
at most 540 seconds and returns the existing running result plus
`nextAction: { tool: "review_await", jobId: ... }`; every `review_await` call
waits at most another 540 seconds. Other discovered clients keep the published
v0.6.2 start behavior unless live #109 probes require an additive bounded mode.

### MCP session isolation

Persistence does not broaden the published MCP authorization scope. Durable
rows keep their originating MCP session ID for audit, while the in-process MCP
session registry owns the set of review IDs that each active session may read,
await, list, or cancel. UI history is application-wide. After app/MCP server
restart the registry starts empty, so a new MCP session cannot enumerate or
claim an older session's durable reviews merely by guessing an ID. Cross-session
history/resume would require a new explicit authorization token and is not part
of this recovery.

### Authentication and executable consumers

```swift
let method: CodexReviewAuthenticationMethod = switch choice {
case .chatGPT:
    .chatGPT
case .apiKey(let input):
    .apiKey(try CodexReviewAPIKey(validating: input))
}
let request: CodexReviewAuthenticationRequest = store.auth.hasActiveSavedAccount
    ? .addAccount(using: method)
    : .signIn(using: method)
try await store.performPrimaryAuthenticationAction(request)

let executable = try await executableResolver.resolve(
    configuredPath: preferences.codexExecutablePath,
    environment: environment
)
```

The UI drops its input buffer before awaiting authentication and never stores
the secret in observable or durable state. The resolver is the only executable
candidate/precedence owner; process transport receives one validated
`ExecutableCapability`, borrows its diagnostic path only inside the immediate
#113 revalidation/`Process.run` handoff, and performs no second PATH/app-bundle
search.

Observed on 2026-08-20: `launchctl getenv PATH` was empty, while the Xcode-
launched ReviewMonitor environment selected `/opt/homebrew/bin/codex`; the
official `/Applications/ChatGPT.app` had bundle ID `com.openai.codex` and a
bundled CLI, and same-named apps under `~/Applications` were Safari Web Apps.
This evidence makes both injected deterministic filesystem roots and bundle-ID
validation load-bearing. Precedence remains contractual rather than choosing by
version: selecting the bundled CLI ahead of PATH requires an explicit setting.

Executable precedence is fixed:

1. An explicit normalized settings path. If present but not executable, throw;
   do not silently fall through.
2. The first explicitly configured environment command in
   `CODEX_APP_SERVER_CODEX_EXECUTABLE`, `CODEX_REVIEW_CODEX_EXECUTABLE`,
   `CODEX_EXECUTABLE` order. An invalid explicit command throws.
3. `codex` in the process `PATH`, preserving PATH order.
   Empty components are ignored rather than interpreted as the current working
   directory.
4. `<injected-home-directory>/.local/bin/codex`.
5. App-bundle resources, in this order:
   `/Applications/ChatGPT.app/Contents/Resources/codex`,
   `/Applications/Codex.app/Contents/Resources/codex`,
   `<injected-home>/Applications/ChatGPT.app/Contents/Resources/codex`, then
   `<injected-home>/Applications/Codex.app/Contents/Resources/codex`.
6. `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, then standard system bin
   directories.

The home locator comes from `FileManager.homeDirectoryForCurrentUser` at live
composition, not the `HOME` environment. Candidate strings are opened through
the descriptor owner; executable regular-file policy and deduplication use
`fstat` volume/device/inode identity. Standardized/canonical spelling is retained
only in diagnostics and never as candidate authority.
Bundle-resource candidates additionally require an existing `.app` directory,
an `Info.plist` whose `CFBundleIdentifier` is `com.openai.codex`, and the exact
`Contents/Resources/codex` layout before executable validation. Total failure
returns one typed source-by-source search trace. Invalid implicit PATH/home/
bundle/system candidates continue; an invalid explicit setting or the first
present explicit environment key throws without fallback. The composition root
resolves exactly once per app lifetime and injects the same
`ExecutableCapability` into primary and staging runtimes. Transport requires
that capability, performs no second search, and asks the #113 descriptor owner
to revalidate both executable and Codex-home identities immediately before each
`Process.run`; session-source probing uses only that executable capability.
Live composition supplies `/Applications`, the known fallback bin directories,
and the real filesystem collaborator once. Tests inject temporary application/
home/bin roots and metadata through `Configuration`/`FileSystem`; they never
create fake bundles or executables in real system directories.

### History paging and deletion consumer

```swift
let page = try await store.historyQuery.loadNextPage()
try await store.deleteReviewHistory(jobID: terminalReviewID)
```

ReviewUI offers deletion only for a terminal review and confirms the operation.
The selection owner clears a deleted selected review after the database commit;
an active review produces a typed invalid-state error rather than implicit
cancellation.

## 7. Access control plan

### Keep public

- Existing v0.6.2 consumer types and commands needed by ReviewUI/MCP/tool app:
  `CodexReviewStore`, `CodexReviewJob`, `ReviewJobCore`, `ReviewLogEntry`, review
  target/request/result/error types, authentication/settings models.
- Additive read-only terminal facts: `ReviewTerminalKind`,
  `ReviewTerminalRecord`, `ReviewInterruptionCause`, and
  `ReviewJobCore.Lifecycle.terminal`. The store/reducer remains the mutation
  owner; the exact v0.6.2 lifecycle initializer remains available.
- Additive awaited lifecycle entry points: `CodexReviewStore.close()` for the
  app/runtime owner and `ReviewMonitorWindowController.closeAndWait()` for the
  native composition owner. Neither exposes persistence types.
- No new persistence API. Existing public raw String IDs remain source-compatible;
  package code converts them to the typed `ReviewID` at the boundary.

### Package/internal

- SQLite tables, migrations, database factory, row DTOs, mutation/commit values,
  writer actor, query subscriptions, import/migration helpers.
- `ReviewRuntimeGeneration`, `RuntimePublicationSnapshot`, `PreparedRuntime`,
  `RuntimeLifecycleHandle`, `MCPServerGeneration`, `PreparedMCPServer`,
  `MCPServerLifecycleOwner`, `ReviewLifecycleResourceFailure` and its nonempty
  aggregate, and their transition state. These exist only for Store/Host/
  AppServer composition and are not consumer-facing lifecycle vocabulary.
- `RecoveryDescriptorFileSystem`, `DirectoryCapability`, managed file/executable
  capabilities, `RecoveryEnvironmentPlan`, and `PreparedRecoveryEnvironment`.
- App-server wire DTOs and notification reducers.
- Authentication disk/lease/provider adapters and executable candidate strategies.

### Remove or do not port

- `CodexAppServerKit`, `CodexAppServerKitTesting`, and `CodexDataKit` products.
- Generic Codex chat sidebar/detail types and source-kind presentation fallback.
- `ReviewChatLogUI` split introduced only for the unreleased generic-chat path.
- Any GRDB re-export or public table/query wrapper.

All new declarations default to package/internal. Each public addition must be
reachable from the consumer code above.

The recovery adds `Fixtures/CodexReviewKitProductConsumer`, a separate Swift
package that depends on the root package products and imports all four released
modules without `@testable`. It builds, links, and runs the documented public
consumer stories. A `swift-api-digester`/symbol inventory compares each public
module with the v0.6.2 baseline and requires every accepted difference to be
listed in this document.

Wave 3B's only public addition is
`@MainActor public func CodexReviewStore.close() async throws`; the released
`start(forceRestartIfNeeded:)`, `stop()`, `restart()`, `waitUntilStopped()`,
review/cancellation/result, and MCP surfaces remain exact. The external consumer
fixture uses an async `main` and actually executes `try await store.close()`.
`scripts/compatibility-baselines/v0.6.2/public-api.json`, its README, and checksum
metadata record this one accepted additive difference. MCP `tools/list` remains
the byte-equivalent published five-tool JSON; tool names and input schemas do not
change. `ReviewMonitorWindowController.closeAndWait()` is a separate Wave 3C
addition and baseline update.

## 8. Variation axes and addition tests

| Axis | Single absorption point | Variant addition test |
|---|---|---|
| Live / preview / test backend | `CodexReviewStoreBackend` composition | Add one backend implementation; no UI/store branch |
| Live listener / declared no-MCP composition | `MCPServerLifecycleOwner` | Add one owner implementation; Live activation returns actual URL, no-MCP returns nil, and no caller fallback/placeholder is added |
| ChatGPT / API key auth | authentication submission/provider owner | Add one provider case + adapter registration |
| App-server notification kind | backend decoder/reducer | Add one typed event handler; no UI/persistence decode |
| Review attempt generation | product review processor | Add restart attempt without creating a new review row |
| Live / preview / test database | composition-root database factory | Inject on-disk or temporary DB; no product branch |
| MCP identifier alias | MCP request decoder | Add alias at decoder only; core keeps `ReviewID` |
| Log presentation kind | `ReviewLogEntry.Kind` projection | Add kind + one renderer registration, not transport casts |
| Manual workspace/review order | anchor-based history reorder command | Add/move a row using one stable before-ID |
| Default / explicit / test storage root | `RecoveryEnvironmentPlan` + trusted descriptor policy | Add one trusted-anchor policy; no caller URL guard |
| Managed file operation | `RecoveryDescriptorFileSystem` | Add one descriptor-relative operation; no `FileManager` mutation path |
| Authentication session disk state | `AuthenticationDiskStateV1.sessionState` | Add one enum case/migration in the auth disk actor; no second manifest |

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

- Retire the former Wave 0 path-owned `CodexReviewRecoveryEnvironment`
  preparation/removal implementation and never merge `c83e499`.
- Replace bare RecoveryV1/runtime/history/login URLs at mutation/open boundaries
  with `PreparedRecoveryEnvironment` capabilities in issue #113.
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
- GRDB imports or observations outside the persistence/query owner.
- A global default database accessed from arbitrary domain/UI call sites.
- An MCP listener/lease or server URL stored in `PreparedRuntime` or owned by a
  replaceable AppServer handle.
- A placeholder/default MCP URL for Direct/Preview/Testing or publication of a
  pre-bind port-0 URL; explicit no-MCP is `nil`, not inferred recovery.
- Store review/rate-limit/cleanup Tasks hidden behind a Host lifecycle handle.
- A close method that throws before attempting later signals, or a completion
  wait started before the client/process close signal was attempted.
- Persistence or executable-discovery methods added to
  `CodexReviewStoreBackend`.
- Preview/test branches in production reducers or renderers.
- Fallback to empty history on database or observation error.
- Canonical/standardized/resolved path strings as containment, ancestry,
  creation, or deletion authority.
- A raw URL saved after preparation and later passed directly to Process or GRDB.
- An Environment-owned login cleanup manifest or recursive URL removal beside
  RegistryV2 authentication debt.

## 11. Test plan

### Characterization before migration

- v0.6.2 job-owned sidebar/detail and fixed duration.
- Human review output from `exitedReviewMode.review`.
- Current notification/terminal/cancellation/login fixtures captured from the
  source branches listed in issues #104–#107.
- Each current-wire fixture records upstream Codex
  `3b45c29062ff0e76e71c91b6753290400e7fa8da`, installed binary
  `0.148.0-alpha.15`, and the source/schema revision that produced it; release
  validation refreshes the live probe if the installed binary changes.
- Existing log truncation, append/replace, command panel, find, and scroll-tail
  behavior.
- Controlled two-review gate: one attempt's grace force-close closes both
  streams; current code terminalizes the sibling and attempts resume on the
  same permanently closed client (PR #117 P1).
- Controlled runtime-factory gate: stop/close wins while preparation is held;
  current Host completion can still install stale client/backend state and
  publish `.running`.
- Concurrent close callers currently execute shutdown more than once.
- Controlled MCP-handler and rate-limit-refresh gates prove current stop/cancel
  reports completion before those already-owned Tasks finish.
- Controlled Store-worker/Host-reader gates prove current shutdown has no owner-
  specific completion boundary or enforceable close-signal-before-Host-wait
  ordering.
- Client close cannot prove the AppServer backend's private
  `notificationRouterTask` and review-event sessions are finished; Host has no
  Task/session handle, and testing Bool/`Task.yield()` observation is not a
  semantic completion seam.
- Inject two or more shutdown failures and prove current code drops/logs later
  failures rather than retaining deterministic lifecycle and registration order.
- Reverse the timeout-detach characterizations in
  `CodexReviewStoreCommandTests` to the target awaited-completion contract; no
  wall-clock timeout or request count is completion evidence.

### Descriptor capability contract (#113)

- Component-by-component `openat` uses
  `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`; missing-leaf `mkdirat` is followed by
  reopen/`fstat`, never path inference.
- Case-only, Unicode-normalization, firmlink, and reverse-ancestor aliases cannot
  authorize a managed source/destination relationship; diagnostic spelling does
  not affect identity.
- Symlink in every component position, non-directory component, wrong UID,
  group/world mode, unreadable/extended/inherited ACL, mount crossing, and
  unknown metadata fail before mutation.
- Existing explicit homes are not chmod/chown/ACL-mutated. Safe default,
  explicit, preview, and temporary test anchors follow their declared policy.
- Inject controlled swaps before/after creation and immediately before Process
  and GRDB handoff. Device/inode mismatch rejects the handoff and calls neither
  path-only consumer.
- Descriptor-relative bounded read, temp write/fsync/renameat/directory-fsync,
  and manifested recursive unlink preserve exact identity across injected
  failures. No test uses a mutation-capable global path such as `/Library`.
- Read-only absolute locator parsing performs no I/O; source open walks from the
  retained trusted root, allowlist enumeration returns only capabilities/
  relative components, descriptor copy cannot mutate source, and alias/mount/
  identity swaps never fall back to locator spelling.
- Cleanup refuses an unmanifested child, referenced pending session, identity
  mismatch, symlink, mount boundary, and policy change; source and neighboring
  entries remain byte-for-byte unchanged.
- Tests record the same-UID path-only residual as an explicit threat-model
  limitation rather than claiming it is eliminated.

### Persistence contract (#102, #108)

- Fresh database, every schema migration, corrupted/incompatible database, and
  proof that the first GRDB open occurs only inside last-moment capability
  revalidation from `PreparedRecoveryEnvironment`.
- Atomic run + log mutation, injected commit failure, process termination after
  each transaction boundary.
- Mid-ingestion write/observation failure closes mutation admission, stops and
  awaits upstream workers, fails MCP waiters, preserves last-good UI, and
  recovers only through full reopen/orphan handling.
- Failed-state close joins that worker shutdown, skips semantic writes, closes
  the pool, preserves the complete failure aggregate plus any additional
  physical-close secondary, and gives repeat callers the same result.
- Restart hydration with identical title/status/duration/result/log.
- Empty/partial app-server list while durable history remains unchanged.
- Duplicate/replayed event identity, sequence order, old-attempt isolation, and
  cap/truncation.
- Stable durable/public effective entry IDs, v0.6.2-compatible effective counts,
  text, metadata, paging, grouped replacement, and capped-text behavior across
  restart; `latestSourceEntryID` changes without replacing the projection row.
- Completed terminal/result/final-log row commit and digest validation are
  atomic; the log marker joins the one text owner; corruption or injected
  mismatch never chooses one copy as fallback.
- Exactly one visible final row for full marker+assistant delivery and sparse
  promotion, plus 256 KiB/over-limit final-result, Unicode boundary, cap
  priority, DB-size, and loaded-window memory cases.
- Copy/import cutover leaves the current-main source untouched and is idempotent.
- Active-source import refusal, WAL/SHM quiescence, before/after manifest change,
  same-key/different-hash conflict, success rollback, and separate failure
  manifest transaction.
- Exact custom/default legacy-root resolution, unknown SQLite refusal, lsof
  process/FD ownership, raw main/WAL/SHM cohort copy, staging backup/quick-check,
  UserDefaults before/after equality, and source zero-diff after every failure.
- Plain/zstd + legacy/paginated exact-ID staging reads, sanitized auth-free
  app-server, outer/reviewer-child eligibility matrix, deterministic review/
  attempt/log ID goldens, and live/import normalizer equivalence.
- Exact/lower-bound/unavailable imported duration including duration-only rows;
  eligible count equals imported plus documented skips and eligible failure is
  zero before admission.
- Current-main numeric auth schema 0/1, ChatGPT/Bedrock opaque RegistryV2 import,
  a trap proving API-key artifact bytes are never read/copied/hashed, preference
  allowlist/conflict, debt refusal, and untouched legacy keys.
- Cutover journal crash/resume at every state, runtime-before-admission refusal,
  pre/post-admission rollback archive, current-main restart from untouched
  source, and repeat forward cutover from the archive.
- Initial active/recent window, paging, explicit terminal deletion, cascade, and
  large-history memory/latency (#111).
- Anchor-based workspace/review reorder across filters, groups, hidden rows,
  blank-area/end drops, restart, and paging (#110).

### App-server contract (#104–#107)

- Sparse and full terminal snapshots; missing final review fails visibly.
- Current-v2 sparse fallback accepts only the canonical outer turn's documented
  single final-message summary field; generic last-message, async, child, and
  cross-attempt candidates fail.
- Review-scoped command/tool/file/reasoning normalization, preservation of the
  app-server-delivered lossy Unicode string, and proof that unregistered
  standalone command/process deltas cannot mutate a review.
- Interrupt response/terminal races and cleanup ordering.
- Terminal-before-interrupt-response, accepted/rejected/outcome-unknown
  interrupt, duplicate/conflicting terminal, and forced transport close using a
  fake clock plus real worker completion.
- Current ChatGPT login success, cancel, fallback, restart, and API-key accepted
  response/notification/account-read/outcome-unknown flow.
- Nullable ChatGPT email, stable generated saved IDs across nil/non-nil reads,
  same/nil-email accounts remaining distinct, one API-key slot, and duplicate
  rejection before staging/secret access.
- ChatGPT pre-completion account update is ignored; matching completion then
  post-reload update/read is required. API-key pre/post-write cancellation,
  response/connection loss, same-home reconciliation, and pending-admission
  debt are continuation-controlled without secret replay.
- Secret-bearing API-key send has one request ID/stdin write, never retries an
  overload response, and atomically resolves cancel-before-write versus
  may-have-written at the transport boundary.
- Immutable artifact, RegistryV2, `AuthenticationDiskStateV1`, activation
  journal, and primary-runtime-lease crash points; hash/reference corruption
  fails closed; add-account keeps shared bytes/runtime unchanged; sign-in
  forward-completes one activation and performs one Wave 3 account transition.
- Every nested staging/candidate disk-state crash point reuses one session ID,
  candidate account/revision ID, directory identity, and immutable candidate.
  Tests cover candidate rename/fsync before cleanup-continuation commit,
  staging cleanup, candidate.ready next-owner transfer, cancellation discard,
  and debt; unmanifested/mismatched staging is preserved with typed failure.
- Repeated/concurrent `LoginStagingLease.close()` joins one result; runtime/
  client/reader/writer failure prevents removal, manifest failure prevents
  unowned deletion, removal/finalization failure records debt, and all failures
  reach app close instead of becoming log-only diagnostics.
- RegistryV0 migration-journal crash points preserve order/non-secret metadata,
  generated IDs, and Amazon Bedrock; ambiguous active key, duplicate key,
  multiple API-key entries, and missing artifact fail without changing v0.
  Blank/whitespace account keys fall back to normalized email, and Unicode/
  `.`/`..` keys reproduce the exact existing Foundation directory encoding.
- Provider-event and reconciliation grace expiry each trigger owned close/read,
  never fabricate success/cancellation, and leave finite typed debt. Staging
  process close failure retains and joins the real resource Task and exact
  descriptor capability.
- Journal-committed `.committedActivationPending` rejects reauthentication and
  forward-completes the same saved ID after restart. Simultaneous old runtime
  lease + activation journal is rejected as an impossible persisted state.
- Cancellation before activation `committingJournal` creates no journal and
  first persists candidate cancellation intent, restarts the previous account
  runtime exactly once after quiescence, and resumes candidate discard/debt at
  every crash boundary; cancellation after that linearization loses to
  activation-pending.
- Executable precedence including installed ChatGPT.app/Codex.app bundle
  identity, classic/Safari bundle rejection, invalid explicit no-fallback,
  PATH order/empty components, injected home, symlink deduplication, total
  failure, and proof that transport performs no second discovery.
- `AppServerProcessTransport.Configuration` cannot be constructed without the
  validated executable and Codex-home capabilities; primary/staging
  configurations receive the identical executable capability, revalidate at
  Process handoff, and session-source probing does not trigger discovery.
- Runtime transition matrix coverage for explicit cancel, stop, same-account
  restart, account change/reconciliation, recoverable network loss,
  nonrecoverable protocol/process death, and application termination.
- Two concurrent reviews plus one grace force-close: the target reaches its
  requested terminal, every healthy sibling joins forced-generation recovery
  once, and the Host factory creates one replacement client/backend pair.
- The old backend is handoff/cleanup-only and the new backend is resume-only;
  sibling resume never reaches the closed client. A sibling canonical terminal
  that wins before old-runtime close suppresses only its own resume. Once close
  is signaled, zero eligible siblings still produces/publishes one replacement
  runtime while the Store remains open.
- Replacement creation/validation failure produces the same typed terminal for
  every still-eligible sibling without retry or per-sibling runtime creation,
  publishes typed runtime failed, leaves Store review/runtime admission closed,
  and keeps the existing MCP listener available for typed status/failure output.
- Recovery interrupt acknowledgement before/after canonical terminal, proving
  that acknowledgement never detaches the old event subscription/session;
  canonical `completed`/`failed` suppress that attempt's candidate while
  canonical `interrupted` and a policy-recoverable connection terminal permit
  exactly one; per-attempt disposition never suppresses mandatory AppServer
  runtime replacement after a shared old-runtime close signal.
- Cancellation racing an in-progress recovery joins the old admission's one
  request/barrier, issues no duplicate interrupt, and prevents replacement;
  after the barrier, a replacement uses a distinct attempt ID and fresh
  `ReviewStartAdmission`, including cancellation-before-dispatch proof.
- Recovery disposition is installed before token creation; concurrent explicit
  cancellation and outcome-unknown-plus-connection cannot fabricate requested
  cancellation or leave a token for a product-terminal result.
- Attempt ownership remains one coherent run/admission state through rollback
  and replacement start; no observation can pair the old run with the fresh
  admission.
- Cancellation/terminal before initial or replacement start registration is
  preserved, performs zero backend writes, and cannot be overwritten by
  `ReviewStartAdmission.start`.
- A registered start remains backend-inert until Store publication followed by
  exact-handle activation; cancellation/terminal before activation resolves the
  Task with zero writes.
- Mailbox/worker terminal round-trips retain typed network, forced-close,
  unexpected-connection, process, protocol, and owner-cancellation cases;
  process/protocol/unclassified failures never enter recovery via string
  matching or ambient network state.
- Application close failure preserves the last rendered error snapshot and
  requires an explicit Cancel Quit / Quit Anyway decision; post-close
  start/restart no-op and mutation rejection are deterministic.
- Close racing an awaited start/restart invalidates that generation before the
  await completes; late completion cannot publish and its acquired resource is
  joined by the one close Task. Concurrent close/stop callers observe one
  recorded result.
- Framing/routing failure closes the connection; isolated malformed payload or
  conflicting event closes only its attempt; old-attempt events cannot mutate
  product state; no production external-input trap.

### Native UI (#99, #100, #103)

- Source plus reviewer child produces one product row and human detail output.
- Running timer freezes to start/end duration and remains fixed after time moves.
- Orphaned terminal rows stop advancing and clearly distinguish lower-bound or
  unavailable duration from an exact duration.
- Persistence-failed active rows freeze at `lastCommittedAt` as lower bounds and
  disable mutation affordances while retaining selection/readability.
- Stable row/job native identity through history updates and app-server restart.
- Loaded history remains visible while signed out and while server state is
  stopped/starting/failed; auth/runtime state changes command affordances only.
- History loading and persistence failure are distinct from a successfully
  loaded empty history and preserve last-good rows on later query failure.
- Log tail pinning through append/reflow/resize; user scroll-away remains stable.
- Production observation/render completion, not sleep or queue-turn counts, is
  used as the test synchronization point.

### MCP and runtime (#109)

- All five tools from current Codex and Claude Code.
- Multiple sessions/reviews, cancel, long await, paged logs, stop/restart.
- Close/start, close/restart, stop/close, and concurrent-close controlled
  interleavings join one Store state/Task/result. A stale acquired runtime handle
  receives exactly one admission-close/physical-close/wait sequence and its
  snapshot is never published.
- AppServer preparation/activation/second revalidation publishes only auth and
  settings. MCP prepare returns no URL; activation binds and returns the actual
  URL, then exact MCP-generation revalidation precedes publication. Configured
  port 0 deterministically publishes the nonzero assigned URL. Direct/Preview/
  Testing no-MCP owners return `nil` without a placeholder; Live `nil` is a
  typed contract failure.
- Runtime-disable stop closes/drains/awaits one MCP lease and a later start
  prepares/activates a new generation on the same app-lifetime owner.
  restartSameAccount/recoveryReplacement retain the existing listener and never
  create a second lease; application close terminalizes the owner.
- MCP rejects requests after network admission closes, awaits every previously
  admitted handler, then signals and awaits HTTP/protocol session disposal.
- `AppServerClientTests.swift` holds the notification router and event sessions
  at controlled gates. `closeAndWaitForOwnedLifecycle()` invokes client close
  first, remains incomplete until the captured Task/session handles finish, and
  uses neither `notificationRouterIsRunningForTesting` polling nor `Task.yield()`.
- Client-close failure still joins the captured router/session handles and
  returns one `ReviewLifecycleResourceFailureAggregate` ordered by router stage
  then session registration ordinal; the Host handle
  consumes that package seam rather than inspecting private backend state.
- Wave 3A `ReviewRuntimeCloseFailure` cases/equality and
  `ReviewAttemptProcessor.swift` remain unchanged. New lifecycle aggregates
  enter `ReviewClosePrimaryFailure.lifecycleResources` independently of existing
  `.attemptRuntime` values.
- Controlled owner gates prove Store acquisition/review/rate-limit/cleanup work
  completes before AppServer combined close begins. That close sends the
  client/process signal before its physical-completion gate, and Store close
  remains pending while the gate is held; subsequent `waitUntilClosed()` joins
  the same result. Forced close adds the separate Store worker join before
  forced semantic publication.
- Store-owned rate-limit/worker/cleanup callbacks and Host-owned auth/reader/
  router/session/client/process callbacks are independently absent after their
  owner completion.
- Simultaneously inject MCP drain/stop/wait, Store worker/rate-limit/cleanup,
  AppServer combined-close and Host idempotent-wait failures. Repeated close
  replays the same nonempty `first` plus every `additionalInLifecycleOrder`,
  using registration ordinal within concurrent stages, does not duplicate the
  handle's replayed aggregate, and loses no failure to logs. Wave 3B has no
  persistence aggregate value or secondary database-close value.
- After MCP/app restart, ReviewUI still sees durable history while a new MCP
  session receives not-found/empty results for reviews it did not authorize.
- Full package tests and ReviewMonitor app tests.
- External product-consumer fixture build/link/run and public API inventory
  against v0.6.2.
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
| F10 / PR #117 P1 | Store-owned runtime generation, runtime-wide sibling recovery, and one replacement backend/client |
| #98 | Composition-root executable resolver |
| #104 | Canonical terminal reducer and final result |
| #105 | Single notification normalization boundary |
| #106 | Authoritative terminal barrier before cleanup |
| #107 | App-server-owned callback/login completion |
| #108 | Copy/import cutover and rollback safety |
| #109 | Published MCP baseline plus evidence-driven aliases |
| #110 | Anchor-based reorder command plus durable sort transaction |
| #111 | Bounded loaded window, paging, and explicit terminal deletion |
| #113 | Descriptor-backed RecoveryV1 authority and last-moment path-only handoff revalidation |

No numbered finding is intentionally left to the current generic-chat path.

## 13. Migration waves

Every gate is a separately committed and exactly reviewed slice. A later gate's
tests/review never validate an earlier one, and each owner cutover removes its
replaced path in the same slice.

The final predecessor chain is:

1. **Gate V — log viewport (#103)** was independently published from restored
   v0.6.2 by PR #114 (`55f68c0` → merge `f4c9bb0`) as the native behavior fix.
2. **Gate C — published compatibility** also branches from restored v0.6.2 and
   publishes independently. It need not contain Gate V, but its reviewed API/
   consumer/MCP baselines must precede any public terminal addition.
3. **Wave 2 — current event contract (#104, #105)** lands on the reviewed
   compatibility gate and ports notification normalization/canonical terminal
   result into the product-owned in-memory flow. Record and review this exact
   HEAD before Wave 3 starts.
4. **Wave 3 — lifecycle/cancellation (#106)** uses a sequential implementation
   checkpoint 3A → exact-base checkpoint review → 3B, but PR #117 P1 makes 3A
   unsafe to merge independently. The combined Wave 3A+B diff is one exact-base
   merge gate; only its reviewed HEAD may precede 3C → reviewed 3C. This proves
   the in-memory terminal-before-cleanup and throwing, joined
   runtime/application close owner. Issue #106 remains open until Wave 4 inserts
   the durable commit.
5. **Descriptor capability core (#113)** starts only from reviewed Wave 3C. It
   retires the former Wave 0 path owner, produces one
   `PreparedRecoveryEnvironment`, and proves descriptor-relative mutation plus
   the last-moment Process handoff. It also fixes the nonescaping
   `openHistoryDatabase` adapter contract, but does not add GRDB. Its reviewed
   HEAD is a hard prerequisite for the first GRDB open and Wave 5 login staging.
6. **Wave 4 — history foundation and ownership cutover (#102, #110, #111)** is
   sequential 4A schema/writer → 4B atomic query → 4C Store/UI/MCP cutover →
   4D fail-closed/orphan/close insertion, with exact review after each slice.
   4A is the sole implementer/test owner of the GRDB adapter over the reviewed
   revalidation core; it consumes the prepared history capability and may not
   accept a raw URL.
   Authentication pending/cleanup debt stays outside this database.
7. **Wave 5 — authentication/runtime discovery (#97, #98, #107)** starts from
   reviewed 4D and explicitly consumes reviewed Wave 3 close plus #113. It lands
   RegistryV2/authentication disk state, provider-neutral `LoginSession`/
   `LoginStagingLease` plus pending/debt/startup reconciliation, executable
   capability composition, then provider flows/activation as the sequential
   slices in its task brief.
8. **Wave 6 — product presentation and MCP completion (#99, #100, #109)**
   supplies one row/detail, fixed duration, and the published MCP contract, with
   Gate V kept green.
9. **Wave 7 — safe state cutover and live proof (#108)** consumes reviewed #113,
   Wave 4 import, and Wave 5 RegistryV2 seams for snapshot/copy/import,
   restart/replay, and the current-client/runtime matrix.

Wave 3B is restricted to the exact 13 production and 11 test/gate paths in
`Docs/recovery-wave-3-task-brief-2026-08-20.md`, including the new
`Sources/CodexReview/ReviewRuntimeLifecycle.swift` and existing
`Sources/CodexReview/Store/CodexReviewStoreBackend.swift`. The one added
AppServer production path is
`Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift`, limited to its
package lifecycle seam that directly joins the owned router Task and event
sessions after client close; its matching added test path is
`Tests/CodexReviewAppServerTests/AppServerClientTests.swift`. All other
`Sources/CodexReviewAppServer/**` edits, decoder/reducer/routing behavior, and
`Sources/CodexReview/ReviewAttemptProcessor.swift` are excluded. Wave 3C,
GRDB/history/schema/migrations/dependencies, descriptor/environment preparation,
authentication provider/wire/RegistryV2/login staging, MCP tool/schema/golden
changes, and workflows remain excluded. A required edit outside the exact set
returns to the design gate before implementation.

Former Wave 0 is not a predecessor. Its path-owned change chain
(`9e5bf73`, `a58daeb`, `59caa59` and follow-ups through `c83e499`) is evidence
only and must not be merged. A historical descendant may contribute only its
non-Wave0 diff replayed onto the required reviewed base. Current local/remote
checkpoints are likewise evidence until the exact base and review are recorded.

### File and time budgets

| Gate / slice | Time budget | Maximum changed files | Owner |
|---|---:|---:|---|
| Former Wave 0 | Retired | 0 | Rejected path-owned environment |
| Gate V | 3 hours | 2 production + 2 test | Native log viewport |
| Gate C | 5 hours | 10 test/fixture/script | Published compatibility |
| Wave 2 | 18 hours | 9 production + 8 test/gate | Current-event decoder/reducer |
| Wave 3A | Within 48-hour Wave 3 total | 17 production + 10 test/gate | Attempt/AppServer barrier |
| Wave 3B | Within 48-hour Wave 3 total | exact 13 production + 11 test/gate allowed paths | Store/AppServer lifecycle/Host/MCP close |
| Wave 3C | Within 48-hour Wave 3 total | 12 production + 7 test/gate | ReviewUI/application close |
| Descriptor core #113 | 24 hours | 8 production + 7 test/gate | Descriptor filesystem + plan/Process handoff + GRDB adapter contract |
| Wave 4A | 24 hours | 12 production/dependency + 4 test | Sole GRDB adapter + schema/writer |
| Wave 4B | 24 hours | 8 production + 5 test | Atomic query/projection |
| Wave 4C | 40 hours | 31 production + 13 test/gate | Store/UI/MCP history cutover |
| Wave 4D | 28 hours | 13 production + 9 test/gate | Fail-closed/orphan/close insertion |
| Wave 5A | 28 hours | 10 production + 7 test | Auth disk + RegistryV2/state migration |
| Wave 5B | 28 hours | 10 production + 8 test | `LoginSession` foundation + `LoginStagingLease` + pending/debt recovery |
| Wave 5C | 16 hours | 6 production + 5 test/gate | Executable capability resolver + #113 handoff composition |
| Wave 5D | 36 hours | 14 production + 10 test/gate | ChatGPT/API-key + activation/runtime lease |

Budgets are stop/escalation boundaries, not targets and not permission to touch
every listed file. Wave 6 retains a design gate before dispatch; Wave 7 slice
budgets remain in its committed task brief. Exceeding a budget, reaching three
failed fixes in one failure class, or adding a repeated path/cleanup guard freezes
the slice and returns to this design gate.

## 14. Acceptance criteria

- The recovery target graph remains the v0.6.2 graph; no generic DataKit/chat
  product is reintroduced.
- Former Wave 0/c83 path authority is absent. Every managed RecoveryV1 mutation
  uses a reviewed descriptor capability from one prepared environment.
- No Process or GRDB path-only open occurs without immediate full-chain identity
  revalidation; canonical URLs remain diagnostic only and the same-UID residual
  is documented rather than misrepresented as solved.
- GRDB imports exist only in the persistence folder.
- Sidebar/detail/MCP all read the same committed product review/history.
- App-server omission, restart, or connection loss never clears committed UI.
- One logical review has one ID/row, one lifecycle, one duration, and one final
  result; internal reviewer threads never become product rows.
- Completed duration is stable and logs survive app restart.
- Database and task close paths are awaited and leave no callback/write after
  close.
- Wave 3A `ReviewRuntimeCloseFailure` remains unchanged; Wave 3B lifecycle
  resource failures use their separate nonempty aggregate.
- AppServer client close is followed by direct joins of the owner-captured
  notification router Task and event sessions; no Bool polling or `Task.yield()`
  is accepted as shutdown proof.
- Shared AppServer force-close creates at most one replacement generation:
  requested target terminalizes, healthy siblings resume exactly once on the
  new backend, and no sibling resumes on the closed client.
- Runtime preparation is inert; only exact-generation Store activation can
  publish, MCP network admission closes before handler drain, and repeated
  Store close callers replay one typed result.
- Login staging has one lease/close result and one RegistryV2 authentication
  pending/debt owner; cleanup removes only a manifested identity match.
- Required issues #97–#100, #102–#111, and #113 meet their acceptance criteria;
  #101 remains explicitly out of scope.
- All new public declarations are justified by consumer code; all SQLite and
  wire implementation types remain package/internal.
- Package tests, app tests, migration tests, runtime scenarios, and Codex review
  are green.

## 15. Design gate decision

Approval of this document authorizes migration implementation on
`codex/v0-6-2-recovery` only in the predecessor order above. It explicitly does
not authorize Wave 3A to merge without the combined Wave 3A+B exact-base gate,
former Wave 0/c83 integration, Wave 4 before reviewed #113, or Wave 5 before its
reviewed Wave 3/#113/Wave 4 prerequisites. It does not authorize push, PR
creation, release, or tag creation.
