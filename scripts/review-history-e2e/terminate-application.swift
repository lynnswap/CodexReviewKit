import AppKit
import Foundation

private enum ExitCode {
    static let usage: Int32 = 64
    static let unavailable: Int32 = 69
    static let timeout: Int32 = 70
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

guard CommandLine.arguments.count == 4,
      let processIdentifier = Int32(CommandLine.arguments[1]),
      let timeoutSeconds = TimeInterval(CommandLine.arguments[3]),
      timeoutSeconds > 0
else {
    fail(
        "Usage: terminate-application <pid> <expected-executable-path> <timeout-seconds>",
        code: ExitCode.usage
    )
}

let expectedExecutableURL = URL(fileURLWithPath: CommandLine.arguments[2])
    .standardizedFileURL
    .resolvingSymlinksInPath()

guard let application = NSRunningApplication(
    processIdentifier: processIdentifier
) else {
    fail(
        "No running macOS application owns PID \(processIdentifier).",
        code: ExitCode.unavailable
    )
}

guard let executableURL = application.executableURL?
    .standardizedFileURL
    .resolvingSymlinksInPath(),
      executableURL == expectedExecutableURL
else {
    fail(
        "PID \(processIdentifier) does not own the expected application executable.",
        code: ExitCode.unavailable
    )
}

guard application.terminate() else {
    fail(
        "NSRunningApplication rejected termination for PID \(processIdentifier).",
        code: ExitCode.unavailable
    )
}

let deadline = Date().addingTimeInterval(timeoutSeconds)
while application.isTerminated == false, Date() < deadline {
    RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.1)))
}

guard application.isTerminated else {
    fail(
        "Application PID \(processIdentifier) did not terminate within \(timeoutSeconds) seconds.",
        code: ExitCode.timeout
    )
}
