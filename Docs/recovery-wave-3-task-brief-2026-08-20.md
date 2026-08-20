# Recovery Wave 3 task brief (2026-08-20)

Status: **No Wave 3 landing/successor is authorized.** Historical Wave 3A
code/test evidence exists at `202ca65ce171`, but that branch descends from the
rejected path-owned Wave 0 ancestry. It must be replayed onto the independently
landed/reviewed current-event HEAD and reviewed there. Wave 3B/3C remain gated
on each reviewed predecessor landing SHA.

| Item | Value |
|---|---|
| Integration branch | `codex/v0-6-2-recovery` |
| Required Wave 3 base | Independently landed and reviewed current-event (#104/#105) HEAD; record before dispatch |
| Historical Wave 3A base | `287795d587823335e160d5e682407539c28a11af` |
| Wave 3A evidence | `codex/recovery-wave-3a@202ca65ce171`; code/tests only, ancestry rejected, never a predecessor SHA |
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

The historical Wave 3A branch is implementation evidence only. Its base ancestry
includes former Wave 0 (`9e5bf73`, `a58daeb`, `59caa59`) plus combined historical
baseline commits, so even a later exact-base review of `202ca65` cannot make it a
valid landing. After Gate C and the current-event contract independently land and
are reviewed, create a successor task branch from that exact HEAD, reapply only
the intended Wave 3A diff without rewriting the historical branch, run all gates,
and complete an exact-base review. Only that successor result can precede 3B. A
later slice or aggregate test/review never back-validates an earlier gate.

## Outcome

- A successful `turn/interrupt` response records request acceptance only.
- The matching canonical `(reviewThreadID, turnID)` `turn/completed`, or a typed
  connection/process terminal after force-close, is the completion barrier.
- The admission installs the joined recovery/cancellation disposition before
  backend token creation; a product-terminal disposition cannot be tokenized.
- Store attempt ownership is one coherent state. No suspension exposes an old
  run paired with a fresh admission.
- Registered start Tasks are backend-inert until the Store publishes their
  ownership state and explicitly activates the exact handle.
- Mailbox and worker failure delivery preserve typed origin/recoverability; no
  protocol, process, or connection case is reduced to a string.
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
- `AppServerCodexReviewBackend.beginReviewRecovery` currently treats interrupt
  ACK as recovery completion, marks the turn/attempt abandoned, and unregisters
  the event session before a canonical/connection terminal can arrive.
- the Store clears and cancels the active event subscription before invoking
  recovery, removing the input that must satisfy the old attempt barrier.
- recovery currently records a recovered run on the predecessor's admission;
  one terminal attempt owner is thereby reused for a different attempt ID.
- a generic recovery barrier can be handed to backend token creation before the
  admission has installed the joined explicit-cancellation disposition;
  outcome-unknown plus connection loss can then be relabeled requested cancel.
- replacement startup mutates the admission map before rollback/`review/start`
  returns while the run map still contains the old attempt.
- `ReviewStartAdmission.start` resets its phase to thread preparation even when
  cancellation/terminal was already recorded before the worker registered start.
- `registerStart` returns a live Task with no activation barrier, so backend
  dispatch may race ahead of Store publication of the registered handle.
- mailbox failure stores only display text, erasing whether the source was a
  verified network outage, unexpected connection loss, process exit, or
  protocol violation; downstream code can therefore recover every case.
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
  -> registeredStart(handleID, activation: pending)
  -> activatedStart(handleID)
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
       purpose: terminalCancellation(requestedBy) | recoverableTransition(trigger),
       requestTask,
       terminalBarrierTask,
       graceTask,
       forceCloseTask?
     )
  -> resolving(terminal, requestOutcome, joinedPurpose)
  -> disposition(productTerminal | replacementCandidate)
  -> finishing(disposition, requestTask?, graceTask?, forceCloseTask?)
  -> terminal(ReviewResolvedAttemptTerminal)
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

Use one store-created `ReviewStartAdmission` actor per attempt plus the
registered start Task. The backend must atomically ask that admission
immediately before both the `thread/start` and `review/start` writes. A pre-recorded cancellation
refuses the relevant write and proves `.notSent`; admission of either write
irreversibly records that stage as `.outcomeUnknown` until response/connection
resolution.
Store cancellation and backend dispatch consult this same value—there is no duplicated
`startingJobIDs`/`startupCancellations` truth. The backend returns an immutable
attempt value and never publishes directly into the store.

The same admission owns both terminal cancellation and recoverable interruption.
`AppServerCodexReviewBackend.interruptReview` is request-scoped and returns after
ACK (or throws typed rejection/outcome-unknown); it never waits for the event
stream barrier and never finishes, abandons, unregisters, or cleans up the
session. Remove the backend-owned `beginReviewRecovery` lifecycle shortcut.
The Store asks the current admission to begin a recoverable transition, and the
admission runs the ACK-only backend operation while it waits independently for
the canonical/connection terminal. Thus request completion and semantic
completion have exactly one owner each and cannot wait on each other twice.
The backend cannot accept a generic barrier or create a token at this point.
After all independently ordered inputs and any joined explicit cancellation are
linearized, the admission installs one `ReviewRecoveryDisposition`. Only its
replacement candidate may pass through Store finish and then to backend recovery
preparation/token creation.

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
- cancellation received while the old attempt's recovery barrier is still
  active joins that admission's one request/barrier Task, issues no second
  interrupt, and suppresses any replacement after the barrier;
- the admission installs a product-terminal or replacement disposition before
  any token request. A product-terminal result is not convertible to a token;
- outcome-unknown request plus connection terminal retains the typed transport
  terminal and original request failure. If explicit cancellation joined, it
  suppresses replacement but the product-terminal disposition explicitly stores
  transport failure, never fabricated `.requested`;
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

For recovery, a canonical `completed` or `failed` terminal is a natural product
terminal and produces a product-terminal disposition. A canonical `interrupted`
terminal, or a typed connection terminal that the trigger policy classifies as
recoverable, closes the old attempt and produces a replacement candidate with no
token while the product remains nonterminal. A nonrecoverable connection/
process/protocol terminal produces a product-terminal disposition. If explicit
cancellation joined the recovery first, a natural completed/failed terminal
still wins; otherwise
an acknowledged recovery interrupt followed by the interrupted/connection
barrier commits requested product cancellation and suppresses replacement. If
the recovery request remained outcome-unknown and only connection loss
satisfied the barrier, retain the typed transport outcome and original request
failure rather than fabricating requested cancellation; replacement is still
suppressed.

The Store must keep the old `activeEventSubscriptionID`, mailbox consumer, and
AppServer session registered until this classification and all owned request/
force-close Tasks have joined and the admission has installed the disposition.
Only then may the Store cancel/detach its subscription and pass that whole value
through its single finish owner. The replacement finish branch records the old
attempt while keeping the product nonterminal; the product-terminal branch
finishes both and returns no candidate. For the former only,
`prepareReviewRecovery` then finishes/unregisters the backend session and creates
one candidate-plus-token handoff. Neither candidate nor token is stored alone.
ACK alone never marks a turn/attempt abandoned.
Recoverable teardown preserves the source thread and does not invoke destructive
review cleanup.

`resumeReviewRecovery` always receives one waiting handoff and a newly
constructed `ReviewStartAdmission` for the candidate attempt and consults that
admission before the replacement `review/start` write. The predecessor admission
remains terminal and immutable; `recordActiveRun` is never called on it. Store
attempt ownership moves to `replacementStart(handoff, registeredStart)`
before rollback starts; that state has no active run. Only a successful response
atomically publishes `active(run, admission)`. Cancellation before the
replacement write routes to this fresh admission and is therefore a `.notSent`
decision, not state inherited from or accidentally paired with the old attempt.

`BackendReviewEventMailbox` and the Store input queue carry
`ReviewAttemptStreamFailure`, never `.failed(String)` or an arbitrary `Error`
whose only retained field is `localizedDescription`. The transport/router maps
external failure once into verified recoverable network, owner-forced connection
close, unexpected connection loss, process exit, protocol/routing violation, or
owner Task cancellation. Only verified network, or owner-forced close belonging
to the already-admitted recoverable transition, can yield a replacement
candidate. Unexpected connection, process, protocol/routing, and unknown failure
are typed nonrecoverable product-terminal inputs. UI/log formatting happens
after this exhaustive Store switch.

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
sequence. Natural completion, requested interruption, connection terminal,
ingestion failure, and recovery disposition all call the same awaited finish
owner. The recovery entry receives the whole `ReviewRecoveryDisposition` so it
can distinguish attempt-only replacement from product terminal without
reconstructing policy. In Wave 3 its body performs the in-memory mutation before
projection/waiter publication; Wave 4 replaces that body with the durable
history commit. Cleanup is invoked only from the returned finish result.

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
must not run destructive thread cleanup. They keep the old event session and
Store subscription alive through the attempt barrier, detach them only after
that barrier and their owned Tasks join, close the old runtime, and move
directly to `recovering` when the replacement runtime is authoritative; they do
not wait for a network-monitor edge. Exactly
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

package enum ReviewAttemptRecoveryTrigger: Sendable {
    case sameAccountRestart
    case recoverableNetworkLoss
}

package enum ReviewAttemptInterruptionPurpose: Sendable {
    case terminalCancellation(ReviewCancellation)
    case recoverableTransition(ReviewAttemptRecoveryTrigger)
}

package enum ReviewAttemptBarrierTerminal: Sendable {
    case canonical(ReviewTerminalRecord)
    case stream(ReviewAttemptStreamFailure)
    case localCancellation(ReviewCancellation)
}

package struct ReviewResolvedAttemptTerminal: Sendable {
    package let run: CodexReviewBackendModel.Review.Run
    package let terminal: ReviewAttemptBarrierTerminal
    package let requestFailure: ReviewInterruptRequestFailure?

    // Constructed only by ReviewStartAdmission after joined disposition.
    fileprivate init(
        run: CodexReviewBackendModel.Review.Run,
        terminal: ReviewAttemptBarrierTerminal,
        requestFailure: ReviewInterruptRequestFailure?
    )
}

package struct ReviewRecoveryCandidate: Sendable {
    package let resolved: ReviewResolvedAttemptTerminal
    package let trigger: ReviewAttemptRecoveryTrigger

    // Constructed only for a replacement disposition, never a generic barrier.
    fileprivate init(
        resolved: ReviewResolvedAttemptTerminal,
        trigger: ReviewAttemptRecoveryTrigger
    )
}

package struct ReviewProductTerminalDisposition: Sendable {
    package let resolved: ReviewResolvedAttemptTerminal
    package let productTerminal: ReviewTerminalRecord

    // Constructed only by ReviewStartAdmission after joined disposition.
    fileprivate init(
        resolved: ReviewResolvedAttemptTerminal,
        productTerminal: ReviewTerminalRecord
    )
}

package enum ReviewRecoveryDisposition: Sendable {
    case productTerminal(ReviewProductTerminalDisposition)
    case replacement(ReviewRecoveryCandidate)
}

package struct ReviewRecoveryHandoff: Sendable {
    package let candidate: ReviewRecoveryCandidate
    package let token: CodexReviewBackendModel.Review.RecoveryToken

    package init(
        candidate: ReviewRecoveryCandidate,
        token: CodexReviewBackendModel.Review.RecoveryToken
    )
}

package struct ReviewAttemptContractFailure: LocalizedError, Sendable {
    package let message: String
}

package enum ReviewAttemptStreamFailure: LocalizedError, Sendable {
    case recoverableNetwork(ReviewRuntimeCloseFailure)
    case ownerForcedConnectionClose(ReviewRuntimeCloseFailure)
    case unexpectedConnection(ReviewRuntimeCloseFailure)
    case process(ReviewRuntimeCloseFailure)
    case protocolViolation(ReviewAttemptContractFailure)
    case workerContract(ReviewAttemptContractFailure)
    case ownerCancellation
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

package struct ReviewActiveAttempt: Sendable {
    package let run: CodexReviewBackendModel.Review.Run
    package let admission: ReviewStartAdmission
}

package struct ReviewStartHandleID: Hashable, Sendable {
    fileprivate let generation: UInt64
}

package struct ReviewRegisteredStart: Sendable {
    package let id: ReviewStartHandleID
    package let admission: ReviewStartAdmission
    package let task: Task<BackendReviewAttempt, any Error>
}

package enum ReviewAttemptOwnership: Sendable {
    case initialStart(ReviewRegisteredStart)
    case active(ReviewActiveAttempt)
    case resolvingRecovery(ReviewActiveAttempt)
    case recoveryDisposition(ReviewRecoveryDisposition)
    case preparingRecovery(
        candidate: ReviewRecoveryCandidate,
        preparationTask: Task<ReviewRecoveryHandoff, any Error>
    )
    case waitingForRecovery(ReviewRecoveryHandoff)
    case replacementStart(
        handoff: ReviewRecoveryHandoff,
        start: ReviewRegisteredStart
    )
    case terminal
}

package actor BackendReviewEventMailbox {
    package func fail(_ failure: ReviewAttemptStreamFailure)
}

package actor ReviewStartAdmission {
    package func registerStart(
        _ operation: @escaping @Sendable (
            ReviewStartAdmission
        ) async throws -> BackendReviewAttempt
    ) throws -> ReviewRegisteredStart

    package func activateStart(_ id: ReviewStartHandleID) throws

    // Existing terminal cancellation joins this operation if recovery is
    // already waiting; it never installs a second request/barrier pair.
    package func beginRecovery(
        trigger: ReviewAttemptRecoveryTrigger,
        interrupt: @escaping @Sendable (
            CodexReviewBackendModel.Review.Run,
            CodexReviewBackendModel.CancellationReason
        ) async throws -> Void,
        forceClose: @escaping @Sendable () async throws -> Void
    ) async throws -> ReviewRecoveryDisposition
}

package protocol CodexReviewBackend: Sendable {
    func startReview(
        _ request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt

    // Resolves only the turn/interrupt request response. The attempt admission
    // owns and awaits the independent semantic terminal barrier.
    func interruptReview(
        _ run: CodexReviewBackendModel.Review.Run,
        reason: CodexReviewBackendModel.CancellationReason
    ) async throws

    func prepareReviewRecovery(
        _ candidate: ReviewRecoveryCandidate
    ) async throws -> ReviewRecoveryHandoff

    func resumeReviewRecovery(
        _ handoff: ReviewRecoveryHandoff,
        request: CodexReviewBackendModel.Review.Start,
        admission: ReviewStartAdmission
    ) async throws -> BackendReviewAttempt
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

`ReviewAttemptOwnership` is the value of the Store's sole per-review attempt
registry. Do not retain parallel `activeRuns`, admission, recovery-token, or
replacement-start maps. Every command switches on this enum, captures the exact
associated values it needs before an `await`, and revalidates the same case after
suspension. Cancellation in `resolvingRecovery` joins the old admission;
cancellation in `recoveryDisposition` prevents preparation; cancellation in
`preparingRecovery` joins its Task and discards the handoff; cancellation in
`waitingForRecovery` consumes no token and prevents resume. In particular,
`replacementStart` is installed with its registered start handle before rollback
or `review/start`; it contains no active run. `registerStart` records a Task that
is suspended on admission-owned activation state. The Store makes the whole
handle command-visible, then calls `activateStart(handle.id)`; only that exact
transition lets the Task reach backend code. Detached work is not used.
Success replaces the whole value with `active(ReviewActiveAttempt)` in one
mutation.

`registerStart`/start entry never assigns a preparing phase unconditionally. If
the admission already contains a terminal or cancellation, it preserves that
fact, returns its typed completion/cancellation, and the operation performs zero
backend writes. Cancellation/terminal after registration but before activation
resolves the pending gate and Task with the same typed outcome. Activation that
wins first is recorded even if the Task has not reached its wait yet; a stale or
wrong ID is a typed contract failure, and duplicate activation for the same live
handle is idempotent. Store close/cancel resolves pending activation and awaits
the registered Task. Task scheduling is not completion or ordering proof.

The only recovery chain is
`active(old) -> resolvingRecovery(old) -> recoveryDisposition ->
preparingRecovery -> waitingForRecovery -> replacementStart -> active(new)`.
Cases after `resolvingRecovery` carry the resolved old attempt as disposition or
handoff data, never as a currently active run.

Only `ReviewStartAdmission` constructs `ReviewResolvedAttemptTerminal`,
`ReviewProductTerminalDisposition`, and `ReviewRecoveryCandidate`.
`prepareReviewRecovery` accepts only the latter and
is called after the Store finish owner returns it; therefore a generic barrier or
product-terminal result cannot reach token creation. The returned handoff
retains the candidate alongside the token through waiting and resume.

`ReviewAttemptStreamFailure` is the mailbox/worker terminal payload. Production
mailboxes expose only the typed `fail` entry point above; `fail(any Error)`,
`.failed(String)`, and recovery decisions based on `localizedDescription` are
removed. Mapping from external errors into this closed union belongs to the
transport/router boundary.

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
- `Sources/CodexReview/Store/CodexReviewStoreTesting.swift`, limited to
  cancelling/awaiting workers and activation/admission work before clearing the
  new sole attempt registry
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

Matching test-only compile seam:

- `Tests/ReviewUITests/ReviewUITests.swift`, limited to the fixture/test-double
  seam required to compile and exercise the new internal registry/backend
  contract; no `Sources/ReviewUI` production behavior is in Wave 3A

Wave 3A propagates the reviewed throwing transport/client close and throwing
`cleanupReview` signatures through StoreBackend, preview/testing conformances,
and the minimum Host call sites so the slice compiles and is independently
green. Unsubscribe/delete/background-terminal cleanup rejection is typed as
`ReviewRuntimeCloseFailure.cleanup`; no `try?` cleanup remains on the review
barrier. Wave 3A does not implement public store close, Host runtime replacement,
MCP drain, or ReviewUI.

The Wave 3A implementation of
`cancelAndDetachReviewWorkersForRuntimeStop(jobIDs:)` may move the worker Task to
the existing detached-task registry, but it must retain the corresponding
`ReviewAttemptOwnership`. The detached worker first resolves any pending start
activation to cancellation/terminal without releasing backend dispatch, awaits
admission/start/cleanup completion, then removes only the same ownership
generation on the Store actor. `CodexReviewStoreTesting` follows
the same order: cancel, await all live/detached workers and activation/admission
work, then clear the sole registry. Clearing ownership at detach time would make
cancel/close unable to reach the operation that still owns backend-write
authority.

This detachment is a Wave 3A compatibility boundary only. Wave 3B replaces it
with the recorded runtime/store close Task and removes timeout detachment as an
owner; do not grow a second lifecycle around the temporary dictionary.

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
- recovery subscription/session barrier and fresh-attempt admission tests
- recovery-disposition/token linearization and coherent attempt-ownership tests
- typed mailbox failure round-trip and recoverability classification tests
- initial/replacement registered-start activation-gate tests
- detached-worker ownership retention and testing-cleanup ordering tests
- Host runtime start/restart/stop reentrancy tests
- MCP admitted-handler drain tests
- ReviewUI close-and-await tests
- ReviewMonitor termination decision tests
- existing external consumer/API/MCP golden gates

Do not modify GRDB/history/schema/migrations, descriptor capability/environment
preparation, login staging/RegistryV2/pending/debt, auth provider/wire semantics,
executable resolution, sidebar duration/paging/order, legacy import, workflows,
or the MCP tool names/input schemas. Do not close #106 in this wave.

Account switch/removal/sign-out lifecycle ordering is in scope: the review
barrier must finish before shared credential/runtime state changes. The login
provider, credential format, and account wire protocol remain Wave 5 scope.

## Downstream capability and lease prerequisites

Wave 3 produces lifecycle authority consumed by later filesystem/auth owners;
it does not implement those owners itself.

1. Reviewed Wave 3C is the prerequisite for issue #113. The descriptor
   capability core consumes the throwing process/runtime close contract and the
   joined generation owner before it replaces path-owned RecoveryV1 setup.
2. Issue #113 then produces one `PreparedRecoveryEnvironment` and opaque
   `DirectoryCapability` values. No Wave 4 GRDB path may open before that gate is
   independently reviewed.
3. Wave 5 `LoginStagingLease` consumes both reviewed Wave 3 close authority and
   reviewed #113 descriptor authority. The lease, not Wave 3 and not
   `RecoveryEnvironmentPlan`, owns staging runtime/client/writer completion and
   one joined close result.
4. RegistryV2's authentication disk actor owns the versioned pending/cleanup-
   debt manifest and startup reconciliation. Wave 3 must not add a bare staging
   URL, cleanup manifest, log-only cleanup error, or Environment-owned removal
   helper as a convenience for Wave 5.

Any need to change Wave 3's close result so that #113 or Wave 5 can consume it is
a Wave 3 design finding and must be resolved before its reviewed landing. Later
gates must not wrap or bypass an inadequate close owner.

## Characterization-first checkpoints

Before production edits, replace timing assumptions with controlled gates and
prove these current failures:

1. interrupt ACK arrives before terminal and current code completes early;
2. terminal arrives before ACK;
3. interrupt request is explicitly rejected;
4. request transport outcome is unknown, then terminal or connection loss
   resolves it;
5. recovery ACK currently unregisters/abandons the event session before terminal;
6. Store recovery currently cancels its terminal-producing subscription first;
7. a recovered run currently reuses the predecessor admission;
8. stop timeout currently returns with an unfinished worker;
9. start/restart completion publishes after close begins;
10. concurrent close callers currently execute shutdown more than once;
11. application termination cannot report a close failure;
12. generic recovery barrier reaches token creation before a concurrently joined
    explicit-cancellation disposition is installed;
13. rollback/replacement start exposes the old active run with the fresh
    admission in separate Store maps;
14. mailbox failure round-trip erases protocol/process/connection identity to a
    string and admits nonrecoverable failures to network recovery;
15. cancellation/terminal recorded before start registration is overwritten by
    unconditional transition to thread preparation;
16. a Task returned by start registration can reach backend dispatch before its
    handle is published in Store attempt ownership;
17. runtime-stop detachment removes attempt state while the detached worker still
    owns activation/admission/backend-write authority.

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
- recovery ACK before/after terminal keeps the old subscription/session alive
  until canonical/connection barrier completion;
- canonical completed/failed during recovery suppresses replacement; canonical
  interrupted and policy-recoverable connection terminal create exactly one
  replacement candidate; nonrecoverable terminal creates none;
- cancellation during recovery joins the same request/barrier with one interrupt
  and prevents replacement;
- cancellation admitted before disposition prevents backend token creation;
  cancellation racing outcome-unknown plus connection preserves the transport
  attempt terminal/request diagnostic and stores an explicit transport product
  terminal, never `.requested`;
- cancellation after replacement disposition, during preparation, and while
  waiting suppresses resume, joins owned preparation work, and never exposes a
  bare token or starts a candidate attempt;
- backend recovery preparation receives only a replacement candidate and returns
  one candidate-plus-token handoff after the Store finish insertion point;
- replacement uses a fresh admission/attempt ID, and cancellation before its
  `review/start` dispatch is proven `.notSent` without mutating the predecessor;
- controlled rollback and pre-`review/start` gates observe one
  `replacementStart` state, never old run plus fresh admission; success publishes
  the new pair atomically and every failure cleans up from associated values;
- cancel/connection terminal before initial and replacement start registration
  survives `registerStart`, performs zero `thread/start`/`review/start` writes,
  and returns the recorded typed outcome;
- controlled activation gate proves a registered Task performs no backend write
  before `ReviewAttemptOwnership` publication plus `activateStart(handle.id)`;
  cancel/terminal in that window resolves both activation and Task with the same
  typed zero-write outcome;
- activation-before-Task-wait proceeds once, duplicate same-handle activation is
  idempotent, and stale/wrong-handle activation is a typed contract failure;
- close/cancel with an unactivated registered start resolves its gate and joins
  the Task without backend writes or leaked continuation;
- runtime-stop detach retains the exact `ReviewAttemptOwnership` until the
  detached worker resolves activation/admission and removes that generation;
  testing cleanup cancels and awaits live/detached workers before registry clear;
- mailbox-to-Store round-trip preserves every `ReviewAttemptStreamFailure` case
  and payload; verified network/owned recoverable close may resume, while
  unexpected connection, process, protocol, and unknown failures never do;
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

After reviewed 3C, dispatch #113. Do not dispatch Wave 4 or Wave 5 directly from
a Wave 3 code/test checkpoint: the reviewed descriptor-capability result is an
additional mandatory predecessor.

Each worker commits only to its task branch, leaves a clean worktree, and does
not push, create a PR, tag, or close #106. Three failed fixes in one lifecycle
class, a second close owner, unowned cleanup Task, timeout detachment, or any
need to change the approved public API is a stop condition.
