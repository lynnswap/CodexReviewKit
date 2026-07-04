# MCP

ReviewMonitor exposes Codex review over its app-managed MCP Streamable HTTP
endpoint.

## Server Behavior

- App-managed Streamable HTTP MCP endpoint at `http://localhost:9417/mcp`
- Multi-session
- Session-scoped review runs
- One long-lived `codex app-server` backend process
- One shared internal transport to the backend process
- Review runs run concurrently across sessions and within the same session

## Tools

### `review_start`

Runs a review through the shared long-lived `codex app-server` backend.

Key inputs:

- `cwd`
- `target`

`target` uses the app-server review target model:

- `{"type":"uncommittedChanges"}`
- `{"type":"baseBranch","branch":"main"}`
- `{"type":"commit","sha":"abc1234","title":"Optional title"}`
- `{"type":"custom","instructions":"Free-form review instructions"}`

Returns:

- `runId`
- `run`
  - `reviewThreadId`
  - `threadId`
  - `turnId`
  - `model` effective resolved review model
- `lifecycle`
  - `status`
  - `exitCode`
  - `startedAt`
  - `endedAt`
  - `elapsedSeconds`
  - `cancellable`
  - `cancellation` when cancellation metadata is available
  - `errorMessage`
- `review`
  - `hasFinalReview`
  - `finalReview` from the terminal Codex review response
  - `reviewResult` parsed finding state (`hasFindings`, `noFindings`, or `unknown`) with title/body/location fields when a final review is available
- `log`
  - `orderedEntryIds`
  - `activeEntryIds`
  - `activeEntryCount`
  - `latestEntryId`
  - `finalLifecycleMessage`
  - `finalResult`
  - `itemsPage`
  - `items` for detailed reads

Notes:

- `lifecycle.message` is review-run lifecycle text. It is not final review content.
- `review.finalReview` comes from the terminal review response. Chat log projection is only used for `log` details.
- `review_start` is the primary client flow. Codex clients wait for terminal completion. Claude Code clients wait up to 540 seconds; if the run is still running, call `review_await` with the returned `runId`.
- ReviewMonitor resolves the reported review model in this order:
  1. `~/.codex_review/config.toml` `review_model`
  2. the effective dedicated Codex config in `~/.codex_review/config.toml` `review_model`
  3. backend-reported `thread/start.model`
  4. the effective dedicated Codex config in `~/.codex_review/config.toml` `model` only as a pre-thread-start fallback when the backend does not report a model
- Use `review_read` to fetch detailed Codex chat log projection for a run.

If you are unsure how to build the `target` object, read:

- `codex-review://help/tools/review_start`
- `codex-review://help/tools/review_await`
- `codex-review://help/targets/uncommittedChanges`
- `codex-review://help/targets/baseBranch`
- `codex-review://help/targets/commit`
- `codex-review://help/targets/custom`

### `review_await`

Waits for a running review run owned by the current MCP session. The wait is
bounded to 540 seconds so clients with fixed activity watchdogs can continue
waiting with another tool call.

Inputs:

- `runId` or `runID`

Returns the same lightweight shape as `review_start`: `runId`, `run`,
`lifecycle`, `review`, and a compact `log`. Use `review_read` when log item
details are needed.

If the run is still running after the bounded wait, call `review_await` again
with the same `runId`.

### `review_read`

Reads the current or final state of a review run owned by the current MCP session.
This is optional for normal clients because `review_start` already returns the terminal lifecycle state and final review when a Codex chat projection is available.

Returns:

- `runId`
- `run`
- `lifecycle`
- `review`
- `log` with ordered item IDs, active item IDs, terminal lifecycle/final review
  values, paging metadata, and item details.

### `review_list`

Lists review runs owned by the current MCP session.

Optional inputs:

- `cwd`
- `statuses`
- `limit` default `20`, max `100`

Returns:

- `items`
  - `runId`
  - `cwd`
  - `targetSummary`
  - `run`
  - `lifecycle`
  - `review`

### `review_cancel`

Cancels a review run owned by the current MCP session.

Inputs:

- exact:
  - `runId`
- selector:
  - `cwd`
  - `statuses`

Notes:

- `cwd` is a search key, not a unique identifier.
- Without `runId`, `review_cancel` searches only the current MCP session.
- Responses include `lifecycle.cancellation.source` and `lifecycle.cancellation.message` when cancellation metadata is available. UI-triggered cancellations use `source: "userInterface"`.

## Discovery Resources

ReviewMonitor exposes onboarding/discovery resources over MCP. Clients can use `resources/list` and `resources/read` to inspect supported review flows without relying on the README.

Useful resources:

- `codex-review://help/overview`
- `codex-review://help/tools/review_start`
- `codex-review://help/tools/review_await`
- `codex-review://help/targets/uncommittedChanges`
- `codex-review://help/targets/baseBranch`
- `codex-review://help/targets/commit`
- `codex-review://help/targets/custom`

## Resource Templates

ReviewMonitor also exposes MCP resource templates for tool-specific and target-specific help. Clients can discover them via `resources/templates/list`.

## Runtime Files

ReviewMonitor uses `~/.codex_review` as its dedicated Codex home.

- `config.toml` stores backend settings for this dedicated home
- `review_mcp_endpoint.json` records the current HTTP/SSE endpoint
- `review_mcp_runtime_state.json` records internal server/runtime ownership state
