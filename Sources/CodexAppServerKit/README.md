# CodexAppServerKit

CodexAppServerKit is a Swift library for working with a local
`codex app-server` process from macOS apps and tools.

The package hides JSON-RPC framing and app-server DTOs behind Swift domain
types. Callers work with an app-server container, threads, turns, prompts,
messages, transcript items, log entries, models, accounts, and login handles.

## Container

Create one `CodexAppServer` for the lifetime of the app-server connection:

```swift
import CodexAppServerKit

let appServer = try await CodexAppServer()
let thread = try await appServer.startThread(in: workspaceURL)

let result = try await thread.respond(to: "Review this workspace.")
print(result.finalAnswer ?? "")

await appServer.close()
```

`CodexAppServer()` uses the local `codex` executable over stdio. It performs
`initialize` / `initialized`, manages the process transport, routes
notifications, retries app-server overload responses, and preserves schema-new
notifications as unknown domain events.

## Threads

`CodexThread` is the long-lived handle for a Codex conversation in a workspace.
It supports high-level commands:

```swift
let thread = try await appServer.startThread(
    in: workspaceURL,
    instructions: .init(developer: "Keep responses concise."),
    options: .init(model: "gpt-5", approvalMode: .autoReview)
)

let turn = try await thread.startTurn("Run the checks.")
try await turn.steer(with: "Focus on failing tests.")
let result = try await turn.result()
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

Threads expose async sequences for chat, transcript, and log-style consumers.
This is the API surface intended for higher-level products that need to render
Codex output continuously.

```swift
for try await message in thread.messages {
    print(message.text)
}
```

```swift
for try await transcript in thread.transcript {
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

This lets CodexReviewKit and similar clients build review logs from
CodexAppServerKit domain events instead of parsing JSON-RPC notifications or
string logs directly.

## Turns

`CodexTurn` is a handle for one in-flight turn. It has turn-scoped streams and
result aggregation:

```swift
let turn = try await thread.startTurn("Summarize the changes.")

for try await progress in turn.progress {
    render(progress.transcript)
}

let result = try await turn.result()
```

`CodexThread.respond(to:)` is the convenience form for starting a turn,
consuming its events, and returning the final `CodexTurnResult`.

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
- `CodexThread`
- `CodexTurn`
- `CodexPrompt`
- `CodexTranscript`
- `CodexThreadItem`
- `CodexThreadEvent`
- `CodexTurnEvent`
- `CodexTurnProgress`
- `CodexTurnResult`
- `CodexModel`
- `CodexAccount`
- `CodexLoginHandle`

Unknown notifications and unknown item kinds are preserved so clients can keep
running when app-server adds new schema.
