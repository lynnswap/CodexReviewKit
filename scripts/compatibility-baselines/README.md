# v0.6.2 compatibility gates

Run every published-compatibility gate from the repository root:

```bash
scripts/check-compatibility.sh
```

The aggregate command builds and runs the separate product consumer, checks the
four public Swift modules against the `swift-api-digester` baseline, and
compares MCP `tools/list` with the tracked golden. Individual gates are
available as `consumer`, `api`, and `mcp` subcommands.

The metadata under `v0.6.2/` records the published release source revision and
the approved recovery capture revision. The API gate archives that immutable
capture revision, then builds and dumps both the approved and current public
products with the same Swift toolchain selected for the job. The digester target,
language version, modules, and canonicalization are therefore identical on both
sides of every comparison even when the rolling runner image changes.

Changing the approved capture revision still requires one reviewed PR that owns
the contract rationale and acceptance history. A missing revision, a source that
the selected toolchain cannot build, or a canonical API difference fails loudly.
