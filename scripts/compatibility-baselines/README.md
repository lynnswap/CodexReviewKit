# v0.6.2 compatibility gates

Run every published-compatibility gate from the repository root:

```bash
scripts/check-compatibility.sh
```

The aggregate command builds and runs the separate product consumer, checks the
four public Swift modules against the `swift-api-digester` baseline, and
compares MCP `tools/list` with the tracked golden. Individual gates are
available as `consumer`, `api`, and `mcp` subcommands.

The baseline under `v0.6.2/` records the published release source revision, the
approved recovery capture revision, and the exact Xcode/Swift/digester identity.
The Swift comparison pins the compiler build but excludes the host-specific
`Target:` line; the API capture target remains fixed by the digester invocation.
A toolchain mismatch fails loudly rather than generating a substitute result.
Updating this baseline requires an explicit accepted API change recorded in this
file; the checker never rewrites it.

## Accepted baselines

### v0.6.2 initial capture

- Published source: `82bddbcb1310a091eff742b36ab90781a4cbee5a`
- Capture revision: `0948f454b05c9a190deffb6707ee4b6416217e67`
- Recovery design acceptance: [`18499aa795d6af7716a5d94c92d4c7210fc3b821`](https://github.com/lynnswap/CodexReviewKit/commit/18499aa795d6af7716a5d94c92d4c7210fc3b821)

### v0.6.2 current-v2 review terminal addition

- Reviewed contract change: additive `ReviewTerminalKind`,
  `ReviewInterruptionCause`, `ReviewTerminalRecord`, and read-only
  `ReviewJobCore.Lifecycle.terminal`
- Capture revision: `d6b877752f8d5b101aa36382ba64d7d6fe786d71`
- Replacement baseline SHA-256: `465956e4233ae545980a42dd03bd34a4de2bedea93c4ce735f15b68a37ded17d`
- Accepted baseline update: [`f377ba37dee59eace8237f28661a27c121707d16`](https://github.com/lynnswap/CodexReviewKit/commit/f377ba37dee59eace8237f28661a27c121707d16)

### v0.6.2 Store close addition

- Reviewed contract change: additive `CodexReviewStore.close() async throws`
- Capture revision: `6a05d14a67932ffddb2f98791855df4a7a6a93a3`
- Recovery design acceptance: [`d0ec991ec9c553b30f49ac5689e8b3b159f6f1ae`](https://github.com/lynnswap/CodexReviewKit/commit/d0ec991ec9c553b30f49ac5689e8b3b159f6f1ae)
- Replacement baseline SHA-256: `04517f712053061a8f662752ecbb33d367738354aa2eef10609ebea57e0e501b`
- Accepted baseline update: [`846fed0178f25bb2613e1df1ad9b7e4477490359`](https://github.com/lynnswap/CodexReviewKit/commit/846fed0178f25bb2613e1df1ad9b7e4477490359)

Future entries must identify the reviewed contract change, the replacement
baseline checksum, and the commit that accepted both.
