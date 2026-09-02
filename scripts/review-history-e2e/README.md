# Review history application E2E

`run.sh` is the isolated macOS semantic gate for durable ReviewMonitor history. It builds
the app into a dedicated DerivedData directory, runs an actual review through
`/opt/homebrew/bin/codex`, gracefully quits the exact app PID, relaunches against
the same SQLite database, and checks restored Store diagnostics plus MCP session
isolation. Complete app acceptance also requires the visible UI/accessibility
inspection and screenshot described below; diagnostics do not prove that the
sidebar or detail renderer is correct.

The application composition root must implement all four explicit test inputs:

- `REVIEW_MONITOR_TEST_PORT`
- `REVIEW_MONITOR_TEST_CODEX_COMMAND`
- `REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH`
- `REVIEW_MONITOR_TEST_HISTORY_PATH`

The script fails when that integration is absent. It never changes `HOME`, never
uses port `9417`, and never falls back to the production history location. The
fixture is a new temporary Git repository with one intentionally unsafe
uncommitted change so the real review produces a structured finding. The
effective ReviewMonitor Codex home (default `~/.codex_review`) must already be
authenticated for `/opt/homebrew/bin/codex`; the gate does not perform login or
redirect `HOME`.

Run the gate from the repository root:

```bash
scripts/review-history-e2e/run.sh
```

Every run retains its artifact directory, including build/app logs, MCP requests
and responses, semantic diagnostics, SQLite schema/rows, and a final summary. A
failure prints that directory and gracefully terminates only the exact app PID it
started; a verified process that ignores graceful termination is checked again by
executable path before an exact signal fallback.

For the required final visible UI inspection, leave the verified second instance running:

```bash
scripts/review-history-e2e/run.sh --keep-restored-app-running
```

The output and `e2e-summary.json` identify the restored app PID, rebuilt binary,
diagnostics, database, fixture, and job. Inspect the rebuilt process through the
macOS accessibility tree, select the restored row, and verify its target,
terminal state, duration, canonical review, and `AccessGate.swift` finding. Save
a screenshot as `ui-restored.png` in the artifact directory, record the inspected
accessibility state beside it, and change `uiEvidenceStatus` from `pending` only
after both checks pass. Finally, run the exact termination command printed by the
script. The script intentionally remains attached until that exact app process
terminates, so a non-interactive runner can inspect the UI without the child being
re-launched outside the isolated environment.
