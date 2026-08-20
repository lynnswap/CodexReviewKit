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

Future entries must identify the reviewed contract change, the replacement
baseline checksum, and the commit that accepted both.
