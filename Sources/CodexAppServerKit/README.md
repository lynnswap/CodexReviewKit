# CodexAppServerKit

CodexAppServerKit is a Swift library for working with a local
`codex app-server` process from macOS apps and tools.

The package hides JSON-RPC framing and app-server DTOs behind Swift domain
types. Callers work with an app-server container, sessions, prompts,
typed turn outcomes, transcript items, models, accounts, and login handles.

## Container

Create one `CodexAppServer` for the lifetime of the app-server connection:

```swift
import CodexAppServerKit

let appServer = try await CodexAppServer()
let thread = try await appServer.startThread(in: workspaceURL)

let outcome = try await thread.respond(to: "Review this workspace.")
if case .completed(let response) = outcome {
    print(response.transcript.finalAnswer ?? "")
}

await appServer.close()
```

`CodexAppServer()` uses the local `codex` executable over stdio. It performs
`initialize` / `initialized`, manages the process transport, routes
notifications, retries app-server overload responses, and preserves schema-new
notifications as unknown domain events.

Use the root-bound connection sequence for diagnostics and the single typed
termination reason:

```swift
let connectionEvents = await appServer.connectionEvents()
for await event in connectionEvents {
    switch event {
    case .warning(let diagnostic):
        print(diagnostic.message)
    case .retrying(let retry):
        print("Retrying \(retry.method), attempt \(retry.attempt)")
    case .deprecation(let notice):
        print(notice.summary)
    case .unknown(let notification):
        print("Future notification: \(notification.method)")
    case .terminated(let reason):
        print("Connection ended: \(reason)")
    }
}
```

The sequence does not retain the app-server connection. Each subscriber keeps
the newest 32 pending diagnostics; the terminal event supersedes pending
diagnostics and is the only event replayed to a late subscriber.

## Configuration

`CodexAppServer.Configuration` owns the container identity and local-process
runtime settings. The default local process resolves Codex home from
`CODEX_HOME`, then `HOME/.codex` on macOS command-line runs, then Application
Support for container-style environments. Pass `localProcess.codexHomeURL` when
an app wants an isolated runtime directory.

```swift
let configuration = CodexAppServer.Configuration(
    localProcess: .init(
        codexHomeURL: appSupportURL.appendingPathComponent("Codex", isDirectory: true)
    )
)
let appServer = try await CodexAppServer(configuration: configuration)
```

Install a typed server-request handler when the host needs to answer approvals,
user-input prompts, dynamic tool calls, or provider requests. Delegate request
kinds the host does not override to the built-in policy:

```swift
let configuration = CodexAppServer.Configuration(
    serverRequestHandler: { request in
        switch request {
        case .commandExecutionApproval:
            return .approval(.accept)
        case .userInput(let prompt):
            return .userInput(.init(answers: prompt.questions.reduce(into: [:]) {
                $0[$1.id] = .init(answers: [])
            }))
        default:
            return try await CodexAppServer.Configuration
                .defaultServerRequestHandler(request: request)
        }
    }
)
```

## Threads

`CodexThread` is the long-lived session handle for a Codex conversation in a workspace. Use `respond` to wait for an exhaustive terminal outcome.

```swift
let thread = try await appServer.startThread(
    in: workspaceURL,
    instructions: .init(developer: "Keep responses concise."),
    options: .init(model: "gpt-5", approvalMode: .autoReview)
)

let outcome = try await thread.respond {
    "Run the checks."
    "Focus on failing tests."
}
```

Thread management is exposed without requiring raw request DTOs:

```swift
let snapshot = try await thread.read(includeTurns: true)
try await thread.rename(to: "Release review")
try await thread.compact()
try await thread.archive()
let restored = try await thread.unarchive()
try await thread.delete()
```

## Package-Internal Streaming

`streamResponse` and the derived event sequences are package-level implementation
details used by DataKit and package tests. Public consumers use `respond`, or a
`CodexReviewSession` returned from `startReview`.

```swift
let stream = try await thread.streamResponse(to: "Summarize the changes.")

for try await snapshot in stream {
    render(snapshot.transcript.items)
}

let response = try await stream.collect()
```

Codex also supports explicit cancellation for an in-flight response. App-server
has real `turn/steer` and `turn/interrupt` control paths, so
`CodexResponseStream` exposes them directly:

```swift
let stream = try await thread.streamResponse(to: "Run the slow checks.")
try await stream.steer(with: "Prefer the smallest fix.")
try await stream.cancel()
```

Cancelling a task that awaits `stream.collect()` only stops that local
consumer. Explicit `stream.cancel()` owns the server-side interrupt.

Use `steer(with:)` when new input should modify the current turn. Start a
follow-up from the reusable `CodexThread` handle; terminal response handles
release their connection lease and do not start another generation.

It also exposes reasoning controls with domain values instead of raw strings:

```swift
let outcome = try await thread.respond(
    to: "Find the risky part of this change.",
    options: .init(
        effort: .high,
        summary: .detailed,
        personality: .pragmatic
    )
)

if case .completed(let response) = outcome {
    print(response.usage?.reasoningOutputTokens ?? 0)
}
```

Structured final answers can be constrained with a JSON schema:

```swift
let outcome = try await thread.respond(
    to: "Summarize the change as JSON.",
    options: .init(outputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "summary": .object(["type": .string("string")]),
            "risk": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("summary"), .string("risk")]),
    ]))
)
```

The package-internal thread handle also exposes async sequences for chat,
transcript updates, and log-style consumers.

```swift
for try await message in thread.messages {
    print(message.text)
}
```

```swift
for try await transcript in thread.transcriptUpdates {
    render(transcript.items)
}
```

```swift
for try await entry in thread.logEntries {
    switch entry {
    case .reasoningDelta(let delta, _):
        renderReasoningDelta(delta)
    case .itemStarted(let item, _), .itemUpdated(let item, _), .itemCompleted(let item, _):
        switch item.content {
        case .message(let message):
            renderMessage(message)
        case .reasoning(let reasoning):
            renderReasoning(summary: reasoning.summary, content: reasoning.content)
        case .command(let command):
            renderCommand(command.command, output: command.output)
        case .toolCall(let tool):
            renderToolCall(tool.name, result: tool.result, error: tool.error)
        case .fileChange(let fileChange):
            renderFileChange(fileChange.path, output: fileChange.output)
        default:
            break
        }
    case .messageDelta(let delta, _, _):
        renderMessageDelta(delta.text)
    default:
        break
    }
}
```

`CodexThread.events` is the full thread event stream. It includes turn
lifecycle, item lifecycle, message deltas, token usage, thread status, and
unknown notifications:

```swift
for try await event in thread.events {
    switch event {
    case .reasoningDelta(let delta, _):
        renderReasoningDelta(delta)
    case .tokenUsageUpdated(let usage, _):
        updateUsage(usage.totalTokens)
    case .unknown(let raw):
        logUnknownNotification(raw.method)
    default:
        break
    }
}
```

The stream represents the thread's current generation, not an append-only
connection history. A generation is registered before a scoped request is
written and becomes current only after its response is accepted; attempts that
fail or cancel before an accepted response leave the previous generation
intact. Each subscriber has a
bounded 256-event channel. A slow subscriber receives an authoritative turn
snapshot plus the newest usage/status and bounded unknown diagnostics when its
incremental queue overflows. Terminal and `thread/closed` events are never
dropped, and cancelling one iterator synchronously removes only that
subscriber.

This lets review clients build logs from
CodexAppServerKit domain events instead of parsing JSON-RPC notifications or
string logs directly.

Known `CodexThreadItem` values keep their high-level `content` projection and
the original `rawPayload`. Use the raw payload when a product needs
full-fidelity rendering for app-server fields that the current Kit version does
not yet model directly.

## Reviews

`review/start` is part of the app-server surface, so CodexAppServerKit exposes
it as a high-level `CodexAppServer` operation and as a lower-level thread
operation for callers that already own a thread. App-server does not expose a
separate review transport stream. A review session owns the source, active
review-thread, and turn identities and exposes one typed terminal outcome.

```swift
let review = try await appServer.startReview(
    in: workspaceURL,
    target: .baseBranch("main"),
    options: .init(model: "gpt-5")
)

let outcome = try await review.collect()
if case .completed(let response) = outcome {
    print(response.transcript.reviewOutputText ?? "")
}
```

Use `CodexThread.startReview` when a thread owner is already explicit:

```swift
let thread = try await appServer.startThread(in: workspaceURL)
let review = try await thread.startReview(target: .uncommittedChanges)
```

Review targets are Swift domain values:

```swift
try await appServer.startReview(in: workspaceURL, target: .uncommittedChanges)
try await appServer.startReview(in: workspaceURL, target: .commit(sha: sha, title: title))
try await appServer.startReview(in: workspaceURL, target: .custom(instructions: instructions))
```

Review output is exposed as `CodexTranscript.reviewOutputText` from the
`exitedReviewMode` item. Incremental review transport sequences stay inside the
package; apps that render live thread content use CodexDataKit's context-owned
chat observation instead of building a second review model graph.

`terminalOutcomeIfKnown()` is a nonwaiting read of the same review-generation
state used by `collect()`. It returns `nil` while the turn is live, never sends a
request, and surfaces a committed connection termination as an error. This is
primarily useful to arbitrate a caller-cancellation race without starting a
second collector.

`CodexReviewSession` also owns the app-server lifecycle identity for a review.
Use `sourceThreadID`, `activeTurnThreadID`, `associatedThreadIDs`, and
`cleanupThreadIDs` when a host app needs to track source, detached review, and
cleanup ownership without keeping its own app-server dictionaries.

```swift
let identity = review.identity
persist(identity)

let restored = try await appServer.resumeReview(identity)
let cancellation = try await restored.cancel()
noteActiveTurnThread(cancellation.threadID)
```

`CodexReviewIdentity` is a `Codable` Swift value containing only CodexKit
identity: source thread, review turn, optional detached review thread, and
active review thread model when known. It is intended for persisted app-server
review runs and does not depend on any higher-level review domain model.

`CodexAppServer` also owns app-server review restart and cleanup lifecycle
state. A host that needs to interrupt and restart a review can prepare a
transient token, restart from it, then perform cleanup without tracking
detached review thread IDs itself:

```swift
let token = try await appServer.prepareReviewRestart(identity)
let restarted = try await appServer.restartPreparedReview(
    token,
    target: .baseBranch("main"),
    delivery: .detached
)
let cleanup = await appServer.cleanupReview(restarted.identity)
if cleanup.succeeded == false {
    persistForLaterCleanup(cleanup.attemptedThreadIDs)
}
```

Cleanup returns every attempted thread ID and its ordered failures. When any
deletion fails, identities retained by restart preparation stay registered so
the same app-server generation can retry without losing cleanup ownership.

Preparation and restart are owned by one process-local coordinator. Concurrent
restart calls with the same token, target, delivery, and thread options join one
shared operation; a cancelled waiter does not cancel that operation. A token
allows at most two restart invocations, and the deprecated rollback request is
sent successfully at most once.

When a host stops a run before consuming its prepared token, invalidate it and
take ownership of every identity retained for that source thread:

```swift
let retained = await appServer.discardPreparedReviewRestart(token)
persistForLaterCleanup(retained)
```

Runtime owners use `discardAllPreparedReviewRestarts()` before closing the
app-server connection. It waits for in-flight preparation and restart work,
interrupts any replacement session that arrives after invalidation, and returns
an ordered identity list for each source thread. This is a terminal close of
restart preparation for that `CodexAppServer` instance. Neither discard
operation deletes review threads; the caller decides when durable ownership
permits final cleanup.

## Responses

`CodexThread.respond` and `CodexReviewSession.collect` return
`CodexTurnOutcome`: `.completed`, `.interrupted`, `.failed`, or
`.invalidTerminalStatus`. Every case carries a `CodexResponse`; failed turns
also carry a non-optional `CodexTurnError`. Caller cancellation throws
`CancellationError` and is not a terminal outcome.

`CodexResponse` carries transcript, token usage, timing, and `turnID`.

Final answers are derived from assistant messages whose phase is
`.finalAnswer`. If no final-answer phase is present, the last normal assistant
message is used as a fallback.

## Prompts

`CodexPrompt` accepts text and structured parts:

```swift
let prompt: CodexPrompt = .init(parts: [
    .text("Explain this screenshot."),
    .localImage(screenshotURL),
    .mention(name: "repo", path: workspaceURL),
])
```

String literals are supported for simple prompts:

```swift
try await thread.respond(to: "What changed?")
```

For dynamic prompts, use the result-builder initializer or the builder overloads
on `respond` and the package-level `streamResponse`:

```swift
let response = try await thread.respond {
    "Explain this screenshot."
    CodexPrompt.Part.localImage(screenshotURL)
    if includeRepository {
        CodexPrompt.Part.mention(name: "repo", path: workspaceURL)
    }
}
```

## Models, Account, And Login

```swift
let models = try await appServer.models()
let account = try await appServer.account(refreshToken: true)
let configuration = try await appServer.configuration()
let rateLimits = try await appServer.rateLimits()
```

Update configuration through a patch so `nil` can mean "clear this setting"
without making every field optional update state visible in call sites:

```swift
var patch = CodexConfigurationPatch()
patch.setReviewModel("gpt-5-codex-review")
patch.setReasoningEffort(.high)
patch.setServiceTier(nil)
try await appServer.updateConfiguration(patch)
```

ChatGPT browser login returns a typed handle:

```swift
let handle = try await appServer.loginChatGPT()
openInBrowser(handle.authenticationURL)
let outcome = try await handle.result()
```

API-key login is an immediate credential replacement owned by the app-server:

```swift
func configureAuthentication(
    on appServer: CodexAppServer,
    apiKey: String
) async throws {
    try await appServer.login(apiKey: apiKey)
}
```

A successful return means the app-server stored and reloaded the key in its
configured Codex home. Login does not make a remote API request, so it does not
prove that the key will be accepted by the API. Empty keys and keys with leading
or trailing whitespace fail before a request is sent.

Caller cancellation before write acceptance sends nothing. Once the request is
written, cancellation is deferred until its correlated response is known. A
connection loss, deadline, or malformed response after write acceptance throws
`CodexAppServerError.authenticationOutcomeUnknown`; reconcile the authoritative
account state before retrying.

## Testing

Use `CodexAppServerKitTesting` to exercise `CodexAppServer` without launching a
real `codex app-server` process. The test runtime uses an in-memory transport,
enqueues the startup `initialize` response, records requests, and lets tests
emit server notifications explicitly.

```swift
import CodexAppServerKit
import CodexAppServerKitTesting
import Foundation
import Testing

@Test func readsConfiguration() async throws {
    let runtime = try await CodexAppServerTestRuntime.start()
    let layer = try CodexAppServerTestConfigurationLayerMetadata(
        source: .user(
            file: URL(fileURLWithPath: "/tmp/codex/config.toml"),
            profile: nil
        ),
        version: "test-config-v1"
    )
    let fixture = try CodexAppServerTestConfigurationReadResult(
        configuration: .init(model: "gpt-5-codex"),
        origins: ["model": layer],
        layers: [try .init(
            metadata: layer,
            configuration: .object(["model": .string("gpt-5-codex")])
        )]
    )
    try await runtime.transport.enqueueConfiguration(fixture)

    let configuration = try await runtime.server.configuration()

    #expect(configuration == fixture.configuration)
    #expect(await runtime.transport.recordedRequests(for: .configurationRead).count == 1)
    await runtime.close()
}
```

Tests can hold a typed operation with
`CodexAppServerTestGate` and release it explicitly. This avoids depending on
sleep duration or repeated `Task.yield()` calls.

```swift
let gate = CodexAppServerTestGate()
await runtime.transport.holdNext(.configurationRead, gate: gate)
try await runtime.transport.enqueueConfiguration(fixture)

let readTask = Task {
    try await runtime.server.configuration()
}

await runtime.transport.waitForRequest(.configurationRead)
await gate.open()
_ = try await readTask.value
```

## Boundary

Public users should not need to import or call JSON-RPC or `AppServerAPI`
request DTOs. Those remain package-level implementation details.

The public boundary is:

- `CodexAppServer`
- `CodexThreadID`
- `CodexTurnID`
- `CodexThread`
- `CodexReviewTarget`
- `CodexReviewSession`
- `CodexReviewIdentity`
- `CodexReviewCleanupFailure`
- `CodexReviewCleanupResult`
- `CodexReviewRestartToken`
- `CodexTurnSnapshot`
- `CodexTurnStatus`
- `CodexThreadStatus`
- `CodexTurnOutcome`
- `CodexFailedTurn`
- `CodexTurnError`
- `CodexErrorInfo`
- `CodexResponse`
- `CodexAppServerError`
- `CodexRequestFailure`
- `CodexServerError`
- `CodexGenerationOptions`
- `CodexPrompt`
- `CodexTranscript`
- `CodexThreadItem`
- `CodexModel`
- `CodexAccount`
- `CodexAccountEvent`
- `CodexAPIKeyValidationFailure`
- `CodexAuthenticationOutcomeUnknownReason`
- `CodexLoginHandle`

Unknown notifications and unknown item kinds are preserved so clients can keep
running when app-server adds new schema.
