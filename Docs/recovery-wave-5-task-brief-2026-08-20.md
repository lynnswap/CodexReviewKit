# Recovery Wave 5 task brief (2026-08-20)

Status: Design-gated, but no implementation slice is authorized until every
prerequisite below has a reviewed landing SHA recorded in the recovery ledger.

| Item | Value |
|---|---|
| Integration branch | `codex/v0-6-2-recovery` |
| Design | `Docs/recovery-design-2026-08-20.md` |
| Ledger | `Docs/review-stability-recovery-2026-08-20.md` |
| Issues | #97 API key, #98 executable discovery, #107 ChatGPT login |
| Required lifecycle base | Reviewed Wave 3C / #106 |
| Required filesystem base | Reviewed descriptor capability core / #113 |
| Required history base | Reviewed Wave 4D / #102 |
| Rejected evidence | `codex/recovery-wave-0-1-pr@c83e499`; must not merge or be repaired in place |

Wave 5 is four sequential task branches: **5A** authentication disk and
RegistryV2, **5B** provider-neutral `LoginSession` plus `LoginStagingLease` and
pending/debt recovery, **5C** executable capability resolution/composition, and
**5D** current ChatGPT/API-key plus activation/runtime-lease semantics. Each
starts from the reviewed predecessor SHA and receives its own exact-base Codex
review. They are not parallel workers.

## Prerequisite gate

Before 5A dispatch, record and verify all of:

1. The published compatibility gate and current-event contract are landed and
   reviewed independently.
2. Wave 3C supplies one throwing, joined runtime/process/application close owner.
   A runtime close result proves whether every process/client/reader/writer Task
   finished; timeout or cancellation request alone is not completion.
3. Issue #113 supplies `RecoveryEnvironmentPlan` → one
   `PreparedRecoveryEnvironment`, opaque `DirectoryCapability`/managed-file
   values, descriptor-relative create/read/replace/removal, and last-moment
   Process launch. Wave 4A alone adds the GRDB adapter that invokes the reviewed
   identity-revalidation core immediately before its open.
4. Wave 4D has inserted durable history commit/query/database close into the
   Wave 3 owner without storing authentication secret, pending, or cleanup debt.
5. The exact base SHAs and green compatibility/package/app gates are in the
   ledger. A historical code/test checkpoint is not a reviewed predecessor.

Failure of any prerequisite pauses Wave 5. Do not locally wrap a bare URL,
nonthrowing close, or raw filesystem helper to make a slice compile.

## Shared invariants

- `AuthenticationDiskStore` is the sole durable owner of RegistryV2, immutable
  auth revisions, `AuthenticationDiskStateV1`, activation journal, and primary
  runtime lease. It consumes prepared descriptor capabilities.
- `RecoveryEnvironmentPlan` owns configuration only. It does not allocate login
  sessions, persist pending/debt, copy credentials, or remove staging.
- `LoginSession` owns provider state, native presentation, and cancellation
  intent. One `LoginStagingLease` owns the staging capability, runtime/client,
  registered reader/writer Tasks, and one joined close result.
- Registry identity is generated `SavedAccountID`; email is nullable
  presentation metadata and never identity. At most one API-key saved account
  is admitted.
- Raw API-key text crosses only the one-shot write boundary, is cleared before
  await, is never retried after possible write, and never enters observable
  state, persistence, logs, diagnostics, or crash metadata.
- Authentication artifacts remain opaque. Product code validates identity,
  type/mode/ACL, bounded size, SHA-256, and byte count through descriptors but
  never decodes secret/JWT/account-ID content.
- `.addAccount` requires an active RegistryV2 account and leaves active ID,
  shared auth bytes, and primary runtime generation unchanged. `.signIn`
  activates only through the reviewed Wave 3 account-transition owner.
- A pending/outcome-unknown/cleanup-debt state blocks another authentication
  admission. History remains readable; no failure becomes an empty registry or
  an implicit sign-out.
- Existing public v0.6.2 declarations and MCP tool schemas remain compatible.
  New filesystem/auth implementation types are package/internal.
- No code from the rejected c83 branch is copied as an owner. Tests may preserve
  its case/alias/cleanup failures as characterization fixtures.

## Owner map

| Responsibility | Owner | Not an owner |
|---|---|---|
| Recovery names/trust policy | `RecoveryEnvironmentPlan` | `LoginSession`, UI |
| Descriptor I/O and identity | reviewed `RecoveryDescriptorFileSystem` | URL/string helpers |
| RegistryV2/artifacts/journals | `AuthenticationDiskStore` actor | live backend helper enum |
| Pending authentication + cleanup debt | `AuthenticationDiskStateV1.sessionState` in the disk actor | Environment, logs, UserDefaults |
| Staging live resources and close | one `LoginStagingLease` actor | provider callbacks, deinit |
| ChatGPT/API-key semantic outcome | `LoginSession` | staging directory existence |
| Shared-account activation | Wave 5-owned `AuthenticationActivationOperation` invoking reviewed Wave 3 runtime transition | `LoginSession`, registry write helper |
| Primary working-copy reconciliation | `runtime-lease.json` through the disk actor | `LoginStagingLease` |
| Executable candidate selection | `CodexExecutableResolver` | transport fallback search |
| Process path-only handoff | reviewed descriptor owner immediately before `Process.run` | cached/canonical URL |

## Authentication disk contract

The saved-account capability contains these descriptor-relative leaves:

```text
registry.json
  RegistryV2(schemaVersion, generation, contentHash, activeAccountID?, accounts[])
authentication-state.json
  AuthenticationDiskStateV1(schemaVersion, generation, contentHash, sessionState)
registry-migration-journal.json
activation-journal.json
runtime-lease.json
  PrimaryRuntimeLeaseV1(schemaVersion, runtimeGeneration, activeAccountID,
    baseRevision/fingerprint, preallocatedWritebackRevisionID,
    running | writebackPrepared | registryPublished)
<SavedAccountID>/revisions/<RevisionID>/auth.json
```

`authentication-state.json` is one versioned atomic manifest. Its sole
`sessionState` is:

```text
idle
staging(
  reserved(pending, relativeSessionComponent)
  | leased(pending, relativeSessionComponent, filesystemIdentity)
  | outcomeUnknown(pending, relativeSessionComponent, filesystemIdentity, reason)
  | cleanupRequired(relativeSessionComponent, filesystemIdentity,
                    discard | candidate(pending, immutableArtifact))
  | cleanupFailed(relativeSessionComponent, filesystemIdentity, continuation,
                  typedKind, operation, code?)
)
candidate(
  ready(pending, immutableArtifact) // staging absent
  | discardRequired(pendingWithCancellationIntent, immutableArtifact)
  | discardFailed(pendingWithCancellationIntent, immutableArtifact, failure)
)
```

This enum permits only one authentication session and keeps pending semantics
and deletion authority in one generation. It stores no absolute/canonical URL.
`pending` contains the session ID, preallocated candidate `SavedAccountID`,
preallocated immutable revision ID, intent, provider, previous active ID, and
cancellation intent. The surrounding `sessionState` case is the phase; there is
no second phase field to disagree.
`contentHash` covers the canonical encoding with its own field omitted.

Reservation is committed before staging creation. The disk actor asks the
descriptor owner to create the single UUID component relative to the prepared
login-staging root, reopens/`fstat`s it, and commits `leased` with exact identity
before returning a lease. A crash before creation sees `reserved` plus absence;
a crash after creation sees the same component and either records the verified
identity or fails closed. IDs never regenerate during replay.

The reservation input is a sanitized `AuthenticationStagingRequest` containing
only intent and provider. The disk actor reads the previous active ID from its
own RegistryV2 transaction. `CodexReviewAPIKey` remains inside `LoginSession`
until the one-shot transport write and never crosses the authentication disk
actor API.

Every JSON update is temp write + file fsync + same-directory `renameat` +
directory fsync. Immutable artifacts fsync file and containing directories
before RegistryV2 can reference them. Decode/hash/reference/generation conflict
is a typed persistence failure, never `RegistryV2.empty`.

RegistryV0→V2 migration reuses its prepared journal IDs across crash, copies
only descriptor-verified opaque artifacts into immutable revisions, and
publishes V2 atomically. It never mutates the V0 source. Duplicate normalized
keys, ambiguous active mapping, multiple API-key records, missing/corrupt
artifacts, unsafe component names, or unknown providers fail with V0 intact.

`runtime-lease.json` journals the primary shared Codex-home working copy. It is
not the login-staging lease and cannot authorize staging deletion. Its writeback
revision ID is durable before launch. Close writes only that revision, publishes
RegistryV2 before clearing the lease, and startup idempotently resumes every
file/registry/lease phase without scanning for a latest artifact. A valid disk
state never contains both an old primary runtime lease and an activation journal.

## LoginStagingLease state and failure

The in-memory state is exact:

```text
preparing(sessionID)
  -> open(resources, filesystemIdentity)
  -> closing(resources, oneCloseTask)
  -> closed(Result<LoginStagingCloseOutcome, LoginStagingCloseError>)
```

`resources` contains the actual staging capability, runtime/client handle, and
all registered reader/writer Tasks. Registration is rejected once `closing` is
installed. The first close installs `closing` before suspension; concurrent or
repeated close callers join the same Task and receive the same result.

Close order is:

1. Close staging admission and reject new resource registration.
2. Ask the reviewed Wave 3 runtime handle to close and join the real process,
   client, reader, and writer Tasks.
3. For outcome-unknown, atomically persist `outcomeUnknown` and retain the exact
   staging directory for next-start same-home reconciliation.
4. For confirmed provider success, use the authentication disk actor to write an
   immutable unreferenced candidate at the revision ID already stored in
   `pending`; this is a lease-owned writer. A crash before/after its rename or
   fsync reuses and validates that exact ID from `staging.leased`. For a
   definitive discard, there is no candidate.
5. Persist `cleanupRequired` only after resources and candidate write are proven
   complete. Reopen the manifested child relative to the login-staging root,
   require the stored device/inode/type/UID/mode/ACL identity, prove no live
   resource or second durable record references it, and remove recursively
   through descriptor-relative operations. The `cleanupRequired` state itself
   carries any pending candidate/intent needed after removal.
6. Fsync the parent. A discarded session becomes `idle`; a candidate becomes
   `candidate.ready`, which can finish without the deleted staging directory.
7. `.addAccount` publishes RegistryV2 first and clears `candidate.ready` only after
   the registry durably references the exact candidate. `.signIn` keeps
   `candidate.ready` while the Wave 5 activation actor quiesces the old runtime and
   clears it only after a matching activation journal is durable. The next owner
   always exists before the prior manifest is cleared.

`LoginStagingCloseOutcome` is `.discarded`,
`.preparedForActivation(candidate)`, `.added(savedAccountID)`, or
`.retainedForReconciliation(sessionID)`. Retention is a finite resource-close
outcome paired with an authentication outcome-unknown error; it is not reported
as successful authentication or cleanup.

`LoginStagingCloseError` retains:

- one nonoptional typed primary resource-aggregate-or-cleanup failure;
- every later cleanup or debt-persistence failure in order; and
- a debt disposition proving either the exact recorded
  `AuthenticationDiskSessionState` or the typed persistence failure plus last
  known state when debt recording itself failed.

The resource aggregate is nonempty and deterministic: runtime first, followed by
registered client/reader/writer Tasks in registration order, then the
close-owned candidate write. The runtime case
embeds `ReviewRuntimeCloseFailure`; other work keeps a typed task owner,
operation, code, and sanitized message. No joined failure is dropped or flattened
to `localizedDescription`. A primary and all secondary failures can coexist, and
the close error cannot be constructed with no cause.

If resource completion is not proven, removal is not attempted. If the manifest
cannot record deletion authority, removal is not attempted. Identity mismatch,
ACL/mount/policy drift, or removal failure preserves the directory and records
`cleanupFailed` when possible. Failure to record that debt preserves the
original and debt-write failures together. No case is `try?`, log-only, detached,
or converted to clean application close.

An unmanifested staging child, a manifested identity mismatch, or an unexpected
second child is preserved and fails new authentication admission. It is never
called an orphan and deleted by name. A prior primary account is considered only
from independently valid RegistryV2/runtime-lease/activation state. Cleanup
removes only a manifested, identity-matching, unreferenced lease.

## Startup reconciliation

Before primary runtime or new auth admission, the disk actor validates RegistryV2
and `AuthenticationDiskStateV1`, then handles each state through the same owner:

- `idle`: require no unexpected staging child; continue.
- `staging.reserved`: clear only when the manifested child is absent; otherwise
  descriptor-open it and advance with the same IDs or fail on policy/identity.
- `staging.leased`: treat a crashed provider write as outcome-unknown and perform
  a fresh app-server `account/read` from that exact staging capability; the
  preallocated revision ID validates/completes an interrupted candidate write.
- `staging.outcomeUnknown`: perform the same-home read without replaying login or a raw
  API key. Commit the confirmed provider result or retain typed debt.
- `staging.cleanupRequired` / `cleanupFailed`: prove no live resource reference and retry
  only the manifested identity-safe removal/finalization, preserving candidate
  and pending intent when present.
- `candidate.ready`: when cancellation intent is false, publish RegistryV2
  idempotently for add-account or resume/consume an exact activation journal for
  sign-in. A next-owner mismatch is corruption.
- `candidate.ready` with cancellation intent, `discardRequired`, or
  `discardFailed`: never activate; start the previous authoritative account when
  valid and resume descriptor-safe candidate cleanup.

Any unresolved state blocks new authentication and never hides loaded review
history. A prior RegistryV2 account starts only when RegistryV2/runtime-lease/
activation state is independently authoritative. Startup never chooses an account from email,
directory contents, or a guessed latest artifact.

## Provider and activation contract

- ChatGPT login follows current app-server start/completed/post-reload
  account-update/read semantics. `ASWebAuthenticationSession` is presentation
  only; app-server owns localhost callback. External-browser fallback happens
  once and observes the same staging session.
- API-key login uses one `AuthenticationWriteGate` and one non-retrying
  `sendOneShot`. `.notWritten` may cancel without reconciliation;
  `.mayHaveBeenWritten` requires same-home account read and never resends/retains
  the secret.
- A successful staging account read closes/joins the lease before adopting the
  opaque artifact. `.addAccount` atomically adds an inactive record. `.signIn`
  hands a `PreparedAuthenticationCandidate` to the Wave 5 activation actor.
- That actor invokes the reviewed Wave 3 runtime-transition owner to quiesce
  affected reviews and old runtime, then writes back and clears the primary
  runtime lease, rereads the latest RegistryV2 generation, commits the activation
  journal, materializes shared auth, starts one prepared runtime, and validates
  authoritative account read before journal removal.
- Cancellation before `committingJournal` wins and restarts the previous active
  account exactly once after quiescence, but only after persisting
  `candidate.ready.pending.cancellationIntent`. It then transitions through
  `candidate.discardRequired`/`discardFailed` while descriptor-safely removing
  the preallocated unreferenced revision. Startup never resumes activation when
  that intent is set. Cancellation afterward loses to
  activation/`.committedActivationPending`; it cannot rewrite the durable commit.

## Slice 5A — authentication disk and RegistryV2

Budget: 28 hours; at most 10 production and 7 test files.

Allowed responsibilities:

- new package-only authentication persistence owner files under
  `Sources/CodexReviewHost/Authentication/Persistence/`;
- RegistryV2/value/migration-journal and immutable artifact storage;
- `AuthenticationDiskStateV1` codec/atomic replacement;
- composition injection of the reviewed saved-accounts capability;
- focused Host persistence/migration tests.

5A does not start a login runtime, implement provider UI/wire behavior, or add
an Environment cleanup helper. It commits separately reviewed checkpoints for
disk schema/atomic state, immutable artifacts/RegistryV2, V0 migration/crash
replay, and finding fixes.

## Slice 5B — LoginSession, LoginStagingLease, pending/debt, startup recovery

Budget: 28 hours; at most 10 production and 8 test files.

Allowed responsibilities:

- new `LoginStagingLease` and staging-recovery owner files under
  `Sources/CodexReviewHost/Authentication/`;
- the provider-neutral `LoginSession` state/cancellation/presentation-close
  owner that creates and consumes exactly one lease; it lands in this slice so
  no bare staging owner exists before the lease contract;
- minimal AppServer/Host lifecycle-handle integration needed to retain and join
  the real runtime/client/readers/writers;
- every nested staging/candidate authentication-disk transition and startup
  reconciliation;
- focused descriptor/lease/restart/application-close tests.

5B uses fake provider outcomes only through the production data flow. It does
not implement ChatGPT/API-key-specific wire/UI behavior, activation, or
executable search. Within the slice, establish the `LoginSession` owner first
and add lease acquisition before any session can launch a runtime; do not ship
or review an intermediate path-owned session. It commits separately reviewed
checkpoints for the provider-neutral session state, reservation/acquisition,
joined close, cleanup/debt, startup reconciliation, and finding fixes.

## Slice 5C — executable capability and composition

Budget: 16 hours; at most 6 production and 5 test/gate files.

Allowed responsibilities:

- `CodexExecutableResolver` candidate policy;
- package-only executable capability resolution in the reviewed descriptor
  owner;
- `AppServerProcessTransport.Configuration` consuming #113's already reviewed
  capability-owned `Process.run` handoff; this slice does not define another
  revalidation or raw-path launch API;
- ReviewMonitor composition and focused resolver/transport/app tests.

5C performs one candidate search at composition and no transport fallback
search. Primary, staging, reconciliation, and import runtimes receive the same
resolved executable capability. Invalid explicit candidates fail without
fallback; implicit candidate order remains the canonical design contract.

## Slice 5D — ChatGPT/API-key and activation/runtime lease

Budget: 36 hours; at most 14 production and 10 test/gate files.

Allowed responsibilities:

- existing Host auth model/backend and native authentication owners;
- current AppServer account/login DTO/client seams and one-shot API-key write;
- the reviewed `LoginSession`, a Wave 5-owned
  `AuthenticationActivationOperation`, RegistryV2 account selection, activation
  journal, and primary runtime lease;
- directly required ReviewUI account/action presentation and tests.

5D extends the reviewed 5B `LoginSession`, consumes its lease, and launches only
through the reviewed 5C executable composition plus #113 Process handoff. It
cannot create a second session owner or delete staging itself. It commits
separately reviewed checkpoints for ChatGPT, API key/write admission, account
adoption/add-account, activation/runtime reconciliation, native UI, and finding
fixes.

## Required test matrix

- RegistryV2 fresh/open/corrupt/hash/reference/generation and every V0 migration
  journal crash point, including nil email and Bedrock preservation;
- reservation before creation, create/reopen identity publication, and crash at
  every `AuthenticationDiskStateV1` transition;
- case/Unicode/firmlink/symlink/mount/UID/mode/ACL/identity-swap rejection through
  the real #113 seam, with no global-path mutation;
- concurrent/repeated lease close, registration racing close, resource failure,
  manifest failure, identity mismatch, recursive removal failure, fsync/finalize
  failure, and exact ordered retention of every resource, cleanup, and debt-write
  failure;
- unmanifested/second/mismatched staging preservation; manifested referenced
  staging cannot be deleted;
- restart handling for every nested staging/candidate case, including candidate
  file crash points before/after rename/fsync and the cleanup-continuation state
  commit; unresolved debt blocks a new request but history stays visible;
- ChatGPT completion-before-post-reload update/read, nullable email, native
  cancellation, external-browser fallback, connection loss, grace reconciliation;
- API-key not-written/may-have-been-written, zero retry, secret non-retention,
  same-home reconciliation, duplicate slot rejection before staging/secret access;
- add-account byte-for-byte active/runtime preservation and sign-in activation
  cancellation on both sides of journal commit;
- pre-journal cancellation crash points after durable cancellation intent,
  old-runtime quiescence, previous-runtime restart, candidate-discard transition,
  candidate removal, and final state clear; no replay activates the candidate;
- activation/runtime-lease crash replay before/after exact writeback rename/fsync,
  RegistryV2 publish, lease phase/final clear, and invalid simultaneous
  lease+journal;
- executable candidate precedence, bundle identity, invalid explicit no-fallback,
  PATH/empty component, symlink identity, identity swap immediately before
  `Process.run`, and proof no second discovery occurs;
- compatibility aggregate, full package suite, ReviewMonitor app suite, and
  exact-base branch-wide Codex review for every slice.

Tests use continuations/gates and injected trusted temporary ancestors. They do
not use sleeps, request counts, deinit, cancellation dispatch, or a timeout as
proof of resource/cleanup completion.

## Validation and delivery

At every green checkpoint run the focused owner suites and
`scripts/check-compatibility.sh`. Before each slice review run:

```bash
swift test --build-system swiftbuild --no-parallel
xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj \
  -scheme CodexReviewMonitor \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Each worker commits only its intended files to its task branch, leaves a clean
worktree, records the exact base/result SHA, and does not push, create a PR, tag,
release, or close issues. Freeze and return to the design gate if a slice exceeds
its file/time budget, one failure class reaches three unsuccessful fixes, a raw
URL enters a registry/cleanup/open API, a second manifest/cleanup owner appears,
resource completion would be detached, or public/MCP behavior must change.
