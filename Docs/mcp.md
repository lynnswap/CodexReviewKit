# MCP reference

ReviewMonitor hosts a Streamable HTTP MCP server at
`http://localhost:9417/mcp`. It shares one long-lived `codex app-server` process
across sessions. Reviews can run concurrently within a session and across
sessions, but each session can access only its own jobs.

## Tools

| Tool | Use |
| --- | --- |
| `review_start` | Start a review and wait for its result |
| `review_await` | Continue waiting for a queued or running review |
| `review_read` | Read a job snapshot and a page of logs |
| `review_list` | List jobs in the current session |
| `review_cancel` | Cancel a job in the current session |

### `review_start`

Pass `cwd` and a `target`. The target takes one of these forms:

- `{"type":"uncommittedChanges"}`
- `{"type":"baseBranch","branch":"main"}`
- `{"type":"commit","sha":"abc1234","title":"Optional title"}`
- `{"type":"custom","instructions":"Free-form review instructions"}`

The call waits up to 540 seconds, including time spent queued during a Codex
update. If the returned status is still `queued` or `running`, call
`review_await` with the returned `jobId`.

The response contains `jobId`, `run`, `lifecycle`, and `output`, described
[below](#response-fields). ReviewMonitor starts with its settings model and
reports `thread/start.model` when the server supplies it. Otherwise, it keeps
the requested model.

The store waits for the terminal history commit before returning the result.
Backend cleanup continues separately. A later cleanup failure appears in
`review_read` with `logFilter: "all"`.

### `review_await`

Pass `jobId` or `jobID` for a job in the current session. Each call waits up to
540 seconds and returns the same fields as `review_start`. Call it again if the
job is still queued or running.

Use `review_read` for logs; start and await responses contain neither `logs`
nor `rawLogText`.

### `review_read`

Pass `jobId` or `jobID` to read a job independently of start or await.

| Optional argument | Meaning |
| --- | --- |
| `logOffset` | Zero-based offset; omitting it selects the latest page |
| `logLimit` | Page size, default `100`, maximum `500` |
| `logFilter` | `default` excludes command output and developer entries; `all` includes both |

The response adds `logs`, `logsPage`, and `rawLogText` to the common fields.
Before paging, the server folds grouped replacements and deltas into their
current values. Developer entries have `audience: "developer"`; product entries
omit `audience`.

`logsPage` contains `total`, `offset`, `limit`, `returned`, `hasMoreBefore`,
`hasMoreAfter`, `previousOffset`, and `nextOffset`. Use the offsets to fetch
adjacent pages. `rawLogText` contains raw diagnostic text, not a full transcript;
use `logs` for ordered log entries.

### `review_list`

Lists jobs in the current session.

| Optional argument | Meaning |
| --- | --- |
| `cwd` | Filter by working directory |
| `statuses` | Filter by lifecycle status |
| `limit` | Number of jobs, default `20`, maximum `100` |

Each entry in `items` contains `jobId`, `cwd`, `targetSummary`, `run`,
`lifecycle`, and `output`.

### `review_cancel`

Pass `jobId` to cancel one job, or use `cwd` and `statuses` to select jobs in the
current session. A working directory can match more than one job.

The response includes cancellation source and message when available.
Cancellations from the app use `source: "userInterface"`.

## Response fields

Start, await, read, and cancel responses share these fields. List entries use
the same `run`, `lifecycle`, and `output` objects.

| Object | Fields |
| --- | --- |
| `run` | `reviewThreadId`, `threadId`, `turnId`, `model` (effective review model) |
| `lifecycle` | `status`, `exitCode`, `startedAt`, `endedAt`, `elapsedSeconds`, `cancellable`, `cancellation`, `errorMessage`, `terminal` |
| `output` | `summary`, `review`, `hasFinalReview`, `lastAgentMessage`, `reviewResult` |

`reviewResult` describes parsed findings as `hasFindings`, `noFindings`, or
`unknown`. Findings include title, body, and location fields when available.

### Lifecycle responses

`status` is `queued`, `running`, `succeeded`, `failed`, or `cancelled`.
`terminal` is `null` while the job is queued or running. Once it ends, the
terminal object records its outcome:

| Outcome | Terminal object | Status |
| --- | --- | --- |
| Completed | `{"kind":"completed"}` | `succeeded` |
| Failed | `{"kind":"failed","message":<string-or-null>}` | `failed` |
| Interrupted | `{"kind":"interrupted","cause":<cause>}` | `cancelled` for requested interruption; otherwise `failed` |

An interruption cause contains `kind`, `source`, and `message`:

| `kind` | `source` | `message` |
| --- | --- | --- |
| `requested` | `userInterface`, `mcpClient`, `sessionClosed`, or `system` | Cancellation reason |
| `server` | `null` | Server reason, when supplied |
| `transport` | `null` | Transport failure |
| `previousProcessExit` | `null` | `null` |

`cancellation` records a cancellation request and its source. A request may
arrive before the review's final outcome, so use `terminal` to determine how
it ended.

## Help resources

Use `resources/list` and `resources/read` to read help from the server:

- `codex-review://help/overview`
- `codex-review://help/tools/review_start`
- `codex-review://help/tools/review_await`
- `codex-review://help/targets/uncommittedChanges`
- `codex-review://help/targets/baseBranch`
- `codex-review://help/targets/commit`
- `codex-review://help/targets/custom`

`resources/templates/list` also provides templates for tool and target help.

## Runtime files

ReviewMonitor keeps its Codex runtime files in `~/.codex_review`:

| File | Contents |
| --- | --- |
| `config.toml` | Backend settings |
| `review_mcp_endpoint.json` | Current HTTP/SSE endpoint |
| `review_mcp_runtime_state.json` | Server and runtime ownership state |
