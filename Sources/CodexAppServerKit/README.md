# CodexAppServerKit

CodexAppServerKit is a Swift library for working with a local
`codex app-server` process from macOS apps and tools.

The package hides JSON-RPC framing and app-server DTOs behind Swift domain
types. Callers work with an app-server container, sessions, prompts,
responses, response streams, transcript items, log entries, models, accounts,
and login handles.

## Container

Create one `CodexAppServer` for the lifetime of the app-server connection:

```swift
import CodexAppServerKit

let appServer = try await CodexAppServer()
let thread = try await appServer.startThread(in: workspaceURL)

let response = try await thread.respond(to: "Review this workspace.")
print(response.finalAnswer ?? "")

await appServer.close()
```

`CodexAppServer()` uses the local `codex` executable over stdio. It performs
`initialize` / `initialized`, manages the process transport, routes
notifications, retries app-server overload responses, and preserves schema-new
notifications as unknown domain events.

## Threads

`CodexThread` is the long-lived session handle for a Codex conversation in a
workspace. It mirrors the Foundation Models session style: use `respond` for a
single final response, or `streamResponse` when the UI needs partial snapshots.

```swift
let thread = try await appServer.startThread(
    in: workspaceURL,
    instructions: .init(developer: "Keep responses concise."),
    options: .init(model: "gpt-5", approvalMode: .autoReview)
)

let response = try await thread.respond {
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
try await thread.rollback(turnCount: 1)
try await thread.delete()
```

## Streaming

Use `streamResponse` for the Foundation Models-style streaming surface. The
stream yields snapshots of the accumulated response state and can be collected
into the final `CodexResponse`.

```swift
let stream = try await thread.streamResponse(to: "Summarize the changes.")

for try await snapshot in stream {
    render(snapshot.transcript.items)
}

let response = try await stream.collect()
```

Codex also supports explicit interruption for an in-flight response. Foundation
Models normally relies on task cancellation, but app-server has real
`turn/steer` and `turn/interrupt` control paths, so `CodexResponseStream`
exposes them directly:

```swift
let stream = try await thread.streamResponse(to: "Run the slow checks.")
try await stream.steer(with: "Prefer the smallest fix.")
try await stream.interrupt()
```

If the task awaiting `stream.collect()` is cancelled, the stream also sends the
same interrupt request to app-server.

When a UI needs to accept another prompt while a response is in flight, submit
it with an explicit follow-up mode:

```swift
let next = try await stream.submit(
    "Now update the tests.",
    mode: .queueAfterCurrentResponse
)

let urgent = try await stream.submit(
    "Stop and try the shorter path.",
    mode: .interruptCurrentResponse
)
```

Use `steer(with:)` when the new input should modify the current turn.
`.queueAfterCurrentResponse` waits for the current response to finish before
starting the next turn. `.interruptCurrentResponse` sends `turn/interrupt`,
waits for app-server's terminal event, and then starts the next turn in the
same thread.

`CodexGenerationOptions` includes `transcriptErrorHandlingPolicy`, matching the
Foundation Models policy shape:

```swift
let stream = try await thread.streamResponse(
    to: "Try the risky change.",
    options: .init(transcriptErrorHandlingPolicy: .revertTranscript)
)
```

Threads also expose async sequences for chat, transcript updates, and log-style
consumers. This is the API surface intended for higher-level products that need
to render Codex output continuously outside a single response stream.

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
    switch entry.item?.content {
    case .message(let message):
        renderMessage(message)
    case .command(let command):
        renderCommand(command.command, output: command.output)
    case .toolCall(let tool):
        renderToolCall(tool.name, result: tool.result, error: tool.error)
    case .fileChange(let fileChange):
        renderFileChange(fileChange.path, output: fileChange.output)
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
    case .tokenUsageUpdated(let usage, _):
        updateUsage(usage.totalTokens)
    case .unknown(let raw):
        logUnknownNotification(raw.method)
    default:
        break
    }
}
```

This lets review clients build logs from
CodexAppServerKit domain events instead of parsing JSON-RPC notifications or
string logs directly.

Known `CodexThreadItem` values keep their high-level `content` projection and
the original `rawPayload`. Use the raw payload when a product needs
full-fidelity rendering for app-server fields that the current Kit version does
not yet model directly.

## Responses

`CodexResponse` is the final result from `respond` or `ResponseStream.collect()`.
It carries the final answer, transcript, status, token usage, and `turnID`.

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
on `respond` and `streamResponse`:

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

Login flows return typed handles:

```swift
let handle = try await appServer.loginChatGPT(callbackURLScheme: "myapp")
try await appServer.completeLogin(handle, callbackURL: callbackURL)
```

API key and device-code login are also available:

```swift
try await appServer.loginAPIKey(apiKey)
let deviceCode = try await appServer.loginChatGPTDeviceCode()
```

## Boundary

Public users should not need to import or call JSON-RPC or `AppServerAPI`
request DTOs. Those remain package-level implementation details.

The public boundary is:

- `CodexAppServer`
- `CodexThreadID`
- `CodexTurnID`
- `CodexThread`
- `CodexResponse`
- `CodexResponseStream`
- `CodexGenerationOptions`
- `CodexTranscriptErrorHandlingPolicy`
- `CodexPrompt`
- `CodexTranscript`
- `CodexThreadItem`
- `CodexThreadEvent`
- `CodexModel`
- `CodexAccount`
- `CodexLoginHandle`

Unknown notifications and unknown item kinds are preserved so clients can keep
running when app-server adds new schema.
