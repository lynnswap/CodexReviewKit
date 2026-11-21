# Test review history across an app restart

Authenticate `/opt/homebrew/bin/codex` in ReviewMonitor's Codex home (normally
`~/.codex_review`), then run this command from the repository root.

```bash
scripts/review-history-e2e/run.sh
```

The script builds ReviewMonitor, runs a review in a temporary repository, and
relaunches the app with the same test database. It checks that the result is
restored and that a new MCP session cannot access it. The artifact directory
contains the logs, database output, and `e2e-summary.json`.

## Inspect the restored UI

To check the sidebar and detail view as part of the run, keep the restored app
open.

```bash
scripts/review-history-e2e/run.sh --keep-restored-app-running
```

1. Use the printed PID to select the restored row through the app's accessibility
   tree. Check the target, terminal state, duration, final review, and
   `AccessGate.swift` finding.
2. Save `ui-restored.png` and the accessibility output in the artifact directory.
   In `e2e-summary.json`, set `uiScreenshot` and `uiAccessibility` to their
   absolute paths and `uiEvidenceStatus` to `verified`.
3. Run the printed termination command. The script waits for that app to exit
   and checks both evidence files.
