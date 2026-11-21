# MCP reference

ReviewMonitor hosts a Streamable HTTP MCP server at `http://localhost:9417/mcp`.
Send the `MCP-Session-Id` returned by `initialize` with subsequent requests.
Each session can run several reviews and access only its own jobs. Send
`DELETE` to close the session.

## Tools

### `review_start`

Pass `cwd` and one of these `target` objects.

- `{"type":"uncommittedChanges"}`
- `{"type":"baseBranch","branch":"main"}`
- `{"type":"commit","sha":"abc1234","title":"Optional title"}`
- `{"type":"custom","instructions":"Free-form review instructions"}`

The call waits up to 540 seconds, including time spent in the queue during a
Codex update. If `lifecycle.status` is still `queued` or `running`, pass the
returned `jobId` to `review_await`.

### `review_await`

Pass `jobId` or `jobID` to wait up to another 540 seconds. Repeat until the job
ends. Both tools return the same [response fields](#response-fields). Use
`review_read` for logs.

### `review_read`

Pass `jobId` or `jobID` to read a snapshot and one page of logs.

| Optional argument | Meaning |
| --- | --- |
| `logOffset` | Zero-based offset (defaults to the latest page) |
| `logLimit` | Page size (default `100`, maximum `500`) |
| `logFilter` | `all` includes command output and developer entries omitted by `default` |

The response adds `logs`, `logsPage`, and `rawLogText` to the common fields.
Developer entries have `audience: "developer"`. Product entries omit `audience`.

`logsPage` contains `total`, `offset`, `limit`, `returned`, `hasMoreBefore`,
`hasMoreAfter`, `previousOffset`, and `nextOffset`. Use the offsets to fetch
adjacent pages. Use `logs` for ordered entries and `rawLogText` for diagnostic
text. Backend cleanup can finish after a review returns. Use `logFilter: "all"`
to see cleanup failures.

### `review_list`

List jobs in the current session.

| Optional argument | Meaning |
| --- | --- |
| `cwd` | Filter by working directory |
| `statuses` | Filter by lifecycle status |
| `limit` | Number of jobs (default `20`, maximum `100`) |

Each entry in `items` contains `jobId`, `cwd`, `targetSummary`, `run`,
`lifecycle`, and `output`.

### `review_cancel`

Pass `jobId` to cancel one job. You can also select a job by `cwd` and
`statuses`. If several jobs match, use the ID of the one you want to cancel.

## Response fields

Start, await, read, and cancel responses include `jobId` and these objects.

| Object | Fields |
| --- | --- |
| `run` | `reviewThreadId`, `threadId`, `turnId`, `model` (effective review model) |
| `lifecycle` | `status`, `exitCode`, `startedAt`, `endedAt`, `elapsedSeconds`, `cancellable`, `cancellation`, `errorMessage`, `terminal` |
| `output` | `summary`, `review`, `hasFinalReview`, `lastAgentMessage`, `reviewResult` |

`reviewResult` describes parsed findings as `hasFindings`, `noFindings`, or
`unknown`. Findings include title, body, and location fields when available.

### Lifecycle responses

`status` is `queued`, `running`, `succeeded`, `failed`, or `cancelled`.
`terminal` is `null` while the job is queued or running.

| Outcome | Terminal object | Status |
| --- | --- | --- |
| Completed | `{"kind":"completed"}` | `succeeded` |
| Failed | `{"kind":"failed","message":<string-or-null>}` | `failed` |
| Interrupted | `{"kind":"interrupted","cause":<cause>}` | `cancelled` for requested interruptions, otherwise `failed` |

For an interrupted review, inspect `cause.kind`.

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

Read `codex-review://help/overview` for a tool summary. Use `resources/list`
to discover tool and target examples, then `resources/read` to open one.
