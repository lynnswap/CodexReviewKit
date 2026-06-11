# MCP

ReviewMonitor exposes Codex review over its app-managed MCP Streamable HTTP
endpoint.

## Server Behavior

- App-managed Streamable HTTP MCP endpoint at `http://localhost:9417/mcp`
- Multi-session
- Session-scoped review jobs
- One long-lived `codex app-server` backend process
- One shared internal transport to the backend process
- Review jobs run concurrently across sessions and within the same session

## Tools

### `review_start`

Runs a review through the shared long-lived `codex app-server` backend and blocks until the final result is ready.

Key inputs:

- `cwd`
- `target`

`target` uses the app-server review target model:

- `{"type":"uncommittedChanges"}`
- `{"type":"baseBranch","branch":"main"}`
- `{"type":"commit","sha":"abc1234","title":"Optional title"}`
- `{"type":"custom","instructions":"Free-form review instructions"}`

Returns:

- `jobId`
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
- `output`
  - `summary`
  - `review`
  - `hasFinalReview`
  - `lastAgentMessage`
  - `reviewResult` parsed finding state (`hasFindings`, `noFindings`, or `unknown`) with title/body/location fields when available

Notes:

- `review_start` is the primary client flow. It waits for terminal completion, so MCP clients should configure a sufficiently large tool timeout.
- ReviewMonitor resolves the reported review model in this order:
  1. `~/.codex_review/config.toml` `review_model`
  2. the effective dedicated Codex config in `~/.codex_review/config.toml` `review_model`
  3. backend-reported `thread/start.model`
  4. the effective dedicated Codex config in `~/.codex_review/config.toml` `model` only as a pre-thread-start fallback when the backend does not report a model
- Use `review_read` to fetch paged, ordered `logs`. `rawLogText` is the
  diagnostic/raw projection and is not a full log transcript.

If you are unsure how to build the `target` object, read:

- `codex-review://help/tools/review_start`
- `codex-review://help/targets/uncommittedChanges`
- `codex-review://help/targets/baseBranch`
- `codex-review://help/targets/commit`
- `codex-review://help/targets/custom`

### `review_read`

Reads the current or final state of a review job owned by the current MCP session.
This is optional for normal clients because `review_start` already returns the final summary.

Optional inputs:

- `logOffset` 0-based log page offset. If omitted, `review_read` returns the
  latest page.
- `logLimit` page size, default `100`, max `500`
- `logFilter` `default` excludes command output; `all` includes it

Returns:

- `jobId`
- `run`
- `lifecycle`
- `output`
- `logs` paged read projection. Grouped replacement/delta entries are folded
  into their current value before paging.
- `logsPage`
  - `total`
  - `offset`
  - `limit`
  - `returned`
  - `hasMoreBefore`
  - `hasMoreAfter`
  - `previousOffset`
  - `nextOffset`
- `rawLogText` diagnostic/raw projection, not a full transcript

### `review_list`

Lists review jobs owned by the current MCP session.

Optional inputs:

- `cwd`
- `statuses`
- `limit` default `20`, max `100`

Returns:

- `items`
  - `jobId`
  - `cwd`
  - `targetSummary`
  - `run`
  - `lifecycle`
  - `output`

### `review_cancel`

Cancels a review job owned by the current MCP session.

Inputs:

- exact:
  - `jobId`
- selector:
  - `cwd`
  - `statuses`

Notes:

- `cwd` is a search key, not a unique identifier.
- Without `jobId`, `review_cancel` searches only the current MCP session.
- Responses include `lifecycle.cancellation.source` and `lifecycle.cancellation.message` when cancellation metadata is available. UI-triggered cancellations use `source: "userInterface"`.

## Discovery Resources

ReviewMonitor exposes onboarding/discovery resources over MCP. Clients can use `resources/list` and `resources/read` to inspect supported review flows without relying on the README.

Useful resources:

- `codex-review://help/overview`
- `codex-review://help/tools/review_start`
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
