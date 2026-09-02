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

## Lifecycle Responses

`review_start`, `review_await`, `review_read`, and `review_cancel` return a
`lifecycle` object. Each `review_list.items` entry contains the same object.

`lifecycle.status` is the broad job state: `queued`, `running`, `succeeded`,
`failed`, or `cancelled`. `lifecycle.terminal` is the authoritative terminal
classification and is `null` while the job is queued or running. Terminal
values have one of these shapes:

- Completed: `{"kind":"completed"}`
- Failed: `{"kind":"failed","message":<string-or-null>}`
- Interrupted: `{"kind":"interrupted","cause":<cause>}`

An interruption `cause` has a `kind`, `source`, and `message`:

- `requested`: `source` is `userInterface`, `mcpClient`, `sessionClosed`, or
  `system`; `message` contains the cancellation reason.
- `server`: `source` is `null`; `message` may contain a server-provided reason.
- `transport`: `source` is `null`; `message` describes the transport failure.
- `previousProcessExit`: `source` and `message` are `null`.

The current contract pairs `completed` with `status: "succeeded"`, a requested
interruption with `status: "cancelled"`, and the other terminal forms with
`status: "failed"`.

`lifecycle.cancellation` records cancellation intent and its source.
`lifecycle.terminal` records the authoritative outcome. Do not infer an
interrupted terminal from `cancellation` alone.

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
  - `terminal` authoritative terminal classification, or `null` before a
    terminal result; see [Lifecycle Responses](#lifecycle-responses)
- `output`
  - `summary`
  - `review`
  - `hasFinalReview`
  - `lastAgentMessage`
  - `reviewResult` parsed finding state (`hasFindings`, `noFindings`, or `unknown`) with title/body/location fields when available

Notes:

- `review_start` is the primary client flow. Every client waits up to 540
  seconds; if the job is still running, call `review_await` with the returned
  `jobId`.
- A terminal result is returned after its history commit is durable. Backend
  cleanup continues independently, and a later cleanup failure is available as
  a developer diagnostic through `review_read` with `logFilter: "all"`.
- ReviewMonitor starts a job with its effective settings model. After thread
  creation, it reports `thread/start.model` when available and otherwise keeps
  that requested model.
- Use `review_read` to fetch paged, ordered `logs`. `rawLogText` is the
  diagnostic/raw projection and is not a full log transcript.

### `review_await`

Waits for a running review job owned by the current MCP session. The wait is
bounded to 540 seconds so clients with fixed activity watchdogs can continue
waiting with another tool call.

Inputs:

- `jobId` or `jobID`

Returns the same lightweight shape as `review_start`: `jobId`, `run`,
`lifecycle`, and `output`. It does not include `logs` or `rawLogText`; use
`review_read` when log pages are needed.

If the job is still running after the bounded wait, call `review_await` again
with the same `jobId`.

### `review_read`

Reads the current or final state of a review job owned by the current MCP session.
Use this to fetch log pages or to refresh a job snapshot independently of the
bounded `review_start` / `review_await` flow.

Inputs:

- `jobId` or `jobID`

Optional paging inputs:

- `logOffset` 0-based log page offset. If omitted, `review_read` returns the
  latest page.
- `logLimit` page size, default `100`, max `500`
- `logFilter` `default` excludes command output and developer-only entries;
  `all` includes both

Returns:

- `jobId`
- `run`
- `lifecycle`
- `output`
- `logs` paged read projection. Grouped replacement/delta entries are folded
  into their current value before paging. Developer-only entries returned by
  `logFilter: "all"` include `audience: "developer"`; product entries omit
  `audience`.
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
