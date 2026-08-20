# Recovery Wave 3 task brief (2026-08-20)

Status: Authorized for Wave 3A. Wave 3B/3C remain gated on the reviewed prior
slice SHA.

| Item | Value |
|---|---|
| Integration branch | `codex/v0-6-2-recovery` |
| Wave 3A base | `51354e8c01ce04e1992bce252f6e778dca7edd98` |
| Wave 3B base | Reviewed Wave 3A HEAD; record before dispatch |
| Wave 3C base | Reviewed Wave 3B HEAD; record before dispatch |
| Approved design | `Docs/recovery-design-2026-08-20.md` |
| Issue | #106 cancellation terminal barrier |
| Upstream contract | `openai/codex@3b45c29062ff0e76e71c91b6753290400e7fa8da` |
| Budget | 48 hours total: 3A at most 17 production + 10 test/gate files; 3B at most 18 production + 10 test/gate files; 3C at most 12 production + 7 test/gate files |

Wave 3 replaces acknowledgement-as-completion, timeout detachment, and
caller-owned shutdown with one attempt cancellation processor and one
application-lifetime close authority. It lands as three sequential, stacked
workers with disjoint primary owners: **3A** implements attempt cancellation and
the AppServer interrupt/transport barrier; **3B** starts from reviewed 3A and
implements store runtime-generation, Host/MCP, and public store close; **3C**
starts from reviewed 3B and connects ReviewUI/application termination to that
close. It remains an in-memory wave: Wave 4 inserts durable commits and
database/query close stages into the same owner. Issue #106 therefore remains
open until Wave 4 proves commit-before-cleanup.

## Outcome

- A successful `turn/interrupt` response records request acceptance only.
- The matching canonical `(reviewThreadID, turnID)` `turn/completed`, or a typed
  connection/process terminal after force-close, is the completion barrier.
- Review cleanup, worker removal, MCP waiter completion, runtime teardown, and
  application termination happen only after that barrier and all owned Tasks
  have actually finished.
- `CodexReviewStore` has one app-lifetime state and one recorded close Task.
  Concurrent close/stop callers join it; start/restart completions from an
  invalidated generation cannot republish or reacquire runtime state.
- A close failure is visible and replayable. ReviewMonitor defaults to **Cancel
  Quit** and allows **Quit Anyway** only as an explicit user decision.

## Broken invariants to remove

- `AppServerCodexReviewBackend.interruptReview` currently finishes the event
  stream immediately after interrupt ACK.
- `CodexReviewStore.cancelReview` immediately commits local cancellation and
  cancels its worker after the request returns.
- runtime stop races worker drain against a sleep, cancels the drain Task on
  timeout, moves workers to a detached dictionary, and reports stopped while
  work can remain alive.
- backend cleanup deletes/unsubscribes review threads before terminal and
  reader/router/worker completion are proven.
- `stop()` and `restart()` can interleave across `await`, allowing a stale start
  completion to publish after shutdown began.
- application termination always replies `true` after nonthrowing `stop()`;
  there is no typed failure or explicit user decision.
- UI observations/render Tasks rely on deinit cancellation and are not awaited
  before store close.

## Owners and state machines

### Attempt cancellation owner

One attempt-scoped processor owns request state and terminal state together.
Do not add flags at call sites.

```text
queued
  -> preparingThread(
       threadRequestDispatch: notSent | outcomeUnknown,
       threadStartTask,
       graceTask,
       forceCloseTask?
     )
  -> startingReview(
       preparedThreadID,
       reviewRequestDispatch: notSent | outcomeUnknown
     )
  -> active(canonicalPair)
  -> interrupting(
       requestedBy,
       requestTask,
       terminalBarrierTask,
       graceTask,
       forceCloseTask?
     )
  -> finishing(terminal, requestTask?, graceTask?, forceCloseTask?)
  -> terminal(ReviewTerminalRecord)
```

The backend start operation is part of this processor rather than one opaque
`await startReview`. It exposes a package-only, owned start handle whose state
distinguishes thread preparation from dispatch of the review-producing
`review/start` request. Cancellation in `queued` or
`preparingThread(.notSent)` completes locally after the admission refuses the
thread write. Once `thread/start` may have been written, preparingThread waits
for its response, a typed connection terminal, or the injected grace triggering
the same owned force-close; it never joins an outcome-unknown request forever.
If a thread was created, the processor refuses the later review request,
performs typed thread cleanup, and only then commits requested cancellation—an
empty thread interrupt ACK is never treated as a review terminal. In
`startingReview(.notSent)`, the same
cleanup-before-cancel path applies. Once `review/start` dispatch may have
occurred, cancellation joins its response/connection outcome; on success it
interrupts and awaits the returned canonical pair, and on connection loss it
resolves through the typed connection terminal. Cancelling the caller Task does
not abandon either request or fabricate cancellation.

Use one store-created `ReviewStartAdmission` actor/value plus the registered
start Task. The backend must atomically ask that admission immediately before
both the `thread/start` and `review/start` writes. A pre-recorded cancellation
refuses the relevant write and proves `.notSent`; admission of either write
irreversibly records that stage as `.outcomeUnknown` until response/connection
resolution.
Store cancellation and backend dispatch consult this same value—there is no duplicated
`startingJobIDs`/`startupCancellations` truth. The backend returns an immutable
attempt value and never publishes directly into the store.

The processor accepts three independently ordered inputs:

1. interrupt request response: accepted, explicitly rejected, or
   outcome-unknown transport failure;
2. the canonical attempt terminal from the Wave 2 reducer;
3. connection/process terminal, including the result of an owned force-close.

Rules:

- matching terminal before ACK wins; a later successful ACK is idempotent;
- ACK before terminal remains pending and cannot finish the product review;
- explicit request rejection clears the cancellation request and throws the
  original typed request error unless a terminal already won;
- request transport failure is outcome-unknown and waits for the matching
  terminal/connection result rather than being relabeled rejection;
- duplicate identical terminal is a no-op; conflicting terminal is a typed
  attempt contract failure and never rewrites a committed terminal;
- auxiliary, stale, child, and cross-attempt terminals cannot satisfy the
  barrier;
- queued work not dispatched to app-server may cancel locally; a started or
  in-flight attempt may not;
- a review already in `waitingForConnectivity` has no live attempt barrier and
  may commit explicit requested cancellation while preventing recovery;
- one cancellation command owns admission. Repeated callers join the same
  outcome rather than issuing a second interrupt.

The processor retains every Task handle shown above. Terminal-first does not
discard the still-running request Task; request-first does not discard the
barrier Task. Grace expiry may create exactly one force-close Task. Processor
cleanup awaits request, barrier, grace cancellation, and force-close completion
before releasing the attempt. Repeated cancel callers join one recorded
cancellation Task/result.

An explicit rejection received before any terminal transitions
`interrupting -> active(canonicalPair)`, clears the cancellation admission, and
returns the original rejection. A terminal transitions first to `finishing` so
the product fact may win while all remaining handles stay owned; only after they
join does state become `terminal` and cleanup begin. A terminal-first request
Task must finish by response, typed connection terminal, or the same injected
grace triggering connection force-close. It cannot wait forever or be dropped
merely because the product terminal is already known. A later rejection is a
diagnostic and does not reverse the terminal.

`thread/status/changed`, `thread/closed`, `item/completed`, and interrupt ACK
are never substituted for the canonical turn terminal. A known-dead connection
is a distinct typed terminal input, not an inferred successful cancellation.

Remove the current `AppServerReviewControl` behavior that parses an active-turn
ID from a rejection string and retries interruption against that other turn.
Canonical-pair mismatch is an explicit typed rejection; error text cannot
rebind the attempt or select a new interrupt target.

### Application close owner

`CodexReviewStore` owns this package-only state:

```text
open(runtimeGeneration)
  -> closing(invalidatedGeneration, closeTask)
  -> closed(Result<Void, ReviewCloseError>)
```

The first `close()` installs `closing`, invalidates the runtime generation, and
closes mutation admission before its first suspension. Concurrent/repeated
`close()` calls await the same Task and return/throw the same recorded value.
`stop()` during close joins the runtime-stop stage; after closed it is a no-op.
Public `start()` and `restart()` keep their released nonthrowing signatures and
are no-ops once closing begins.

Every start/restart operation captures the open generation before external
awaits and revalidates it afterward. A late stale completion cannot publish
server/auth/settings/observation state. Any resource it acquired is handed to
the installed close Task and awaited there; it is never abandoned or closed by
an unowned Task.

The store registers each runtime acquisition operation, with its owned Task,
before that operation's first external await. Closing first rejects new
registrations, invalidates the generation, and then awaits the finite registered
set. A stale operation closes and awaits any resource it acquired before its
registered Task completes. The close Task awaits that completion before passing
the runtime-close stage; it never takes a one-time snapshot that a late
completion can miss.

Backend runtime startup no longer mutates `CodexReviewStore` during its own
awaits. The lower `CodexReview` target defines only an immutable
`RuntimePublicationSnapshot` and an opaque package lifecycle-handle protocol.
The Host implementation owns concrete AppServer client/process, MCP server, and
auth-observation resources behind that handle and returns
`PreparedRuntime(snapshot:handle:)`. Only the store publishes the snapshot after
generation revalidation and retains/joins the opaque handle. No Host/AppServer/
MCP concrete type enters `CodexReview`, so dependency direction remains intact.
Stale prepared runtimes enter the registered close operation and are fully
closed there. `close()` does not call public `stop()`; both delegate to one
internal runtime-stop stage with an explicit purpose.

Wave 3 normal-terminal close order is:

1. close store mutation admission and the MCP HTTP listener/network admission;
2. request active review cancellation according to the trigger policy;
3. await canonical attempt/connection terminal;
4. publish the in-memory terminal and finish admitted review/MCP waiters;
5. await already-admitted MCP handlers, then dispose the stopped server;
6. stop authentication/runtime consumers and app-server;
7. await transport readers, notification router, event sessions, review
   workers, process exit, and every cleanup request.

The forced branch has a stricter order. Grace expiry first force-closes the
transport/process, then awaits the actual connection/process terminal and the
complete stop of the affected ingestion/review worker. Only after that worker
can no longer publish an upstream terminal does the close processor publish the
forced transport interruption, finish waiters, and continue with MCP/runtime
close. This branch cannot use the normal step-4-before-step-7 order. A matching
terminal already committed before force-close remains authoritative.

Wave 4 inserts durable terminal/history stages between 3 and 4 and query/DB
close after 7. Wave 3 must expose one insertion point rather than a second close
sequence. Natural completion, requested interruption, connection terminal, and
ingestion failure all call the same awaited `finish(terminal:)` owner. In Wave
3 its body performs the in-memory mutation before projection/waiter publication;
Wave 4 replaces that body with the durable history commit. Cleanup is invoked
only from the returned finish result.

`ReviewRuntimeClosePolicy.terminalGrace` is injected; production uses 10
seconds and tests use a controlled suspension. Grace expiry triggers transport
and process force-close. It does not prove completion. The owner then awaits
the actual connection terminal and all worker Tasks. No second timeout detaches
them.

`JSONRPC.Transport.close()` becomes a throwing package contract (with updated
process, fake, preview, and testing conformances) so force-close/process failure
cannot be erased by a nonthrowing adapter. `AppServerClient` and Host preserve
that typed value through `ReviewRuntimeCloseFailure`; callers never recover it
from log text.

### Trigger policy

| Trigger | Product meaning |
|---|---|
| Explicit UI/MCP cancel | Await barrier, then requested interruption; no retry. |
| `store.stop()` / runtime disable | Await barrier, then system-requested interruption. |
| Same-account `restart()` | Interrupt the old attempt but keep the product review nonterminal; transition through connectivity recovery and create exactly one new attempt. |
| Account switch/sign-out/removal | Await barrier, then terminal requested/server interruption; never continue under another credential. |
| Recoverable network loss | Typed old-attempt transport interruption; product remains nonterminal and one recovery owner starts the next attempt. |
| Nonrecoverable protocol/process loss | Typed failed/interrupted terminal; no retry loop. |
| Application termination | System-request interrupt, barrier/force-close, then complete close stages. |

Do not encode these differences as different call-site cancellation sequences.
One runtime transition command carries the trigger/purpose into the owner.

Same-account restart and recoverable transport loss obtain a recovery token and
must not run destructive thread cleanup. They detach the old event session,
close the old runtime, and move directly to `recovering` when the replacement
runtime is authoritative; they do not wait for a network-monitor edge. Exactly
one resume/start consumes the token. Calling
`start(forceRestartIfNeeded: true)` while already running is this restart path,
not an initial-start shortcut.

Force-closing a shared app-server connection for one review does not relabel
siblings as explicitly cancelled. The target commits the requested terminal;
each sibling receives a typed transport interruption and follows its own
recoverable/nonrecoverable transition policy. This intentional shared
generation loss is recoverable for every otherwise healthy sibling: one runtime
transition owner starts exactly one replacement runtime and resumes each
eligible sibling once. Only failure to create/validate that replacement (or an
independently nonrecoverable sibling fault) terminalizes them.

## Package API contract

New types stay package/internal and `Sendable`. Exact spelling may follow the
approved design, but there is one value for each concept:

```swift
package struct ReviewRuntimeClosePolicy: Sendable {
    package let terminalGrace: Duration
    package let sleep: @Sendable (Duration) async throws -> Void
    package static let production: Self
}

package struct RuntimePublicationSnapshot: Sendable {
    // Immutable server/auth/settings values needed for one atomic publication.
}

package enum ReviewRuntimeTransitionPurpose: Sendable {
    case stop
    case restartSameAccount
    case accountTransition
    case applicationClose
    case recoveryReplacement
}

package protocol RuntimeLifecycleHandle: Sendable {
    func close(purpose: ReviewRuntimeTransitionPurpose) async throws
    func waitUntilClosed() async
}

package struct PreparedRuntime: Sendable {
    package let snapshot: RuntimePublicationSnapshot
    package let handle: any RuntimeLifecycleHandle
}

package enum ReviewInterruptRequestOutcome: Sendable {
    case rejected(code: Int?, message: String)
    case outcomeUnknown(message: String)
}

package struct ReviewInterruptRequestFailure: LocalizedError, Sendable {
    package let outcome: ReviewInterruptRequestOutcome
    package let secondaryBarrierDiagnostic: String?
}

package enum ReviewRuntimeCloseFailure: LocalizedError, Sendable {
    case connection(String)
    case process(String)
    case worker(String)
    case cleanup(String)
    case mcpHandlerDrain(String)
}

package enum ReviewPersistenceError: LocalizedError, Sendable {
    case open(String)
    case migration(String)
    case read(String)
    case write(String)
    case close(String)
}

package enum ReviewClosePrimaryFailure: LocalizedError, Sendable {
    case interruptRequest(ReviewInterruptRequestFailure)
    case runtime(ReviewRuntimeCloseFailure)
    case persistence(ReviewPersistenceError)
}

package struct ReviewCloseError: LocalizedError, Sendable {
    package let primary: ReviewClosePrimaryFailure
    package let secondaryPhysicalDatabaseClose: ReviewPersistenceError?
}

@MainActor
public final class CodexReviewStore {
    // All released declarations remain unchanged.
    public func close() async throws
}

@MainActor
public final class ReviewMonitorWindowController: NSWindowController {
    // All released declarations remain unchanged.
    public func closeAndWait() async
}
```

Wave 3 defines this final close-error shape and the single primary/secondary
assembly owner even though it does not yet generate persistence values. Wave 4
adds stages and values, not another error assembler.

Do not change the public `start()`, `stop()`, `restart()`, cancellation, review
result, or MCP tool signatures. The two approved additive public surfaces in
this wave are `@MainActor public func CodexReviewStore.close() async throws` and
`@MainActor public func ReviewMonitorWindowController.closeAndWait() async`;
update the accepted API
baseline and external consumer fixture for both while preserving every released
declaration. Neither exposes persistence implementation types. The Wave 2
terminal fact remains `ReviewJobCore.Lifecycle.terminal`. Run the strict
API/consumer/MCP compatibility gate at every checkpoint.

Close-policy/fake-clock injection is available only through package initializers
and testing factories; it does not change a released public initializer or
`makeLiveStore` overload. ReviewMonitor catches `any Error` and presents its
localized value; package close-error types are not promoted to public API.

The interrupt request Task remains owned and is awaited even when terminal
arrives first. A later rejection is retained as its secondary diagnostic but
cannot rewrite that terminal. Outcome-unknown followed by a matching terminal
returns that terminal while retaining the request diagnostic. Outcome-unknown
followed only by connection/process loss commits the typed product transport
outcome, then returns the original outcome-unknown error to the cancel caller
with the barrier diagnostic; requested cancellation was not proven. Neither
path is reclassified as an explicit rejection.

## ReviewUI and application termination

ReviewUI owns observation/render lifecycle. Add one awaited
`ReviewMonitorWindowController.closeAndWait()` that asks its root/split/detail
owners to synchronously stop admission, cancel observations, cancel and await
the current render Task, detach AppKit/Combine observation, and preserve the
last rendered snapshot. The store must not reach upward into ReviewUI.

The root controller also owns an in-flight content-transition generation and
completion Task. Closing invalidates new transitions and either awaits or
synchronously finalizes the current animation before returning; the existing
unowned `Task { @MainActor ... }` animation completion cannot mutate the view
after `closeAndWait()` completes.

Sidebar filter/reconciliation/cancellation commands that currently create
unrecorded MainActor Tasks are part of the same UI lifecycle. The sidebar owns
their handles (or one child-operation registry), rejects new commands once
closing starts, and joins them through split/root close. Weak capture alone is
not completion proof because the window intentionally remains alive after a
cancelled quit.

UI close joins only UI-owned presentation/caller work. A sidebar/account action
awaiting a Store-owned cancellation/restart detaches its caller wait when UI
closing begins; it does not cancel or await the domain operation. The Store
command has already transferred to its recorded attempt/runtime Task, survives
caller cancellation, and is joined by the subsequent `store.close()`. This
prevents UI-before-store close from deadlocking on a terminal grace that the
store close owner must drive.

The UI owner inventory includes root content observation/transition, split
window and toolbar observation, sidebar topology/filter/selection/action Tasks,
account/status/accessory/toolbar observations, detail selection and render
Tasks, and window/Combine callbacks. One UI lifecycle generation gates all of
them. A normal synchronous window close/window-close callback enters a
restartable suspended generation and cancels its children; reopening explicitly
binds a fresh generation. Application `closeAndWait()` enters terminal closing,
rejects reopen, and joins the same child registry. It does not rely on deinit.

The application composition owner performs:

1. `await windowController.closeAndWait()`;
2. `try await store.close()`;
3. reply `true` only on success.

On `ReviewCloseError`, present one injected/testable AppKit decision with
**Cancel Quit** as the default and **Quit Anyway** as the destructive alternate.
Cancel replies `false` and leaves the frozen error UI readable with mutation
admission closed. Quit Anyway replies `true` only after explicit selection.
Repeated quit attempts join/replay the recorded store close result and do not
restart shutdown.

Composition retains an app-local typed window lifecycle handle; the factory may
still retain the concrete `NSWindowController` for presentation, but it cannot
erase close authority to bare `NSWindowController` or recover it with a cast.
Tests inject a fake handle through the same composition contract. The
application lifecycle owns one pending termination decision/reply state. Every
call returning `.terminateLater` is resolved exactly once. A second request
while work is pending joins that decision; after Cancel Quit replies `false`, a
later new request may present the already-recorded close failure again.

Do not use alert timing, run-loop delays, or deinit as completion proof.

## Allowed write set

### Wave 3A — attempt and AppServer barrier

Expected production owners (consolidate rather than use every file):

- `Sources/CodexReview/Store/CodexReviewStore.swift`
- `Sources/CodexReview/Store/CodexReviewStoreCancellation.swift`
- `Sources/CodexReview/Store/CodexReviewStoreReviews.swift`
- `Sources/CodexReview/CodexReviewBackend.swift`
- `Sources/CodexReview/Store/CodexReviewStoreBackend.swift`
- `Sources/CodexReview/Store/PreviewCodexReviewStoreBackend.swift`
- `Sources/CodexReviewTesting/TestSupport.swift`
- one new package-only attempt/start/cancellation state file under
  `Sources/CodexReview/`
- `Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift`
- `Sources/CodexReviewAppServer/AppServerProcessTransport.swift`
- `Sources/CodexReviewAppServer/AppServerClient.swift`
- `Sources/CodexReviewAppServer/JSONRPC.swift`
- `Sources/CodexReviewAppServer/AppServerReviewControl.swift`
- `Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift`
- `Sources/CodexReviewHost/CodexReviewHost.swift`

Wave 3A propagates the reviewed throwing transport/client close and throwing
`cleanupReview` signatures through StoreBackend, preview/testing conformances,
and the minimum Host call sites so the slice compiles and is independently
green. Unsubscribe/delete/background-terminal cleanup rejection is typed as
`ReviewRuntimeCloseFailure.cleanup`; no `try?` cleanup remains on the review
barrier. Wave 3A does not implement public store close, Host runtime replacement,
MCP drain, or ReviewUI.

### Wave 3B — store runtime, Host/MCP, and public close

- `Sources/CodexReview/Store/CodexReviewStore.swift`
- `Sources/CodexReview/Store/CodexReviewStoreCancellation.swift`
- `Sources/CodexReview/Store/CodexReviewStoreReviews.swift`
- `Sources/CodexReview/Store/CodexReviewStoreTesting.swift`
- `Sources/CodexReview/Store/CodexReviewStoreRateLimitAutoRefresh.swift`
- one new package-only runtime/close state file under `Sources/CodexReview/`
- preview/testing backend and lifecycle-handle conformances
- `Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift`
- `Sources/CodexReviewHost/CodexReviewHost.swift`
- `Sources/CodexReviewMCPServer/CodexReviewMCPHTTPServer.swift`

Wave 3B consumes the reviewed 3A barrier and throwing cleanup/close contract; it
does not redesign the attempt processor. Store-owned rate-limit refresh and
every other registered runtime consumer are cancelled and awaited by the same
close Task. A 3A cleanup failure retains its original operation/cause and is not
folded into worker success or discarded after a product terminal.
Wave 3B updates the accepted CodexReview API/consumer baseline only for public
`CodexReviewStore.close()`.

### Wave 3C — ReviewUI and application termination

- `Sources/ReviewUI/ReviewMonitorWindowController.swift`
- the existing root/split/sidebar/detail UI lifecycle owners only as required
- existing status/accessory/account/toolbar observation owners only when needed
  to join the same UI lifecycle generation
- `Tools/ReviewMonitor/CodexReviewMonitor/CodexReviewMonitorApp.swift`
- matching ReviewUI/ReviewMonitor tests and accepted API/consumer baseline

Wave 3C adds only the accepted ReviewUI
`ReviewMonitorWindowController.closeAndWait()` declaration to that baseline.

Wave 3C does not change the reviewed 3A attempt processor or reviewed 3B runtime,
MCP, and store close implementation. If native integration exposes a missing
lower-layer contract, it stops and returns a design finding instead of adding a
second close owner in the app target.

Expected tests:

- focused store cancellation/close state tests
- AppServer interrupt ordering and process transport close tests
- Host runtime start/restart/stop reentrancy tests
- MCP admitted-handler drain tests
- ReviewUI close-and-await tests
- ReviewMonitor termination decision tests
- existing external consumer/API/MCP golden gates

Do not modify GRDB/history/schema/migrations, auth provider/wire semantics, executable
resolution, sidebar duration/paging/order, legacy import, workflows, or the MCP
tool names/input schemas. Do not close #106 in this wave.

Account switch/removal/sign-out lifecycle ordering is in scope: the review
barrier must finish before shared credential/runtime state changes. The login
provider, credential format, and account wire protocol remain Wave 5 scope.

## Characterization-first checkpoints

Before production edits, replace timing assumptions with controlled gates and
prove these current failures:

1. interrupt ACK arrives before terminal and current code completes early;
2. terminal arrives before ACK;
3. interrupt request is explicitly rejected;
4. request transport outcome is unknown, then terminal or connection loss
   resolves it;
5. stop timeout currently returns with an unfinished worker;
6. start/restart completion publishes after close begins;
7. concurrent close callers currently execute shutdown more than once;
8. application termination cannot report a close failure.

Then commit green checkpoints:

1. attempt interrupt reducer and AppServer ACK/terminal separation;
2. store cancellation waits the worker-owned terminal;
3. freeze and branch-review Wave 3A;
4. runtime generation and single close Task on reviewed 3A;
5. awaited transport/process/router/worker/MCP cleanup;
6. freeze and branch-review Wave 3B;
7. ReviewUI close and application termination decision on reviewed 3B;
8. freeze and branch-review Wave 3C;
9. review-finding fixes.

## Required test matrix

- ACK→terminal and terminal→ACK ordering;
- explicit rejection before/after terminal;
- outcome-unknown request followed by terminal, connection close, and forced
  close;
- duplicate cancellation callers issue one request and receive one result;
- child/stale/cross-turn terminal cannot satisfy cancellation;
- cancellation before thread dispatch, after outcome-unknown thread dispatch,
  after thread response but before review dispatch, and after outcome-unknown
  review dispatch;
- queued, starting, active, waiting-for-connectivity, recovering, and already
  terminal review cancellation;
- user, MCP, session-close, runtime-stop, restart, account-transition, network,
  and application-termination trigger policy;
- terminal grace expiry triggers force-close and then awaits real completion;
- force-close failure remains typed and workers are not detached;
- concurrent/repeated close returns the same success/error;
- close racing start/restart prevents stale publication and closes acquired
  resources exactly once;
- stop during close joins; start/restart after close are no-ops;
- no callback, event, process, request, or observation after close completion;
- UI render Task is cancelled and awaited before store close;
- Cancel Quit replies `false`; Quit Anyway replies `true`; success replies
  `true`; repeated requests do not duplicate shutdown;
- compatibility script, full package suite, ReviewMonitor app tests.

Use continuations, AsyncStream gates, an injected close policy, and owned Task
handles. Tests must not use request counts, wall-clock sleeps, or a timeout as
proof that work completed.

## Validation and delivery

Run at each green checkpoint:

- focused AppServer/store/Host/MCP/UI lifecycle tests;
- `scripts/check-compatibility.sh`.

Final gates:

- `swift test --build-system swiftbuild --no-parallel`
- `xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj -scheme CodexReviewMonitor -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
- branch-wide Codex review against the exact worker base.

Run the applicable full gates and a branch-wide review at the end of each of
3A, 3B, and 3C before the next stacked slice is dispatched; a later slice never
serves as validation for an earlier one.

Each worker commits only to its task branch, leaves a clean worktree, and does
not push, create a PR, tag, or close #106. Three failed fixes in one lifecycle
class, a second close owner, unowned cleanup Task, timeout detachment, or any
need to change the approved public API is a stop condition.
