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
Updating this baseline requires an explicit accepted API change in
`Docs/recovery-design-2026-08-20.md`; the checker never rewrites it.
