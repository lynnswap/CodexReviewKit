# Recovery Wave 2 task brief (2026-08-20)

| Item | Value |
|---|---|
| Integration branch | `codex/v0-6-2-recovery` |
| Approved design | `Docs/recovery-design-2026-08-20.md` |
| Issues | #104 canonical terminal, #105 notification normalization |
| Upstream contract | `openai/codex@3b45c29062ff0e76e71c91b6753290400e7fa8da` |
| Live binary fixture | `codex-cli 0.148.0-alpha.15` |
| Budget | 18 hours; at most 9 production and 8 test/gate files |

This is one worker charter because terminal and notification normalization share
`AppServerCodexReviewBackend.swift`; splitting them would create two competing
attempt reducers. The worker implements current-v2 semantics in the existing
product-owned in-memory flow. Persistence and the cancellation terminal barrier
remain later waves.

## Outcome

One attempt-scoped reducer fixes the canonical `(reviewThreadId, turn.id)` pair,
normalizes current-v2 review notifications, and emits one typed product terminal
with one human final result. UI and MCP consume the `ReviewJobCore` fact; neither
searches logs, child threads, or arbitrary last messages for success.

## Broken invariants to remove

- A later event can currently rebind the response turn to another turn ID.
- Current `turn/completed { turn: ... }` is decoded as obsolete top-level
  `message/result`, and missing/unknown status falls through to success.
- `exitedReviewMode`, store completion, stream EOF, and MCP each infer final
  output independently.
- Known malformed notifications and transport framing errors are silently
  dropped; required item IDs/types can be fabricated.
- Stable duplicate and conflicting terminal/event payloads are not
  distinguished.
- Historical process-output code guesses standalone handle correlation by
  string equality.

## Owner and allowed write set

Production responsibilities/files:

- new `Sources/CodexReview/Model/ReviewTerminal.swift`
- `Sources/CodexReview/Model/ReviewJobCore.swift`
- `Sources/CodexReview/CodexReviewTypes.swift`
- `Sources/CodexReview/Store/CodexReviewStoreReviews.swift`
- new current-v2 notification DTO/decoder file under
  `Sources/CodexReviewAppServer/`
- new attempt terminal reducer file under `Sources/CodexReviewAppServer/`
- `Sources/CodexReviewAppServer/AppServerCodexReviewBackend.swift`
- `Sources/CodexReviewAppServer/AppServerProcessTransport.swift`
- `Sources/CodexReviewMCPServer/CodexReviewMCPProtocolServer.swift`

Test/gate responsibilities/files:

- one new current-v2 contract test file under `CodexReviewAppServerTests`
- minimal updates to `AppServerClientTests.swift`
- one new terminal contract test under `CodexReviewTests`
- minimal updates to `CodexReviewStoreCommandTests.swift`
- MCP result tests in `CodexReviewMCPHTTPServerTests.swift`
- external product consumer fixture
- accepted public API baseline and metadata

Do not modify ReviewUI, CodexReviewHost/auth/runtime paths, Package dependencies,
MCP tool input schemas/names, workflows, GRDB/history types, reorder/paging, or
legacy import. Do not port CodexKit/DataKit/generic chat types.

If the contract cannot fit this write set/file budget, or requires a second
terminal owner/public type not listed below, freeze a checkpoint and escalate.

## Canonical identity and output

- `ReviewStartResponse(reviewThreadId, turn.id)` is immutable attempt identity.
  Auxiliary/stale/child turns cannot rebind it or satisfy its terminal.
- Full delivery: same-pair `item/completed` with
  `item.type == exitedReviewMode` supplies authoritative nonempty review text.
- Sparse delivery: only same-pair `turn/completed` with `itemsView == summary`
  and exactly one nonempty synchronous `agentMessage` may supply the result.
- Full marker wins when both exist. The typed final assistant companion is
  suppressed/promoted so the product log contains one visible final row.
- Empty/multiple/async/child/cross-turn/cross-attempt summaries produce typed
  `missingFinalReview`; no generic last-message fallback.
- Completed final result is nonempty normalized UTF-8 up to 256 KiB. Over-limit
  output is a typed visible failure, never silent truncation.
- Stream EOF without an authoritative terminal is failure, not inferred success.

## Notification and fault containment

- Review command output uses only
  `item/commandExecution/outputDelta {threadId,turnId,itemId,delta}` and consumes
  raw deltas exactly once in connection order.
- `command/exec/outputDelta` and `process/outputDelta` are standalone traffic.
  Recovery originates no such request, so an unregistered handle cannot mutate
  or fail a review and is never matched by string equality/broadcast. Do not add
  a handle registry in this wave.
- Preserve the Unicode string already delivered by app-server, including
  replacement scalars from upstream lossy decoding.
- Unknown unrelated methods produce one bounded connection diagnostic and
  continue.
- Invalid framing, missing pre-routing identity, or conflicting active routing
  closes the connection and fails affected attempts.
- A malformed known payload after exactly one attempt is selected is
  attempt-fatal; other attempts on the connection continue.
- Verified old-attempt events remain attempt-local and cannot mutate product
  lifecycle/output/log.
- Identical stable lifecycle duplicate is a no-op; conflicting stable payload
  is a typed attempt failure. Raw delta chunks have no receipt/dedupe key.
- External input must not reach a production precondition/trap.

## Public and package API contract

The only new public surface in this wave is the approved additive terminal fact:

```swift
public enum ReviewTerminalKind: String, Codable, Sendable, Hashable

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

public internal(set) var ReviewJobCore.Lifecycle.terminal: ReviewTerminalRecord?
```

The existing public lifecycle initializer must remain exact—same name, labels,
order, defaults, and function-reference shape—and initialize `terminal = nil`.
A package-only initializer accepts a mandatory `terminal:` label. Old Codable
payloads missing the field decode to nil; new terminal/status mismatches are
rejected at the package owner.

Package-only types include `ReviewFinalResult`,
`ReviewTerminalOutputStrategy.currentV2`, typed ingestion/containment errors,
attempt terminal accumulator, and stable lifecycle receipt/fingerprint. Do not
add history/persistence/duration/close API in Wave 2.

MCP adds only result data at `lifecycle.terminal`; `tools/list` remains byte-
canonical to the existing golden. Encode completed, failed with optional
message, and interrupted cause/source/message exactly as the approved design.

The strict public API checker will fail after the approved additions. Update its
tracked baseline/checksum/capture metadata in the same checkpoint, keep all
v0.6.2 declarations, and extend the external fixture to prove both the exact old
initializer function reference and the new read-only terminal types.

## Characterization-first checkpoints

Before production edits, add raw current-v2 fixtures pinned with upstream SHA,
installed binary version, and schema revision. Fixtures characterize the wire
shape, not the existing permissive decoder. Replace obsolete fixtures that put
result/status at the wrong level or bless turn rebind/terminal-before-marker
ordering.

Required contract coverage:

- full marker, sparse summary, both with marker precedence
- missing/empty/multiple/async/child/cross-identity result rejection
- completed/interrupted/failed/inProgress/unknown turn status
- immutable canonical pair and concurrent attempts with colliding item strings
- item lifecycle duplicate/no-op and conflict/failure; raw duplicate delta
  appends twice
- malformed known event attempt containment; framing/routing connection
  containment; unknown unrelated method diagnostic
- review command streamed output, empty aggregate completion, command-only
  completion, replacement Unicode preservation
- unregistered standalone command/process delta produces no review mutation
- EOF without terminal failure
- requested interruption maps to legacy cancelled while spontaneous interruption
  maps to legacy failed; both retain typed interruption
- MCP running null and all terminal JSON shapes; tools golden unchanged
- old Lifecycle Codable payload and exact initializer function reference

## Historical port policy

- `fa31519`: port field decoding, empty-aggregate preservation, and Unicode
  behavior; reject first-string-match process correlation and generic timeline.
- `8e3ec41`: port canonical review/missing-output principles; reject CodexKit,
  DataKit, run aliases, and last-log fallback.
- `e7eac9e`: use sparse fixture idea only; reject version-unscoped
  `reviewOutputText ?? finalAnswer` fallback.
- `128b42c` / `cb84149`: port typed completed/interrupted/failed split and
  missing-output failure; reject SDK/session wholesale copy.
- Do not port `ReviewChatLogUI` content-equality dedupe.

## Validation and commit policy

Commit green checkpoints before long validation:

1. current-v2 characterization fixtures/tests
2. decoder/router/reducer and output normalization
3. store/public terminal/MCP and accepted API baseline
4. review-finding fixes

Run:

- focused AppServer, store, and MCP contract tests
- `scripts/check-compatibility.sh`
- `swift test --build-system swiftbuild --no-parallel`
- ReviewMonitor app tests from `AGENTS.md`
- branch-wide Codex review against the worker base

Three failed fixes in one failure class, multiplying identity guards, or any need
to modify the approved owner/API is a stop condition. The worker commits only to
its task branch, leaves a clean worktree, and does not push/create a PR/tag.
