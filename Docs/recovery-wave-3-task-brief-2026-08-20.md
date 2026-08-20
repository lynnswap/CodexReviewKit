# Recovery Wave 3 task brief (2026-08-20)

Status: **No Wave 3 landing/successor is authorized.** Historical Wave 3A
code/test evidence exists at `202ca65ce171`, but that branch descends from the
rejected path-owned Wave 0 ancestry. It must be replayed onto the independently
landed/reviewed current-event HEAD. Wave 3A remains an exact-base implementation
and review checkpoint, but PR #117 demonstrated that it is not independently
mergeable: Wave 3A and Wave 3B now form one combined merge gate. Wave 3C starts
only from the reviewed combined Wave 3A+B HEAD.

| Item | Value |
|---|---|
| Integration branch | `codex/v0-6-2-recovery` |
| Required Wave 3 base | Independently landed and reviewed current-event (#104/#105) HEAD; record before dispatch |
| Historical Wave 3A base | `287795d587823335e160d5e682407539c28a11af` |
| Wave 3A evidence | `codex/recovery-wave-3a@202ca65ce171`; code/tests only, ancestry rejected, never a predecessor SHA |
| Wave 3B checkpoint base | Exact-base reviewed Wave 3A checkpoint; record before dispatch, but do not merge 3A alone |
| Wave 3A+B merge gate | Review the combined exact-base diff and land only after both 3A and 3B gates are green |
| Wave 3C base | Reviewed combined Wave 3A+B HEAD; record before dispatch |
| Approved design | `Docs/recovery-design-2026-08-20.md` |
| Issue | #106 cancellation terminal barrier |
| Motivating review evidence | PR #117 P1 at `d90be363162692ca34b55cd9c2da77109ec852cf` |
| Upstream contract | `openai/codex@3b45c29062ff0e76e71c91b6753290400e7fa8da` |
| Budget | 48 hours total: 3A at most 17 production + 10 test/gate files; 3B only the exact 12 production + 10 test/gate paths below; 3C at most 12 production + 7 test/gate files |

Wave 3 replaces acknowledgement-as-completion, timeout detachment, and
caller-owned shutdown with one attempt cancellation processor and one
application-lifetime close authority. Work proceeds through three sequential
owner slices: **3A** implements attempt cancellation and the AppServer
interrupt/transport barrier; **3B** starts from the exact-base reviewed 3A
checkpoint and implements Store runtime-generation, Host/MCP, and public Store
close; the combined **3A+B** diff is the only merge gate; **3C** starts from that
reviewed combined HEAD and connects ReviewUI/application termination to the
close. It remains an in-memory wave: Wave 4 inserts durable commits and
database/query close stages into the same owner. Issue #106 therefore remains
open until Wave 4 proves commit-before-cleanup.

The historical Wave 3A branch is implementation evidence only. Its base ancestry
includes former Wave 0 (`9e5bf73`, `a58daeb`, `59caa59`) plus combined historical
baseline commits, so even a later exact-base review of `202ca65` cannot make it a
valid landing. After Gate C and the current-event contract independently land and
are reviewed, create a successor task branch from that exact HEAD, reapply only
the intended Wave 3A diff without rewriting the historical branch, run all gates,
and complete an exact-base checkpoint review. Wave 3B starts only from that exact
checkpoint, then the combined 3A+B diff receives its own exact-base merge review.
A later slice or aggregate test/review never back-validates an earlier checkpoint.

PR #117 supplies the concrete reason for the combined gate. Its P1 trace proves
that an attempt-owned grace force-close calls the Store's runtime-unidentified
`forceCloseReviewConnection()`, closes the one `AppServerClient` shared by all
review sessions, terminalizes unrelated siblings through the notification
router, and then attempts recovery on that already permanently closed client.
The Host has a factory for a new client/backend, but the reviewed 3A shape has no
runtime-generation owner to create exactly one replacement and recover all
eligible siblings. An attempt-local guard, retry, or sibling exception cannot
make that shared-resource transition safe; the Store/Host runtime owner defined
by Wave 3B is required before any 3A code can merge.

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
- Force-close of the shared AppServer connection is one runtime-generation
  transition. The requested attempt reaches its requested terminal, every
  otherwise healthy sibling in that generation is admitted to recovery once,
  and one replacement backend/client resumes them; no sibling resumes on the
  closed backend.
- Runtime preparation is inert. Only the Store revalidates the captured
  generation, activates the exact prepared handle, and atomically publishes its
  snapshot. MCP network admission closes before handler drain, and every
  already-admitted handler is owned through completion.
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
- PR #117's attempt-local force-close closes the single AppServer connection
  shared by sibling reviews, terminalizes those siblings, and asks the same
  permanently closed client to resume the target; no runtime-generation owner
  creates one replacement backend/client for the whole affected generation.
- backend cleanup deletes/unsubscribes review threads before terminal and
  reader/router/worker completion are proven.
- `stop()` and `restart()` can interleave across `await`, allowing a stale start
  completion to publish after shutdown began.
- Host startup can finish after Store stop/close, directly install its stale
  client/backend, and publish `.running` because preparation, activation, and
  publication are not split at a generation revalidation boundary.
- MCP stop closes listener/session resources without owning and awaiting the
  handlers already admitted from that listener; rate-limit refresh similarly
  treats Task cancellation as completion without joining the Task.
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

Here, “replacement” means this product review's next attempt/candidate. It does
not suppress the independent one-per-generation AppServer runtime replacement
after a shared old-runtime close signal has actually been sent.

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
open(
  appServerGeneration,
  appServer: stopped
    | acquiring(ownedTask)
    | running(preparedRuntime)
    | transitioning(purpose, ownedTask, forcedSiblingAttemptIDs)
    | failed(ReviewRuntimeCloseFailureAggregate, admission: closed),
  mcpServerOwner: one stable app-lifetime owner identity
)
  -> closing(invalidatedAppServerGeneration, closeTask)
  -> closed(Result<Void, ReviewCloseError>)
```

The Host-owned MCP owner has its own non-mirrored state:

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

One owner identity spans the Store lifetime, but each `stop()`/later `start()`
uses a new sequential listener lease (or explicit no-MCP generation) and MCP
generation. There is never more than one preparing/running/stopping lease. The
Store does not mirror this state; its one runtime transition Task invokes the
opaque owner and publishes only the
post-activation, generation-revalidated server URL.

The first `close()` installs `closing`, invalidates the runtime generation, and
closes mutation admission before its first suspension. Concurrent/repeated
`close()` calls await the same Task and return/throw the same recorded value.
`stop()` during close joins the runtime-stop stage; after closed it is a no-op.
Public `start()` and `restart()` keep their released nonthrowing signatures and
are no-ops once closing begins.

Every start/restart operation captures the open generation before external
awaits and revalidates it afterward. A late stale completion cannot publish
an MCP server URL or AppServer auth/settings/observation state. Any resource it
acquired is handed to the installed close Task and awaited there; it is never
abandoned or closed by an unowned Task.

The store registers each runtime acquisition operation, with its owned Task,
before that operation's first external await. Closing first rejects new
registrations, invalidates the generation, and then awaits the finite registered
set. A stale operation closes and awaits any resource it acquired before its
registered Task completes. The close Task awaits that completion before passing
the runtime-close stage; it never takes a one-time snapshot that a late
completion can miss.

Backend runtime startup no longer mutates `CodexReviewStore` during its own
awaits. `CodexReviewStoreBackend.prepareRuntime(generation:purpose:)` is the
single live/preview/test AppServer construction seam and returns an inert
`PreparedRuntime(snapshot:handle:)`. `PreparedRuntime` contains only the
replaceable AppServer generation's auth/settings snapshot and
`RuntimeLifecycleHandle`; it never owns, retains, prepares, activates, closes,
or republishes an MCP listener or server URL. The separate
`CodexReviewStoreBackend.mcpServerLifecycle` is one Host-owned app-lifetime
`MCPServerLifecycleOwner`.

The ownership split is exact:

- the Store close Task owns and awaits its runtime transition/acquisition Tasks,
  review workers and admissions, the rate-limit driver and in-flight refresh,
  and Store attempt/cleanup Tasks;
- one replaceable `RuntimeLifecycleHandle` owns only its Host auth observation,
  transport reader, notification router, backend event sessions, client, and
  process; and
- `MCPServerLifecycleOwner` owns only MCP generation/lease state, listener,
  protocol sessions, network admission, and the admitted-handler registry.

No lifecycle handle owns a Store worker/rate-limit/cleanup Task, and no
`PreparedRuntime` or AppServer handle can reach the MCP listener.

Only the Store may:

1. register the acquisition Task before its first external await;
2. revalidate the exact captured generation after preparation;
3. call `activate()` on that exact handle;
4. revalidate the same generation again; and
5. atomically retain the handle and publish its auth/settings snapshot.

Neither preparation nor activation publishes Store state. If either
revalidation fails, the Store closes admission on that exact handle, calls
`close(purpose:)`, records any signal error, always awaits the throwing
`waitUntilClosed()` as an idempotent proof of that same recorded completion,
and never publishes its snapshot. Initial `start()` and
`start()` after `stop()` also ask the stable MCP owner to prepare one inert MCP
generation. Only after exact generation revalidation and AppServer publication
does the Store activate that exact MCP generation. Binding completes inside
`activate`, which returns `MCPServerPublicationSnapshot` with the actual bound
URL. A Live owner must return non-`nil`; an explicit no-MCP Direct/Preview/
Testing owner returns `nil` and never fabricates a placeholder URL. The Store
revalidates that same MCP generation after the await and only then publishes the
returned optional value; `prepare()` has no publication snapshot, so a port-0
configuration can never publish port 0. Stale MCP preparation/activation is
stopped/awaited by the same owner and never published.
No Host/AppServer/MCP concrete type enters `CodexReview`, so dependency direction
remains intact. `close()` does not call public `stop()`; both delegate to one
internal transition owner with an explicit purpose. `restart()` is one recorded
transition Task rather than `await stop(); await start()`.

`restartSameAccount` and `recoveryReplacement` retain the running MCP generation
and listener without closing network admission or preparing another lease.
Runtime-disable `stop()` closes MCP network admission, drains admitted handlers,
physically stops and awaits that lease, and leaves the app-lifetime MCP owner in
`stopped`. A later released `start()` prepares/activates a new MCP generation
through the same owner. Application `close()` transitions the owner to terminal
`closed`; no later prepare/activate is permitted.

Wave 3 normal-terminal close order is exact:

1. before the first suspension, install Store `closing` and synchronously close
   Store mutation/review/runtime admission; then close AppServer generation
   admission and ask the MCP owner to close listener/network admission as its
   first mutation before any handler-drain await;
2. request active review cancellation according to the trigger policy;
3. await canonical attempt/connection terminal;
4. publish the in-memory terminal and finish admitted review/MCP waiters;
5. ask the MCP owner to drain every already-admitted handler in registration
   order, send all listener/session close signals, and then await physical MCP
   completion; signal/drain/wait failures are recorded without skipping a later
   stage;
6. the Store close Task cancels and awaits every Store-owned runtime transition/
   acquisition, review worker/admission, rate-limit driver/in-flight refresh,
   and Store attempt/cleanup Task;
7. only after Store cleanup, call the throwing AppServer
   `RuntimeLifecycleHandle.close(purpose:)`; its one recorded Task issues the
   client/process close signal before any Host completion wait. The method may
   then join physical client/process/reader plus Host auth/router/event-session
   completion before returning or throwing, matching the existing AppServer
   client/transport contract;
8. regardless of step 7 success, call the throwing `waitUntilClosed()` to join
   that exact recorded close Task/result and prove Host auth observation, reader,
   router, event sessions, client, and process completion. A replayed failure
   already recorded from step 7 is not appended twice;
9. assemble and replay the one Wave 3 close result. Wave 4 inserts durable
   terminal/query/database stages into this same Task.

The forced branch has a stricter order. Grace expiry calls the exact old
AppServer handle's throwing `close(purpose:)`; its recorded Task sends the close
signal before its combined physical-completion wait. The Store records that
result once, then always calls throwing `waitUntilClosed()` as an idempotent
proof and separately awaits the affected Store-owned review workers. Only after
Host connection/process termination and those workers can no longer publish an
upstream terminal does the Store publish the forced transport interruption and
finish waiters. It then
continues with MCP drain and remaining Store-owned cleanup; normal close joins
the already-recorded AppServer combined-close result rather than signaling twice.
This branch cannot use normal semantic-publication-before-physical-close order.
A matching terminal already committed before force-close remains authoritative.
Neither branch has a timeout-detach path.

Wave 4 inserts durable terminal/history stages between 3 and 4 and query/DB
close after 8. Wave 3 must expose one insertion point rather than a second close
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
the exact handle's combined Host completion while the Store separately awaits
all affected review-worker Tasks. No second timeout detaches them.

`JSONRPC.Transport.close()` becomes a throwing package contract (with updated
process, fake, preview, and testing conformances) so force-close/process failure
cannot be erased by a nonthrowing adapter. `AppServerClient` and Host preserve
that typed value through `ReviewRuntimeCloseFailure`; callers never recover it
from log text.

The Store close Task is the only error assembler. It appends every typed failure
in the selected branch's declared order—the numbered normal order above or the
forced signal/wait-before-publication sequence; within a concurrently joined
Store or Host stage, registration ordinal—not completion timing—defines order.
The nonempty `ReviewCloseFailureAggregate` retains `first` plus every
`additionalInLifecycleOrder`. No failure prevents a later close/wait stage, and
cleanup, force-close, MCP handler-drain/listener, rate-limit, Host observation/
reader/router/session, client, and process failures are never reduced to logs.
Wave 3 does not generate `.persistence`, so
`secondaryPhysicalDatabaseClose` is always `nil`. Wave 4 keeps an original
persistence failure in the aggregate and uses the secondary field only for an
additional physical database-close failure. Every concurrent or later
`close()` caller receives the same recorded `ReviewCloseError`; Wave 4 may add
values to this assembler but not another assembler or close owner.

### Trigger policy

| Trigger | Product meaning |
|---|---|
| Explicit UI/MCP cancel | Await barrier, then requested interruption; no retry. |
| `store.stop()` / runtime disable | Await barrier, then system-requested interruption; drain/stop the current MCP lease and leave its owner reusable for later `start()`. |
| Same-account `restart()` | Interrupt the old attempt but keep the product review nonterminal; retain the MCP listener and create exactly one new AppServer attempt/runtime. |
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

Force-closing a shared app-server connection for one review follows this exact
runtime-wide sequence:

1. the target attempt's grace expiry enters the Store runtime owner;
2. before suspension, the Store changes the generation to
   `transitioning(.recoveryReplacement, ...)`, closes new review/runtime
   admission, and records one replacement Task;
3. the explicit cancellation target continues toward its requested terminal,
   while every other active attempt ID in that generation is registered in the
   forced-sibling recovery set;
4. the old AppServer client/process is force-closed exactly once;
5. before recording `.ownerForcedConnectionClose` as a product terminal, each
   sibling worker consults that set and installs `.sameAccountRestart`
   recovery; a natural canonical terminal that linearized first still wins;
6. if the Store remains `open`, the Host retains the old backend only for
   handoff/cleanup and creates exactly one replacement client/backend pair from
   its factory even when the forced-sibling set is empty. It neither closes nor
   recreates the current MCP generation/listener;
7. only after the Store activates and publishes the new AppServer generation
   does it resume each eligible sibling exactly once, and every resume uses the
   new backend, never the closed old backend. With zero eligible siblings, this
   publication still restores runtime availability; and
8. replacement creation/validation failure terminalizes all still-eligible
   siblings with the same typed failure, publishes the Store's typed runtime
   failed state, and leaves Store review/runtime admission closed. The
   app-lifetime MCP generation remains unchanged—its bound listener stays active
   or declared-no-MCP URL stays `nil`, with no second lease—so Live read/status
   operations can expose the failure and mutation tools return that typed
   runtime-unavailable failure.

Once the old AppServer close signal is sent, an `open` Store always needs the
one replacement; sibling count is not the condition. If a natural canonical
terminal wins before any old-runtime close signal is sent, no runtime was lost
and the replacement transition is cancelled. If the Store has entered `stop`
or application `closing`, its transition purpose suppresses replacement and
follows the corresponding MCP stop/terminal-close contract. An attempt-local
guard, retry, or replacement client per sibling is not an alternative owner
shape.

## Package API contract

New types stay package/internal and `Sendable`. Exact spelling may follow the
approved design, but there is one value for each concept:

```swift
package struct ReviewRuntimeClosePolicy: Sendable {
    package let terminalGrace: Duration
    package let sleep: @Sendable (Duration) async throws -> Void
    package static let production: Self
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
    // nil is reserved for a composition that explicitly has no MCP capability.
    // A Live owner that binds a listener must return the actual non-nil URL.
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
    // These methods govern only one replaceable AppServer generation. They
    // cannot reach an MCP listener or any Store-owned Task.
    func activate() async throws
    func closeAdmission() async
    // Installs one recorded Task. Its first physical operation sends the
    // client/process close signal; it then joins all Host auth/reader/router/
    // session/client/process completion before returning/throwing.
    func close(purpose: ReviewRuntimeTransitionPurpose) async throws
    // Idempotently joins/replays that exact recorded close completion; it never
    // initiates close or adds a second failure.
    func waitUntilClosed() async throws
}

package struct PreparedRuntime: Sendable {
    package let snapshot: RuntimePublicationSnapshot
    package let handle: any RuntimeLifecycleHandle
}

package protocol MCPServerLifecycleOwner: Sendable {
    // One owner identity spans the app lifetime. prepare is legal only from
    // stopped and creates one inert listener or declared-no-MCP generation.
    func prepare() async throws -> PreparedMCPServer
    // Bind completes here. Live returns the actual non-nil assigned URL,
    // including when configuration requested port 0. A declared no-MCP
    // Direct/Preview/Testing owner returns nil without fabricating a URL.
    func activate(
        _ generation: MCPServerGeneration
    ) async throws -> MCPServerPublicationSnapshot
    // Network admission closes before this operation awaits any handler.
    func closeAdmission() async
    func drainAdmittedHandlers() async throws
    // Nonterminal runtime-disable path; a later prepare is legal after wait.
    // Attempts all listener/session close signals, then returns/throws.
    func stop() async throws
    // Starts only after stop signaling and awaits physical completion.
    func waitUntilStopped() async throws
    // Terminal application-close path; later prepare/activate is illegal.
    // Attempts all listener/session close signals, then returns/throws.
    func close() async throws
    // Starts only after close signaling and awaits physical completion.
    func waitUntilClosed() async throws
}

@MainActor
package protocol CodexReviewStoreBackend: CodexReviewSettingsBackend, Sendable {
    // Existing non-runtime requirements remain unchanged. Runtime construction
    // is replaced by this inert preparation seam; it does not mutate the Store.
    // Stable identity for the entire Store lifetime; every access returns the
    // same owner, never a newly constructed listener owner.
    var mcpServerLifecycle: any MCPServerLifecycleOwner { get }

    func prepareRuntime(
        generation: ReviewRuntimeGeneration,
        purpose: ReviewRuntimeTransitionPurpose
    ) async throws -> PreparedRuntime
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
    case client(String)
    case process(String)
    case authenticationObservation(String)
    case reader(String)
    case router(String)
    case session(String)
    case worker(String)
    case rateLimit(String)
    case cleanup(String)
    case mcpHandlerDrain(String)
    case mcpServer(String)
}

package struct ReviewRuntimeCloseFailureAggregate: LocalizedError, Sendable {
    package let first: ReviewRuntimeCloseFailure
    package let additionalInLifecycleOrder: [ReviewRuntimeCloseFailure]
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

package struct ReviewCloseFailureAggregate: LocalizedError, Sendable {
    package let first: ReviewClosePrimaryFailure
    package let additionalInLifecycleOrder: [ReviewClosePrimaryFailure]
}

package struct ReviewCloseError: LocalizedError, Sendable {
    package let failures: ReviewCloseFailureAggregate
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

`ReviewRuntimeGeneration` is Store-owned and monotonically advances at every
acquisition/transition invalidation. `activate()` is called only by the Store
after exact-generation revalidation. Runtime `closeAdmission()` affects only
that AppServer generation's Host request/session admission. Runtime
`close(purpose:)` installs one recorded Task whose first physical operation
sends the client/process close signal before any Host completion wait. Matching
the existing client/transport contract, it may then join physical client/
process/reader and all Host auth/router/event-session completion before
returning/throwing. The Store always follows it with throwing
`waitUntilClosed()`, which idempotently joins/replays that exact result. A
replayed aggregate is recorded only once. The handle cannot reach Store review
workers, rate-limit work, Store cleanup, or MCP resources.

`MCPServerLifecycleOwner` is the only MCP lifecycle identity. Its
`closeAdmission()` is async for actor isolation; once the owner begins the
operation, closing network admission is its first mutation and precedes any
handler-drain await. `stop()`/`waitUntilStopped()` physically end the current
lease but return the owner to reusable `stopped`; `close()`/`waitUntilClosed()`
make it terminal. Runtime handles and `PreparedRuntime` contain neither this
owner nor its current lease.

The MCP server owns one admission state, not untracked NIO `Task` creation:

```text
running(generation, bound(accepting(admittedHandlerRegistry)))
  -> stopping(networkAdmissionClosed, finiteAdmittedHandlers)
  -> stopped

running(generation, declaredNoMCP) -> stopped

running | stopped | preparing | stopping
  -> closing(networkAdmissionClosed, finiteAdmittedHandlers)
  -> closed
```

The owner registers a handler before dispatch, removes it only after completion,
rejects every request that linearizes after `closing`, and awaits the finite
registry before disposing listener/session resources. `restartSameAccount` and
`recoveryReplacement` leave the `running` generation unchanged. A later
`start()` after runtime-disable `stop()` creates a fresh generation from the
same owner.

Both lifecycle owners normalize multiple failures from one close/wait method to
`ReviewRuntimeCloseFailureAggregate`. The Store flattens those values into
`ReviewCloseFailureAggregate` at the method's fixed lifecycle position; it never
keeps only the thrown `first` value.

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

Wave 3 defines the nonempty first-plus-additional close-failure aggregate and
the separate future physical-database-close secondary under one assembly owner,
even though it does not yet generate persistence values. Wave 4 adds stages and
values, not another error assembler.

Do not change the public `start(forceRestartIfNeeded:)`, `stop()`, `restart()`,
`waitUntilStopped()`, cancellation, review-result, or MCP tool signatures. Wave
3B's only public addition is
`@MainActor public func CodexReviewStore.close() async throws`. Wave 3C later
adds `@MainActor public func ReviewMonitorWindowController.closeAndWait() async`
under its separate gate. Neither exposes a package lifecycle/error or
persistence implementation type.

For Wave 3B, make
`Fixtures/CodexReviewKitProductConsumer/Sources/CodexReviewKitProductConsumer/main.swift`
an async consumer and call `try await store.close()` through the actual public
product. Record exactly that accepted additive declaration in
`scripts/compatibility-baselines/v0.6.2/public-api.json`, update the baseline
README and checksum metadata, and preserve every released declaration. The Wave
2 terminal fact remains `ReviewJobCore.Lifecycle.terminal`. MCP `tools/list`,
tool names, input schemas, and its five-tool byte-equivalent golden stay
unchanged. Run the strict API/consumer/MCP compatibility gate at every
checkpoint and at the combined Wave 3A+B merge gate.

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

This is the exact allowed write set. It is a ceiling, not a requirement to edit
every path. Any required production/test change outside it is a design blocker
and must be reported before editing.

Production — 12 paths:

1. `Sources/CodexReview/ReviewRuntimeLifecycle.swift` — new
2. `Sources/CodexReview/Store/CodexReviewStore.swift`
3. `Sources/CodexReview/Store/CodexReviewStoreBackend.swift`
4. `Sources/CodexReview/Store/CodexReviewStoreCancellation.swift`
5. `Sources/CodexReview/Store/CodexReviewStoreReviews.swift`
6. `Sources/CodexReview/Store/CodexReviewStoreTesting.swift`
7. `Sources/CodexReview/Store/CodexReviewStoreRateLimitAutoRefresh.swift`
8. `Sources/CodexReview/Store/PreviewCodexReviewStoreBackend.swift`
9. `Sources/CodexReviewTesting/TestSupport.swift`
10. `Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift`
11. `Sources/CodexReviewHost/CodexReviewHost.swift`
12. `Sources/CodexReviewMCPServer/CodexReviewMCPHTTPServer.swift`

Test/gate — 10 paths:

1. `Tests/CodexReviewTests/CodexReviewStoreLifecycleTests.swift` — new
2. `Tests/CodexReviewTests/CodexReviewStoreCommandTests.swift`
3. `Tests/CodexReviewTests/CodexReviewStoreRateLimitAutoRefreshTests.swift`
4. `Tests/CodexReviewHostTests/CodexReviewHostTests.swift`
5. `Tests/CodexReviewMCPServerTests/CodexReviewMCPHTTPServerTests.swift`
6. `Tests/ReviewUITests/ReviewUITests.swift` — backend compile seam only
7. `Fixtures/CodexReviewKitProductConsumer/Sources/CodexReviewKitProductConsumer/main.swift`
8. `scripts/compatibility-baselines/README.md`
9. `scripts/compatibility-baselines/v0.6.2/public-api.json`
10. `scripts/compatibility-baselines/v0.6.2/metadata.json`

Wave 3B consumes the reviewed 3A barrier and throwing cleanup/close contract; it
does not redesign the attempt processor. The Store close Task directly owns and
awaits Store acquisition/review/rate-limit/cleanup work, then orchestrates the
separate Host AppServer handle and MCP owner that await only their own resources.
A 3A cleanup failure retains its original operation/cause and is not folded into
worker success or discarded after a product terminal.
Wave 3B updates the accepted CodexReview API/consumer baseline only for public
`CodexReviewStore.close()`.

In `LiveCodexReviewStoreBackend.swift`, authentication-related edits are limited
to replacing existing account-transition `stop`/`start` calls with the Store
runtime command and joining the existing observation Task during close. Wave 3B
does not change auth provider, credential, registry, login, or wire semantics.

Explicitly excluded from Wave 3B are:

- `Sources/CodexReviewAppServer/**` and any Wave 3A redesign of
  `ReviewAttemptProcessor.swift`;
- `Sources/ReviewUI/**` and `Tools/ReviewMonitor/**` Wave 3C behavior;
- GRDB/history/schema/migration code and package dependencies;
- descriptor/environment preparation and executable capability redesign;
- auth provider/wire/RegistryV2/login staging behavior;
- MCP tool names, input schemas, and golden output; and
- workflows.

The Wave 3A checkpoint remains review evidence, not a merge candidate. Only the
combined Wave 3A+B exact-base diff may pass the merge gate; Wave 3C then starts
from that reviewed combined HEAD.

### Wave 3C — ReviewUI and application termination

- `Sources/ReviewUI/ReviewMonitorWindowController.swift`
- the existing root/split/sidebar/detail UI lifecycle owners only as required
- existing status/accessory/account/toolbar observation owners only when needed
  to join the same UI lifecycle generation
- `Tools/ReviewMonitor/CodexReviewMonitor/CodexReviewMonitorApp.swift`
- matching ReviewUI/ReviewMonitor tests and accepted API/consumer baseline

Wave 3C adds only the accepted ReviewUI
`ReviewMonitorWindowController.closeAndWait()` declaration to that baseline.

Wave 3C does not change the combined-reviewed 3A attempt processor or 3B runtime,
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
    owns activation/admission/backend-write authority;
18. with two concurrent reviews, one grace force-close closes both streams,
    terminalizes the sibling, and then fails to resume on the same closed client;
19. holding the runtime factory while stop/close wins allows the late start to
    publish `.running` and install stale client/backend state;
20. an admitted MCP tool handler held at a controlled gate outlives current
    `stop()` completion;
21. a rate-limit refresh held at a controlled gate is treated as complete after
    cancellation without its Task being joined; and
22. the timeout-detach cases in `CodexReviewStoreCommandTests` return while an
    owned worker is still unfinished;
23. current stop/close cannot prove Store worker/rate-limit/cleanup completion
    separately from Host reader/router/session/process completion; and
24. multiple failures from later shutdown stages are logged or overwritten
    after the first error instead of retained in deterministic order.

Then commit green checkpoints:

1. attempt interrupt reducer and AppServer ACK/terminal separation;
2. store cancellation waits the worker-owned terminal;
3. freeze and branch-review Wave 3A;
4. runtime generation and single close Task on reviewed 3A;
5. awaited transport/process/router/worker/MCP cleanup;
6. freeze Wave 3B, then run the combined Wave 3A+B exact-base merge review;
7. ReviewUI close and application termination decision on reviewed combined
   Wave 3A+B;
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
- canonical completed/failed during recovery suppresses that attempt's
  replacement candidate; canonical interrupted and policy-recoverable
  connection terminal create exactly one candidate; none of these per-attempt
  decisions suppresses the mandatory AppServer runtime replacement after a
  shared old-runtime close signal;
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
- with two concurrent reviews, target cancellation reaches the requested
  terminal, every healthy sibling enters forced-generation recovery once, and
  the Host factory creates exactly one replacement client/backend pair;
- the old backend is used only for handoff/cleanup and the new backend only for
  sibling resume; no sibling resume reaches the closed client;
- once old-runtime close is signaled, zero eligible siblings still creates and
  publishes exactly one replacement runtime when the Store remains open;
- replacement creation/validation failure gives every still-eligible sibling
  the same typed terminal failure without a retry loop, publishes runtime
  failed, keeps Store review/runtime admission closed, and leaves the one MCP
  network generation active for typed status/failure responses;
- concurrent/repeated close returns the same success/error;
- close/start, close/restart, stop/close, and concurrent-close interleavings all
  join the recorded owner; a stale acquired handle is closed exactly once and
  never published;
- stop during close joins; start/restart after close are no-ops;
- runtime-disable stop closes/drains/awaits one MCP lease, later start prepares
  and activates a new MCP generation on the same app-lifetime owner, while
  restartSameAccount/recoveryReplacement keep the existing listener and create
  no second lease;
- MCP configured with port 0 returns no pre-activation publication snapshot;
  activation returns the actual nonzero bound URL, and only exact-generation
  post-activation revalidation publishes it;
- Direct/Preview/Testing compositions that explicitly provide no MCP capability
  return `serverURL == nil`; they never synthesize a loopback/default URL, while
  a Live activated listener returning `nil` is a typed contract failure;
- application close terminalizes the MCP owner; MCP rejects requests after
  network admission close, awaits all previously admitted handlers, and then
  signals/awaits listener/session disposal;
- controlled owner gates prove Store review workers/rate-limit/cleanup finish
  before AppServer `close()` begins; that combined close sends the client/
  process signal before its physical-completion gate, and Store close remains
  pending while the gate is held. `waitUntilClosed()` joins the same result;
- forced close signals/waits Host termination and separately joins affected
  Store workers before forced semantic publication;
- rate-limit/worker/Store-cleanup callbacks and Host auth/router/session/client/
  process callbacks are independently absent after their owner completion;
- inject failures into MCP drain/stop/wait, Store worker/rate-limit/cleanup,
  AppServer combined close, and Host idempotent wait together; repeated close
  replays one `first` plus every `additionalInLifecycleOrder`, with registration
  ordinal inside concurrent stages, no duplicate of the handle's replayed aggregate,
  and no log-only loss;
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

Run the applicable full gates and a checkpoint review at the end of 3A. Do not
merge it. After 3B, run all 3B gates plus a branch-wide exact-base review of the
combined Wave 3A+B diff; that combined result is the only merge gate and the
only valid base for 3C. Run the 3C gates and branch-wide review separately. A
later slice never serves as validation for an earlier checkpoint.

After reviewed 3C, dispatch #113. Do not dispatch Wave 4 or Wave 5 directly from
a Wave 3 code/test checkpoint: the reviewed descriptor-capability result is an
additional mandatory predecessor.

Each worker commits only to its task branch, leaves a clean worktree, and does
not push, create a PR, tag, or close #106. Three failed fixes in one lifecycle
class, a second close owner, unowned cleanup Task, timeout detachment, or any
need to change the approved public API is a stop condition.
