# Architecture

ReviewMonitor's UI and MCP server share one `CodexReviewStore`. The store owns
review state and commands; its backend sends requests to `codex app-server`.
`CodexReviewHost` connects these components when the app starts.

## Targets

| Target | Responsibility |
| --- | --- |
| `CodexReview` | Review API, observable store, authentication, settings, and history contracts |
| `CodexReviewAppServer` | JSON-RPC requests, notifications, and process transport for `codex app-server` |
| `CodexReviewPersistence` | SQLite history storage, migrations, and retention |
| `CodexReviewMCPServer` | MCP tool conversion and the Streamable HTTP endpoint |
| `CodexReviewHost` | Live backend, filesystem locations, and dependency assembly |
| `CodexReviewTesting` | Fake backend and transport, gates, and manual clock |
| `ReviewUI` | Monitor views and controllers |
| `TextTransitions` | Animated text rendering |

ReviewMonitor is the app entry point. The package exports `CodexReview`,
`CodexReviewHost`, `ReviewUI`, and `TextTransitions` as libraries; the other
production targets support those libraries internally.

## Review flow

Both UI actions and MCP tools call the store. `CodexReviewStoreBackend` supplies
runtime operations, with live, preview, and test implementations. Each uses the
same store to manage product state.

The live backend uses one shared connection to a long-lived `codex app-server`
process. The gateway initializes the connection once with `initialize` and
`initialized`, then sends typed requests:

- Mutating requests on the same thread run in order. Requests on different
  threads can run concurrently.
- A review uses a normal `turn/start` on its review thread. The adapter includes
  the target, working directory, and server-reported `$review-agent` skill
  provisioned during initialization.
- The gateway subscribes to notifications before `turn/start` so it can receive
  terminal events sent alongside the response.
- `turn/interrupt` can proceed while `turn/start` is pending. Cancellation uses
  control and cleanup requests; it keeps the transport open.

Fake and live tests use the same transport protocol.

## MCP sessions

The app hosts `http://localhost:9417/mcp`. An `initialize` request creates an
`MCP-Session-Id`; subsequent requests carry that header. The server returns JSON
or SSE according to client negotiation, and `DELETE` closes the session.

Jobs belong to the session that started them. The MCP adapter converts tool
arguments into store commands and converts their results into MCP responses.
The app-server gateway handles Codex's JSON-RPC separately. See the
[MCP reference](mcp.md) for tool and response fields.

## History and UI

The store loads and saves history through `CodexReviewPersistence`, which owns
the SQLite database. `CodexReviewHost` supplies its filesystem location. History
stores review metadata, final results, and findings; live transcripts stay in
memory. Restored reviews appear in the UI but are unavailable to new MCP
sessions.

`ReviewUI` observes the store and forwards user actions to it. UI tests cover
layout, selection, rendering, accessibility text, and action forwarding.
`CodexReviewTests` and `CodexReviewAppServerTests` cover review, authentication,
settings, and protocol behavior.

## Codex updates

`CodexReviewStore.updateCodex(when:install:)` pauses new review execution while
keeping accepted jobs and MCP sessions. It waits for current reviews or cancels
them according to the requested timing, finishes cleanup, stops the old runtime,
runs the installation closure, and starts the replacement runtime. Queued jobs
resume once that runtime is ready. Concurrent update calls wait for the same
operation, using the first call's installation closure.

Recovery checks whether the owned process has closed. A previously recorded
close error alone does not prevent recovery if the process is now closed.

The app's `ReviewMonitorCodexUpdater` owns update checks and their results.
Settings and the sidebar share that instance. Automatic checks run at launch
and at eight-hour intervals measured from launch. Manual checks join a check
already in progress and keep that schedule. A check due during installation
runs once after the update.

On application termination, the app stops checking, shuts down the store, and
waits for startup work before replying to AppKit. Store shutdown cancels an
update still waiting for reviews or waits for an installation already in
progress. Codex updates restart the runtime within the running app.

### Simulate an update

To inspect UI responsiveness, set `REVIEW_MONITOR_SIMULATE_CODEX_UPDATE=1` in the
Xcode scheme's **Run → Arguments → Environment Variables** and launch the app.
Use the live runtime with `REVIEW_MONITOR_MOCK_JOBS` and
`REVIEW_MONITOR_REVIEW_MODE` disabled.

After a one-second simulated check, the normal **Update** button appears. The
installation step waits ten seconds through the same subprocess runner as a
real update. The existing Codex runtime stops and restarts normally, while the
Codex and Homebrew packages stay unchanged. Settings then shows **Up to Date**.
Relaunch the app to repeat the simulation.
