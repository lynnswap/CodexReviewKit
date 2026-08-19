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
5. Sidebar status/progress UI can overlap review rows.
6. Review execution is generally unstable compared with v0.6.2.

## Scope and compatibility contract

- The current architecture is not a compatibility requirement.
- A clean branch from v0.6.2 is the leading recovery candidate.
- Preserve the externally used MCP tool names and user-visible review behavior unless evidence requires a deliberate contract change.
- Reintroduce post-v0.6.2 functionality only when a concrete consumer need is confirmed and tracked by its own issue.
- API key authentication/login is already a confirmed feature candidate.
- Do not preserve repo-internal compatibility shims or parallel state paths solely to ease migration.
- Keep current `main` and its persisted user data recoverable while testing the candidate branch.

## Architecture decision gate

The audit must compare these candidates before implementation:

1. **Restore from v0.6.2 (leading candidate):** retain the stable review/store/UI owners and reimplement required features.
2. **Repair current architecture:** only if the failure set is owned by a small number of coherent boundaries and does not require parallel source-of-truth paths or repeated call-site guards.

The gate must include:

- current and desired owner maps for review identity, terminal result, persistence/replay, observation, selection, duration, and rendering;
- a required-feature inventory with one issue per independent contract;
- persisted-data and external MCP compatibility results;
- deletion/cutover list;
- characterization and runtime test plan;
- finding-to-design mapping.

## Evidence checklist

- [ ] Classify the `v0.6.2...main` history by owner and identify regression commits where possible.
- [ ] Run the repository package tests at current `main` and v0.6.2.
- [ ] Run the ReviewMonitor app tests at current `main` and v0.6.2.
- [ ] Inspect crash/error evidence without exposing credentials or review contents.
- [ ] Reproduce live review completion and terminal presentation.
- [ ] Reproduce selection/rebind, refresh, restart, and persisted replay.
- [ ] Trace the approximately one-minute disappearance/recovery boundary.
- [ ] Verify completed-row duration semantics.
- [ ] Verify sidebar layout at representative content sizes.
- [ ] Inventory post-v0.6.2 required features and create child issues.
- [ ] Complete Codex self-review after integration validation.

## Checkpoints

| Time | State | Evidence / next action |
|---|---|---|
| 2026-08-20 | Audit started | Current baseline clean at `26c8f7b`; screenshot confirms terminal JSON, duration, and overlap symptoms. |
| 2026-08-20 | Parent issue created | Issue #96 owns the recovery program and acceptance criteria. |
| 2026-08-20 | Isolated recovery branch created | `codex/v0-6-2-recovery` starts at `v0.6.2`; validate it before changing architecture. |

## Open decisions

- Whether current persisted data can be read directly by v0.6.2 or requires a one-time migration/export.
- Which post-v0.6.2 MCP contract changes are externally depended upon.
- Whether API key authentication belongs in the existing v0.6.2 authentication owner or requires a revised owner contract.
- Whether any current AppServerKit improvements are prerequisites for current Codex app-server compatibility.
