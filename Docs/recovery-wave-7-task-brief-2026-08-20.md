# Recovery Wave 7 task brief (2026-08-20)

Status: Design-gated, but no implementation slice is authorized until reviewed
Wave 6 and the prerequisite gates below are recorded.

| Item | Value |
|---|---|
| Integration branch | `codex/v0-6-2-recovery` |
| Design | `Docs/recovery-design-2026-08-20.md` |
| Ledger | `Docs/review-stability-recovery-2026-08-20.md` |
| Issue | #108 |
| Current-main evidence | `17223698beb9a94336d35ebd3116496cfcd948df` |
| Upstream Codex | `3b45c29062ff0e76e71c91b6753290400e7fa8da` |

Wave 7 is five sequential task branches: 7A snapshot, 7B1 source adapter,
7B2 history import, 7C auth/preferences, and 7D admission/rollback/live proof.
Each starts from the reviewed predecessor SHA. They are not parallel workers.

## Shared invariants

- Current-main source and legacy preference keys are read-only. No source
  SQLite open, auth mutation, preference deletion, or reverse import exists.
- Recovery writes only journal-enumerated RecoveryV1 leaves. A before/after
  source mismatch publishes nothing.
- API-key bytes are never opened, copied, read, or hashed. ChatGPT/Bedrock bytes
  stay opaque; only the 7A snapshotter can construct `VerifiedOpaqueArtifact`,
  which Wave 5 RegistryV2 consumes without a second factory.
- Review eligibility is typed outer thread/turn/item evidence. Reviewer-child
  JSON never reaches the normalizer.
- Live/import use the same current-v2 normalizer and Wave 4 writer. No import
  cache, reducer, terminal owner, history publisher, or direct UI injection is
  added.
- New declarations are package/internal. Four released public products and MCP
  tool names/fields/schemas remain unchanged.
- Every async process/reader/writer/query/runtime Task is owned and awaited.
  Timeouts trigger typed close; they never prove quiescence/completion.
- Each focused-green checkpoint is committed before long gates. No push, PR,
  tag, release, or issue close is part of these workers.

## Prerequisite gates

Before 7A dispatch, record a reviewed Wave 6 HEAD and prove:

1. Issue #113 is reviewed and supplies descriptor-backed source/destination
   capabilities. All locator URLs are diagnostic inputs; source reads and every
   RecoveryV1 mutation are descriptor-relative, and no arbitrary destination
   URL reaches registry/cleanup/import APIs.
2. Wave 4 writer stores duration-only exact milliseconds and implements atomic
   batch import plus sanitized failure rows.
3. Wave 5 RegistryV2 exposes numeric current-main schema 0/1 batch import that
   accepts the snapshotter-produced `VerifiedOpaqueArtifact` type.
4. A targeted disposable probe proves the pinned Codex executable can perform
   auth-free sanitized exact-ID `thread/read(includeTurns:true)` for plain,
   compressed, legacy, and paginated fixtures. Failure returns to topology
   design for zstd/Rust support; it is not skipped.

## 7A — current-main preflight and verified snapshot

Outcome: `CurrentMainSourceSnapshotter` resolves one pinned source, proves
process/FD quiescence twice, copies exact allowlisted/provider-filtered inputs,
and returns one immutable verified manifest without changing source or active
RecoveryV1 leaves.

Budget: 18 hours; at most 7 production and 4 test files.

Allowed production owners:

- new `Sources/CodexReviewHost/Migration/CurrentMainSourceLocator.swift`
- new `Sources/CodexReviewHost/Migration/CurrentMainSourceManifest.swift`
- new `Sources/CodexReviewHost/Migration/CurrentMainSourceActivityProbe.swift`
- new `Sources/CodexReviewHost/Migration/CurrentMainSourceSnapshotter.swift`
- reviewed #113 plan/capability APIs as consumers only; changing their owner
  contract is an escalation
- package-only hashing/filesystem/process collaborators as one owner file each

Tests are new focused Host migration suites. Characterize custom/default root
precedence, malformed preference refusal, unknown SQLite, process/lsof FD
refusal by manifest device/inode while lsof paths remain diagnostic, DB/WAL/SHM
cohorts, copy-time mutation, UserDefaults mutation, symlink/path escape,
provider-filtered auth, API-key open trap, and source zero-diff.

Commit gates:

1. Locator + exact manifest
2. Activity probe + raw cohort copy
3. staging backup/quick-check + provider filter
4. freeze/full review

## 7B1 — sanitized exact-ID source adapter and shared normalization

Outcome: source DB indexes only canonical outer candidates; one sanitized local
app-server reads exact IDs with turns and feeds the same live normalizer. It
handles `.jsonl` and `.jsonl.zst` without source config/auth.

Budget: 28 hours; at most 9 production and 5 test files.

Allowed owners:

- new `Sources/CodexReview/Persistence/Import/CurrentMainReviewIndex.swift`
- new migration adapter files under `Sources/CodexReviewAppServer/Migration/`
- existing current-v2 decoder/item/terminal normalizer files only to extract a
  shared typed boundary
- corresponding AppServer/persistence fixture suites

Required tests: exact `thread/read(includeTurns:true)`, pinned initialize values,
manifest-only rollout path mapping, outside-path refusal, plain/zstd, legacy/
paginated, child/outer eligibility, multiple/cross marker failures, canonical
semantic source hash, deterministic source ordinal, and live/import event
equivalence.

Commit gates:

1. typed state/rollout index
2. sanitized process + exact read
3. shared normalizer + eligibility/hash
4. freeze/full review

## 7B2 — atomic Wave 4 history import

Outcome: `ReviewHistoryStore.importLegacy` owns deterministic IDs, review/
attempt/log/final-result transaction, success manifest, sanitized retryable
failure record, and same/different-hash idempotency.

Budget: 22 hours; at most 6 production and 5 test files.

Allowed owners are new files under
`Sources/CodexReview/Persistence/Import/` and the reviewed Wave 4 schema/store
import extension only. No Store/UI/MCP direct mutation.

Required tests: deterministic ID goldens; workspace/creation mapping; source
ordinal; exact/lower-bound/unavailable and duration-only exact values; full/
sparse canonical row; transaction rollback; identical no-op; hash conflict;
failure-row retry; primary+secondary failure; eligible-failure admission block;
restart hydration.

Commit gates:

1. typed import payload + deterministic IDs
2. atomic success/idempotency
3. failure transaction/duration/log invariants
4. freeze/full review

## 7C — current-main auth and preference conversion

Outcome: numeric account schema 0/1 becomes one ordered typed batch for Wave 5
RegistryV2; only allowlisted validated preferences are conditionally committed.

Budget: 26 hours; at most 8 production and 5 test files.

Allowed owners:

- new Host migration account/preferences adapters
- the reviewed Wave 5 registry's package import extension
- `Sources/CodexReviewHost/CodexReviewRuntimePreferences.swift`
- corresponding Host/UI migration tests

Required tests: schema 0/1/journal/debt, source order/active mapping/generated ID
crash replay, ChatGPT/Bedrock verified opaque revision, invalid artifact
reauthentication, API-key read/open trap, active API-key signed-out result,
external cleanup-debt refusal, sidebar vocabulary, preference conflict, and old
bytes/keys/source unchanged.

Commit gates:

1. typed account batch + provider filtering
2. RegistryV2 import/journal
3. preference allowlist/conflict
4. freeze/full review

## 7D — cutover admission, rollback, and live proof

Outcome: one `RecoveryCutoverCoordinator` resumes the state machine through
final admission, blocks runtime/query at the required boundaries, and supports
pre-admission cleanup or post-admission same-parent rollback archive.

Budget: 22 hours plus the live matrix; at most 7 production and 5 test/gate
files.

Allowed owners:

- `Sources/CodexReviewHost/LiveCodexReviewStoreBackend.swift`
- `Sources/CodexReviewHost/` RecoveryEnvironment plan/composition call sites,
  consuming reviewed capabilities without adding path mutation helpers
- new Host cutover coordinator/journal files
- ReviewMonitor composition/lifecycle only for cutover admission/rollback UI
- corresponding Host/app integration tests, ledger, and cutover docs

Required tests: every crash/resume phase, source/snapshot/destination conflict,
auth-required vs auth-failed, first-query-before-import refusal, runtime/MCP-
before-admission refusal, conditional preference restore, same-parent rename
failure, rollback archive, current-main restart from unchanged source, and
repeat forward cutover.

Final live proof:

- source manifest remains identical before/after/restart/rollback
- eligible = imported + documented skips; eligible failure = 0
- outer + reviewer child produces one row and one human log
- exact/lower-bound/unavailable duration and stopped-app-server hydration
- normal, long output, cancel, network loss, login, restart, persisted replay
- current Codex and Claude Code published five-tool MCP matrix
- ChatGPT artifact restart and proof no legacy API-key bytes exist in
  RecoveryV1/snapshot/diagnostics
- rollback current-main launch and repeat forward cutover from archive

## Validation for every slice

Focused tests are followed by:

```bash
scripts/check-compatibility.sh
swift test --build-system swiftbuild --no-parallel
xcodebuild test -project Tools/ReviewMonitor/CodexReviewMonitor.xcodeproj \
  -scheme CodexReviewMonitor \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

Run branch-wide Codex review against the exact slice base and fix valid
findings. Leave the worker worktree clean and report commit SHAs/test counts.

## Stop conditions

Freeze a checkpoint and return to design gate if any of these occurs:

- source bytes/preferences change, API-key artifact is opened, or destination
  writes occur before manifest equality
- exact-ID zstd adapter fails and needs a dependency/helper topology change
- Wave 4 schema/import API or Wave 5 RegistryV2 contract must change
- a public declaration/MCP schema changes
- an import-only reducer/cache/publisher/terminal owner appears
- a cleanup/process/DB/query Task would be detached
- file budget is exceeded or one failure class needs three unsuccessful fixes
