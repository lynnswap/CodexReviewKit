# CodexReviewKit Architecture

CodexReviewKit provides ReviewMonitor, a native macOS app for running and
observing Codex review. The package is organized so the generic app-server
client, review-specific app-server behavior, semantic review events, observable
timeline state, UI rendering, and MCP responses each have a clear owner.

The important architectural invariant is that review progress flows in one
direction:

```text
raw app-server wire
  -> high-level app-server review stream
  -> domain review event
  -> observable review timeline
  -> UI / MCP / rendering / legacy log projections
```

Raw JSON-RPC notifications are an input boundary only. They must not become the
source of truth for ReviewMonitor UI, MCP responses, or legacy logs after they
have been normalized into high-level app-server review streams and converted
into domain events.

## Targets

This table describes intended ownership. Some names in this table are target
ownership names that may still be pending migration in `Package.swift`; do not
read them as a claim that every symbol has already moved.

| Target | Responsibility |
| --- | --- |
| `CodexAppServerKit` | App-server SDK: local `codex app-server` process transport, JSON-RPC client, typed request DTOs, app-server review notification schema, high-level review stream/session API, and Swift domain API for threads, turns, prompts, review sessions, models, accounts, and login. Raw review DTOs are not its public boundary. It has no Review, UI, or MCP dependencies |
| `CodexReviewKit` | Review semantic core, identifiers, kinds, runs, jobs, timeline, parsing, application store/use-case primitives, `CodexReviewStore`, `CodexReviewStoreBackend`, auth/settings/runtime product state, and legacy log compatibility projections. It has no app-server wire, UI, or MCP dependencies |
| `CodexReviewAppServer` | Adapter from `CodexAppServerKit` high-level `CodexReviewSession` review streams into `CodexReviewKit` backend events |
| `CodexReviewMCPServer` | MCP server and projection over the review core/store contract, internal MCP protocol request/response conversion, and Streamable HTTP endpoint. It has no UI or app-server backend dependency |
| `CodexUI` | Concrete AppKit UI and existing hosted SwiftUI views. SwiftUI views remain concrete UI here; there is no requirement to delete or rewrite them just to satisfy target ownership |
| `CodexReviewHost` | Runtime composition for ReviewMonitor |
| `ReviewMonitorRendering` | Domain timeline rendering helpers that do not know AppKit/SwiftUI or app-server wire |
| `ReviewUI` | Current concrete native monitor UI target while UI ownership names are still migrating |
| `CodexReviewTesting` | Deterministic fake backend, fake JSON-RPC transport, gates, manual clock |
| `TextTransitions` | UI text transition view support |

ReviewMonitor is the product entry point. The host target wires the concrete
runtime together; lower targets do not import the host.

`CodexReviewAppServerWire` exists today as a transitional raw decoder target.
It is not an intended ownership boundary. The intended owner for app-server
review notification schema and high-level review streams is
`CodexAppServerKit`; raw review DTOs should remain implementation details
behind that SDK boundary rather than becoming public ReviewMonitor API.

## Source Of Truth

`CodexReviewKit` owns the semantic timeline vocabulary. It defines the
review item kinds, timeline item content, and `ReviewDomainEvent` values that
describe review progress independently of any transport, UI, or MCP protocol.
Review parsing, store commands, backend contracts, and timeline mutation stay
in this target.

`CodexAppServerKit` owns the app-server connection and schema boundary. It
starts the local `codex app-server` process, performs JSON-RPC framing, sends
`initialize`/`initialized`, retries overload responses, preserves unknown
notifications, owns app-server review notification schema, and exposes
`CodexAppServer` plus high-level review session streams as the Swift-facing
API for threads, turns, prompts, review sessions, messages, transcripts, log
entries, models, accounts, and login flows. Raw review DTOs may exist as
internal implementation detail, but they are not the public API boundary. It
must not import Review, UI, or MCP targets.

`CodexReviewAppServerWire` is a current transitional decoder for raw app-server
review notification shapes. While it exists during migration, it must not be
treated as the intended owner of review wire schema or public API. The intended
direction is for `CodexAppServerKit` to provide the high-level review stream
boundary and keep raw DTOs out of ReviewMonitor-facing contracts.

`CodexReviewAppServer` owns the adapter from high-level app-server review
sessions into `CodexReviewKit` backend events. It consumes `CodexReviewSession`
values from `CodexAppServerKit` and hands application-facing review events to
the store backend. If current code still passes through
`CodexReviewAppServerWire`, that is a migration detail, not the ownership
model.

`ReviewTimeline` and application/store state are the observable source of truth
after conversion. UI views, rendering helpers, MCP server projections, and
legacy log support project from the timeline; they do not parse raw app-server
events and do not make string logs authoritative again.

Legacy log support exists for compatibility with older ReviewMonitor surfaces:

- `ReviewLogEntryTimelineProjection` rebuilds semantic timeline state from
  existing log entries during migration or compatibility paths.
- `ReviewTimelineLegacyLogProjection` derives legacy log entries from timeline
  items when old APIs need them.

Those projections are compatibility edges. New behavior should prefer domain
events and timeline state as the owner.

## Target Graph

```mermaid
flowchart TB
    subgraph Domain["CodexReviewKit domain layer"]
        DomainEvents["ReviewDomainEvent"]
        Timeline["ReviewTimeline"]
    end

    subgraph Application["CodexReviewKit application layer"]
        AppStore["ReviewStore"]
        Awaiter["ReviewObservationAwaiter"]
    end

    subgraph Product["CodexReviewKit product API"]
        PublicStore["CodexReviewStore"]
        LegacyProjection["Legacy log projections"]
    end

    subgraph Kit["CodexAppServerKit"]
        DomainAPI["CodexAppServer"]
        ReviewSession["CodexReviewSession"]
        Client["JSON-RPC client"]
        Process["codex app-server"]
    end

    subgraph AppServer["CodexReviewAppServer"]
        Runtime["Review runtime"]
    end

    subgraph MCP["MCP"]
        MCPServer["CodexReviewMCPServer"]
    end

    subgraph Monitor["Monitor surfaces"]
        Renderer["ReviewMonitorRendering"]
        UI["ReviewUI"]
    end

    subgraph Host["CodexReviewHost"]
        Composition["Composition root"]
    end

    ReviewSession --> Runtime
    Runtime --> DomainEvents
    DomainEvents --> Timeline
    Timeline --> AppStore
    Timeline --> PublicStore
    Timeline --> LegacyProjection
    Timeline --> MCPServer
    Timeline --> Renderer
    PublicStore --> UI
    Renderer --> UI
    DomainAPI --> Client
    ReviewSession --> Client
    Client --> Process
    Runtime --> PublicStore
    Composition --> Runtime
    Composition --> MCPServer
    Composition --> PublicStore
```

The diagram describes ownership direction, not every SwiftPM dependency. New
code should not move domain, application, rendering, UI, or MCP projection
responsibilities back into runtime owners.
`CodexReviewAppServerWire` is intentionally omitted from the intended ownership
graph because it is a current transitional decoder, not a target owner.

## Observation Ownership

ObservationBridge is a subscription primitive. It is not storage, cache, or a
source of truth.

- The observable owner keeps semantic state: domain timelines, application
  stores, and product stores.
- Subscription tokens live with the subscriber that created them. A view
  controller, awaiter, or driver that starts observation is responsible for
  cancelling its token when that owner ends.
- `ReviewObservationAwaiter` belongs in `CodexReviewKit` because it is a
  use-case-level awaiter over observable domain state.
- UI observation tokens are view/controller lifetime details. Any UI projection
  derived from observed state is transient and can be rebuilt from the timeline.
- MCP and rendering projections are value snapshots over timeline state. They
  must not retain ObservationBridge tokens or persist their projection as model
  state.

## CodexReviewKit

`CodexReviewKit` is the public product surface used by existing ReviewMonitor code.
It owns review commands, auth/settings/runtime state, network recovery policy,
diagnostics, and legacy store APIs through `CodexReviewStore`.

`CodexReviewStore` remains the command owner for `review_start`,
`review_await`, `review_read`, `review_list`, `review_cancel`, session close,
auth actions, and settings updates. It depends on domain timeline types and
application awaiters instead of owning app-server wire shapes.

`CodexReviewStoreBackend` is the dependency boundary below the store. Live,
preview, and test backends all implement that boundary; product state remains in
the store.

## App-Server Gateway

`CodexAppServerKit` treats raw JSON-RPC as the only live I/O boundary.

- One live `codex app-server` process maps to one shared connection.
- `initialize` and `initialized` run once per connection.
- `config/read`, `account/read`, login, model, thread, and turn methods are
  typed requests in the generic Kit boundary.
- The public Kit API is expressed as `CodexAppServer`, `CodexThreadID`,
  `CodexTurnID`, `CodexThread`, `CodexPrompt`, Foundation Models-style
  `respond` / `streamResponse` / `CodexResponseStream.collect()` calls,
  Codex-specific response stream controls, thread event streams, messages,
  transcript/log values, high-level review sessions such as
  `CodexReviewSession`, model values, account values, and login handles.
- App-server review notification schemas belong inside the Kit boundary. The
  public review surface should be a high-level review stream/session API, not
  raw notification DTOs.
- Same-thread mutating requests are serialized. `turn/interrupt` is the
  intentional control-path exception so an in-flight response can be stopped
  without waiting behind queued same-thread work.
- Different-thread requests may run concurrently.
- Notifications are routed by turn ID, early turn notifications are replayed to
  later consumers, and schema-new notifications are preserved as unknown domain
  events.
- Cancellation is represented by typed control/cleanup requests, not by closing
  the transport.

`CodexReviewAppServer` adapts high-level `CodexReviewSession` output into
ReviewMonitor backend events and adds ReviewMonitor-specific cleanup and
recovery on top of that generic boundary.

The intended ownership for review logs is that `CodexAppServerKit` supplies
generic app-server thread events, log entries, and high-level review session
events, while ReviewMonitor-specific targets adapt those values into
`ReviewDomainEvent`, `ReviewTimeline`, and legacy review log projections.

Fake and live tests use the same transport protocol.

## MCP Boundary

`CodexReviewMCPServer` knows MCP tool names, request arguments, response shape,
session headers, Streamable HTTP behavior, and MCP-facing value snapshots from
domain/product state. It calls store commands and projects the review timeline
into MCP tool response shape. It does not know Codex JSON-RPC details, does not
depend on the UI or app-server backend, and must not import ReviewUI, the
app-server runtime, or app-server wire DTOs.

ReviewMonitor owns the default Streamable HTTP endpoint at
`http://localhost:9417/mcp`. The HTTP boundary follows current MCP session
semantics: `initialize` creates an `MCP-Session-Id`, subsequent requests carry
that session header, responses are delivered as JSON or SSE as negotiated by the
client, and `DELETE` closes a session.

The public tool surface is:

- `review_start`
- `review_await`
- `review_read`
- `review_list`
- `review_cancel`

## Monitor UI Boundary

`ReviewUI` observes product/domain state and forwards user intent.

- Views and view controllers render observable state.
- User actions call store methods.
- UI rendering may use `ReviewMonitorRendering` helpers over `ReviewTimeline`.
- UI code must not import app-server runtime, app-server wire, or
  MCP server targets.
- UI tests cover layout, selection, rendering, accessibility-facing text, and
  user-intent forwarding.
- Review/auth/settings semantics are tested in lower target tests.

`ReviewMonitorRendering` is intentionally lower than UI. It can render domain
timeline values, but it must not import AppKit/SwiftUI UI, app-server, wire, or
MCP targets.

## Testing

Default tests are deterministic and do not start a live `codex app-server`.

| Test area | Uses | Verifies |
| --- | --- | --- |
| `CodexAppServerKitTests` | Fake JSON-RPC transport | Generic app-server handshake, request serialization, retry, notification routing, domain result aggregation, and high-level review stream behavior |
| `CodexReviewAppServerWireTests` | Raw notification JSON while the transitional decoder exists | Migration compatibility for decode/conversion behavior, not intended target ownership |
| `CodexReviewKitTests` | Domain timelines, ObservationBridge awaiters, and fake `CodexReviewStoreBackend` | Semantic timeline mutation, use-case observation behavior, review/auth/settings state machines, cancellation, result retention |
| `CodexReviewAppServerTests` | Fake app-server review sessions or transport as needed | Adapter behavior from high-level review sessions into backend events, cleanup, and recovery |
| `CodexReviewMCPServerTests` | Fake review store and domain timeline projections | MCP protocol conversion, response shape, and timeline projection snapshots |
| `CodexReviewHostTests` | Fake runtime dependencies | Composition, startup, shutdown |
| `ReviewUITests` | Preview/test monitor backend | Native UI behavior and user-intent forwarding |

Forbidden test patterns:

- Sleeping to wait for lifecycle progress when an explicit signal can be used.
- Enforcing architecture with string-scan or `ArchitectureFence`-style tests.
  Target ownership should be covered by contract and behavior tests at the
  relevant boundary.
- Inspecting fake-only storage as product behavior.
- Starting a live `codex app-server` in default CI tests.
- Testing behavior only because another implementation happened to behave
  differently.
- Parsing raw app-server wire or string logs from UI/MCP tests when a domain
  timeline or store projection can express the behavior.
