# Test review history across an app restart

`run.sh` builds ReviewMonitor, runs a real Codex review, quits that app instance,
and relaunches it with the same SQLite database. It checks that the store restores
the result and that a new MCP session cannot access the restored job. A full
acceptance run also includes the UI inspection below.

## Before running

Authenticate `/opt/homebrew/bin/codex` in ReviewMonitor's Codex home, normally
`~/.codex_review`. The script uses that login and creates a temporary Git fixture
with an unsafe uncommitted change to produce a finding.

The app's composition root must support these isolated test inputs:

- `REVIEW_MONITOR_TEST_PORT`
- `REVIEW_MONITOR_TEST_CODEX_COMMAND`
- `REVIEW_MONITOR_TEST_DIAGNOSTICS_PATH`
- `REVIEW_MONITOR_TEST_HISTORY_PATH`

The script fails if those inputs are unavailable. It uses a dedicated
DerivedData directory, port, and history path. It leaves `HOME`, port `9417`,
and the production history database unchanged.

## Run the automated checks

From the repository root:

```bash
scripts/review-history-e2e/run.sh
```

Each run keeps an artifact directory with build and app logs, MCP requests and
responses, store diagnostics, SQLite schema and rows, and `e2e-summary.json`.

On failure, the script prints that directory and terminates the exact app PID
it started. It first requests a graceful quit. If the process stays alive, it
checks the executable path again before sending a signal.

## Inspect the restored UI

Run with the second app instance left open:

```bash
scripts/review-history-e2e/run.sh --keep-restored-app-running
```

The output and `e2e-summary.json` identify the app PID, rebuilt binary,
diagnostics, database, fixture, and job. Use that process's accessibility tree to
select the restored row. Check its target, terminal state, duration, final
review, and `AccessGate.swift` finding in the sidebar and detail view.

Save `ui-restored.png` in the artifact directory and record the inspected
accessibility state beside it. Set `uiEvidenceStatus` from `pending` only after
both the screenshot and accessibility checks pass; store diagnostics alone do
not verify rendering.

Finish with the exact termination command printed by the script. The script
waits for that app process to exit, keeping it in the isolated environment
throughout the inspection.
