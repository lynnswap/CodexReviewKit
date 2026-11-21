# Architecture

ReviewMonitor's UI and MCP server share one `CodexReviewStore`. It owns review
state and commands. At launch, `CodexReviewHost` connects the store to the MCP
listener, the SQLite history database, and the backend that runs `codex app-server`.

## Targets

| Target | Responsibility |
| --- | --- |
| `CodexReview` | Review API, observable store, authentication, settings, and history contracts |
| `CodexReviewAppServer` | JSON-RPC requests, notifications, and process transport for `codex app-server` |
| `CodexReviewPersistence` | SQLite history storage, migrations, and retention |
| `CodexReviewMCPServer` | MCP tools and the Streamable HTTP endpoint |
| `CodexReviewHost` | Live backend, filesystem locations, and dependency assembly |
| `CodexReviewTesting` | Fake backend and transport, gates, and manual clock |
| `ReviewUI` | Monitor views and controllers |
| `TextTransitions` | Animated text rendering |

The package exports `CodexReview`, `CodexReviewHost`, `ReviewUI`, and
`TextTransitions` as libraries.

## Review flow

The store records each accepted review before dispatching it to the backend.
The live backend shares a long-lived app-server connection across reviews.
Each review gets a thread. The adapter subscribes to notifications before
sending `turn/start` with the `$review-agent` skill so it can receive a terminal
event even if it arrives with the response. Reviews on different threads can
run concurrently.

History keeps review metadata, final results, and findings in SQLite. Live
transcripts stay in memory. After relaunch, the UI restores past reviews.
Each MCP session can access only the jobs it started.

## Codex updates

`ReviewMonitorCodexUpdater` checks for CLI updates. The store keeps the MCP
listener open and queues new reviews while an update is pending. It drains or
cancels active reviews according to the user's choice, waits for cleanup,
and stops the old app-server before running the installer. Queued reviews
resume in acceptance order once the replacement runtime is ready.

To exercise this flow in Xcode, set `REVIEW_MONITOR_SIMULATE_CODEX_UPDATE=1`
with `REVIEW_MONITOR_MOCK_JOBS` and `REVIEW_MONITOR_REVIEW_MODE` disabled. The
app simulates installation and restarts the live runtime.
