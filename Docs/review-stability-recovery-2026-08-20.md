# ReviewMonitor stability recovery ledger (2026-08-20)

Status: In progress

Tracking issue: [#96](https://github.com/lynnswap/CodexReviewKit/issues/96)

Current-main baseline: `26c8f7b49e4afb356698d3c49e5107e96477b2ca`

Known-good candidate: `v0.6.2` (`c8c01d669673d41864db666507f1580155e8f89e`, release commit `82bddbcb1310a091eff742b36ab90781a4cbee5a`)

Audit branch: `codex/restore-review-stability`

Recovery branch: `codex/v0-6-2-recovery`

This is a resumable working ledger for the recovery. It is not yet the approved
Phase 2 design contract. Keep evidence, decisions, checkpoints, and remaining
work here until the recovery is complete; then either promote the durable
contract into the architecture documentation or remove this transient ledger.

## Reported failures

1. A terminal review message can be rendered as the raw structured JSON result.
2. A completed sidebar row shows the age since completion instead of review duration.
3. Review/log rows can disappear and return roughly one minute later.
4. Log presentation can fail or crash.
5. Review execution is generally unstable compared with v0.6.2.

## Scope and compatibility contract

- The current architecture is not a compatibility requirement.
- A clean branch from v0.6.2 is the selected recovery basis.
- Preserve the externally used MCP tool names and user-visible review behavior unless evidence requires a deliberate contract change.
- Reintroduce post-v0.6.2 functionality only when a concrete consumer need is confirmed and tracked by its own issue.
- API key authentication/login and Codex executable discovery are confirmed feature candidates.
- Do not preserve repo-internal compatibility shims or parallel state paths solely to ease migration.
- Keep current `main` and its persisted user data recoverable while testing the candidate branch.
- The bottom status accessory overlap is explicitly out of scope at the user's request.

## Recovery decision and remaining design gate

The selected architecture direction is:

1. **Restore from v0.6.2:** retain the product-owned review/store/UI flow and reimplement required features.
2. **Do not repair the current generic-chat architecture:** it admits internal reviewer children as product rows and changes row semantics when the process-local run owner disappears.

Before migration implementation, the Phase 2 gate still must include:

- current and desired owner maps for review identity, terminal result, persistence/replay, observation, selection, duration, and rendering;
- a required-feature inventory with one issue per independent contract;
- persisted-data and external MCP compatibility results;
- deletion/cutover list;
- characterization and runtime test plan;
- finding-to-design mapping.

## Evidence checklist

- [ ] Classify the `v0.6.2...main` history by owner and identify regression commits where possible.
- [x] Run the repository package tests at current `main` and v0.6.2.
- [x] Run the ReviewMonitor app tests at current `main` and v0.6.2.
- [x] Inspect available crash/error evidence without exposing credentials or review contents.
- [ ] Reproduce live review completion and terminal presentation.
- [ ] Reproduce selection/rebind, refresh, restart, and persisted replay.
- [ ] Trace the approximately one-minute disappearance/recovery boundary.
- [x] Verify completed-row duration semantics.
- [ ] Inventory post-v0.6.2 required features and create child issues.
- [ ] Complete Codex self-review after integration validation.

## Checkpoints

| Time | State | Evidence / next action |
|---|---|---|
| 2026-08-20 | Audit started | Current baseline clean at `26c8f7b`; screenshot confirms terminal JSON and duration symptoms. |
| 2026-08-20 | Parent issue created | Issue #96 owns the recovery program and acceptance criteria. |
| 2026-08-20 | Isolated recovery branch created | `codex/v0-6-2-recovery` starts at `v0.6.2`; validate it before changing architecture. |
| 2026-08-20 | Regression owners confirmed | #99 tracks internal reviewer-child leakage; #100 tracks duration and restart/replay semantics. |
| 2026-08-20 | Required features started | #97 tracks API key authentication and #98 tracks executable discovery. |
| 2026-08-20 | Baseline tests | Both app schemes pass. Current package tests deterministically crash in the API-key prompt UI test; v0.6.2 builds and its focused UI rerun passes after one full-suite UI failure signal. |
| 2026-08-20 | Recovery direction selected | Use v0.6.2 as the base; do not preserve the current generic-chat presentation architecture. |
| 2026-08-20 | Scope reduced | #101 closed as not planned; bottom accessory overlap is not part of this recovery. |

## Open decisions

- Whether current persisted data can be read directly by v0.6.2 or requires a one-time migration/export.
- Which post-v0.6.2 MCP contract changes are externally depended upon.
- Whether API key authentication belongs in the existing v0.6.2 authentication owner or requires a revised owner contract.
- Whether any current AppServerKit improvements are prerequisites for current Codex app-server compatibility.
