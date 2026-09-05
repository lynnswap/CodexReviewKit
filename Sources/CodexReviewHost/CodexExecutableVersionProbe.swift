import Darwin
import Foundation

package struct CodexExecutableVersionProbe: Sendable {
    package enum Failure: Error, Equatable, Sendable {
        case launchFailed
        case outputReadFailed
        case timedOut
        case unsuccessfulExit(Int32)
        case outputTooLarge

        package var reason: String {
            switch self {
            case .launchFailed:
                "version probe could not be launched"
            case .outputReadFailed:
                "version probe output could not be read"
            case .timedOut:
                "version probe timed out"
            case .unsuccessfulExit(let status):
                "version probe exited with status \(status)"
            case .outputTooLarge:
                "version probe output exceeded the limit"
            }
        }
    }

    private let operation: @Sendable (
        URL,
        [String: String]
    ) async -> Result<String, Failure>

    package init(
        operation: @escaping @Sendable (
            URL,
            [String: String]
        ) async -> Result<String, Failure>
    ) {
        self.operation = operation
    }

    package func callAsFunction(
        _ executableURL: URL,
        environment: [String: String]
    ) async -> Result<String, Failure> {
        await operation(executableURL, environment)
    }

    package static let live = live(timeout: .seconds(2))

    package static func live(timeout: Duration) -> Self {
        CodexExecutableVersionProbe { executableURL, environment in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runLive(
                        executableURL: executableURL,
                        environment: environment,
                        timeout: timeout
                    ))
                }
            }
        }
    }

    private static func runLive(
        executableURL: URL,
        environment: [String: String],
        timeout: Duration
    ) -> Result<String, Failure> {
        let process = Process()
        let outputPipe = Pipe()
        var output = BoundedOutput(limit: 4_096)
        let outputHandle = outputPipe.fileHandleForReading
        defer {
            try? outputHandle.close()
        }

        process.executableURL = executableURL
        process.arguments = ["--version"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForWriting.close()
            return .failure(.launchFailed)
        }
        try? outputPipe.fileHandleForWriting.close()

        let deadline = ContinuousClock.now + timeout
        var reachedEndOfOutput = false
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while ContinuousClock.now < deadline {
            var descriptor = pollfd(
                fd: outputHandle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, 10)
            if pollResult < 0 {
                guard errno == EINTR else {
                    if process.isRunning { terminate(process) }
                    return .failure(.outputReadFailed)
                }
                continue
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 {
                if process.isRunning { terminate(process) }
                return .failure(.outputReadFailed)
            }
            if pollResult > 0,
               descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                let byteCount = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor.fd, bytes.baseAddress, bytes.count)
                }
                if byteCount > 0 {
                    output.append(buffer, count: Int(byteCount))
                } else if byteCount == 0 {
                    reachedEndOfOutput = true
                } else if errno != EINTR && errno != EAGAIN {
                    if process.isRunning { terminate(process) }
                    return .failure(.outputReadFailed)
                }
            }
            if output.didExceedLimit {
                if process.isRunning { terminate(process) }
                return .failure(.outputTooLarge)
            }
            if process.isRunning == false && reachedEndOfOutput {
                break
            }
        }
        guard process.isRunning == false, reachedEndOfOutput else {
            if process.isRunning { terminate(process) }
            return .failure(.timedOut)
        }

        guard process.terminationStatus == 0 else {
            return .failure(.unsuccessfulExit(process.terminationStatus))
        }
        guard output.didExceedLimit == false else {
            return .failure(.outputTooLarge)
        }
        return .success(String(decoding: output.data, as: UTF8.self))
    }

    private static func terminate(_ process: Process) {
        process.terminate()
        let terminationDeadline = ContinuousClock.now + .milliseconds(250)
        while process.isRunning && ContinuousClock.now < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private struct BoundedOutput {
        let limit: Int
        private(set) var data = Data()
        private(set) var didExceedLimit = false

        init(limit: Int) {
            self.limit = limit
        }

        mutating func append(_ buffer: [UInt8], count: Int) {
            let available = max(0, limit - data.count)
            data.append(contentsOf: buffer.prefix(min(count, available)))
            if count > available {
                didExceedLimit = true
            }
        }
    }
}
