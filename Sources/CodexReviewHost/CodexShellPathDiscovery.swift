import Darwin
import Foundation

package struct CodexShellPathDiscovery: Sendable {
    package enum Outcome: Equatable, Sendable {
        case output(String)
        case failed(String)
        case timedOut
    }

    private let operation: @Sendable (URL, [String: String]) async -> Outcome

    package init(
        operation: @escaping @Sendable (URL, [String: String]) async -> Outcome
    ) {
        self.operation = operation
    }

    package func discover(
        shellURL: URL,
        environment: [String: String]
    ) async -> Outcome {
        await operation(shellURL, environment)
    }

    package static func live(timeout: Duration = .seconds(1)) -> Self {
        .init { shellURL, environment in
            await Task.detached(priority: .utility) {
                ShellProbe.run(
                    shellURL: shellURL,
                    environment: environment,
                    timeout: timeout
                )
            }.value
        }
    }
}

enum CodexShellProbeMarkers {
    static let begin = "__CODEX_REVIEW_SHELL_PATH_BEGIN__"
    static let end = "__CODEX_REVIEW_SHELL_PATH_END__"
}

private enum ShellProbe {
    static let command = "printf '%s\\n' '\(CodexShellProbeMarkers.begin)'; command -v codex || :; printf '%s\\n' '\(CodexShellProbeMarkers.end)'"
    private static let terminationGrace: Duration = .milliseconds(100)

    static func run(
        shellURL: URL,
        environment: [String: String],
        timeout: Duration
    ) -> CodexShellPathDiscovery.Outcome {
        guard let arguments = arguments(for: shellURL) else {
            return .failed("unsupported shell")
        }

        let launch: ShellProbeProcess.Launch
        do {
            launch = try ShellProbeProcess.launch(
                executableURL: shellURL,
                arguments: arguments,
                environment: environment
            )
        } catch {
            return .failed(error.localizedDescription)
        }
        let collector = BoundedPipeCollector(fileHandle: launch.stdout.fileHandleForReading)
        collector.start()

        guard let status = launch.process.wait(timeout: timeout) else {
            launch.process.terminateProcessGroup(grace: terminationGrace)
            _ = launch.process.wait(timeout: terminationGrace)
            _ = collector.stop()
            return .timedOut
        }

        // Startup files can leave background work behind after the shell exits.
        // The probe owns the process group and never transfers those children.
        launch.process.terminateProcessGroup(grace: terminationGrace)
        collector.waitForEnd(timeout: terminationGrace.timeInterval)
        let data = collector.stop()
        guard status == 0 else {
            return .failed("shell exited with wait status \(status)")
        }
        return .output(String(decoding: data, as: UTF8.self))
    }

    private static func arguments(for shellURL: URL) -> [String]? {
        switch shellURL.lastPathComponent {
        case "zsh", "bash":
            // A login and interactive shell matches the startup files that commonly
            // install version-manager and user-bin PATH entries in Terminal.
            return ["-l", "-i", "-c", command]
        default:
            return nil
        }
    }
}

private final class ShellProbeProcess: @unchecked Sendable {
    struct Launch {
        var process: ShellProbeProcess
        var stdout: Pipe
    }

    private let processIdentifier: pid_t
    private let completion = DispatchSemaphore(value: 0)
    private let statusLock = NSLock()
    private var waitStatus: Int32?

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            var result: pid_t
            repeat {
                result = waitpid(processIdentifier, &status, 0)
            } while result == -1 && errno == EINTR
            statusLock.withLock {
                waitStatus = result == processIdentifier ? status : -1
            }
            completion.signal()
        }
    }

    static func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> Launch {
        let stdout = Pipe()
        let nullDescriptor = Darwin.open("/dev/null", O_RDWR)
        guard nullDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(nullDescriptor) }
        var duplicatedDescriptors: [Int32] = []
        defer { duplicatedDescriptors.forEach { Darwin.close($0) } }
        let stdoutDescriptor = try childSourceDescriptor(
            stdout.fileHandleForWriting.fileDescriptor,
            duplicatedDescriptors: &duplicatedDescriptors
        )
        let childNullDescriptor = try childSourceDescriptor(
            nullDescriptor,
            duplicatedDescriptors: &duplicatedDescriptors
        )
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try check(posix_spawn_file_actions_init(&fileActions))
        try check(posix_spawnattr_init(&attributes))
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            childNullDescriptor,
            STDIN_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            stdoutDescriptor,
            STDOUT_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            childNullDescriptor,
            STDERR_FILENO
        ))
        let ownedDescriptors = Set([
            childNullDescriptor,
            stdout.fileHandleForReading.fileDescriptor,
            stdoutDescriptor,
        ]).filter { $0 > STDERR_FILENO }
        for fileDescriptor in ownedDescriptors {
            try check(posix_spawn_file_actions_addclose(&fileActions, fileDescriptor))
        }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))

        let executablePath = executableURL.path
        let argv = [executablePath] + arguments
        let envp = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var processIdentifier = pid_t()
        let result = try executablePath.withCString { executablePointer in
            try withCStringArray(argv) { argvPointers in
                try withCStringArray(envp) { envPointers in
                    posix_spawn(
                        &processIdentifier,
                        executablePointer,
                        &fileActions,
                        &attributes,
                        argvPointers,
                        envPointers
                    )
                }
            }
        }
        guard result == 0 else {
            try? stdout.fileHandleForWriting.close()
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
        try? stdout.fileHandleForWriting.close()
        return .init(process: .init(processIdentifier: processIdentifier), stdout: stdout)
    }

    func wait(timeout: Duration) -> Int32? {
        if let status = statusLock.withLock({ waitStatus }) {
            return status
        }
        guard completion.wait(timeout: .now() + timeout.timeInterval) == .success else {
            return nil
        }
        return statusLock.withLock { waitStatus }
    }

    func terminateProcessGroup(grace: Duration) {
        guard processGroupExists else { return }
        _ = Darwin.kill(-processIdentifier, SIGTERM)
        guard waitForEmptyProcessGroup(timeout: grace) == false else { return }
        _ = Darwin.kill(-processIdentifier, SIGKILL)
        _ = Darwin.kill(processIdentifier, SIGKILL)
        _ = waitForEmptyProcessGroup(timeout: grace)
    }

    private var processGroupExists: Bool {
        if Darwin.kill(-processIdentifier, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func waitForEmptyProcessGroup(timeout: Duration) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while processGroupExists {
            if clock.now >= deadline { return false }
            usleep(5_000)
        }
        return true
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
    }

    private static func childSourceDescriptor(
        _ descriptor: Int32,
        duplicatedDescriptors: inout [Int32]
    ) throws -> Int32 {
        guard descriptor <= STDERR_FILENO else { return descriptor }
        // Spawn actions run in order. Keep a source out of the stdio range so an
        // earlier dup2 or a later close cannot clobber another action's source.
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard duplicate >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        duplicatedDescriptors.append(duplicate)
        return duplicate
    }

    private static func withCStringArray<R>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> R
    ) throws -> R {
        let pointers = try strings.map { string -> UnsafeMutablePointer<CChar> in
            guard let pointer = strdup(string) else { throw POSIXError(.ENOMEM) }
            return pointer
        }
        defer { pointers.forEach { free($0) } }
        var optionalPointers = pointers.map(Optional.some) + [nil]
        return try optionalPointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress)
        }
    }
}

private final class BoundedPipeCollector: @unchecked Sendable {
    private static let byteLimit = 64 * 1024

    private let fileHandle: FileHandle
    private let lock = NSLock()
    private let reachedEnd = DispatchSemaphore(value: 0)
    private var data = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func start() {
        fileHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let available = handle.availableData
            guard available.isEmpty == false else {
                reachedEnd.signal()
                return
            }
            lock.withLock {
                let remaining = Self.byteLimit - data.count
                if remaining > 0 {
                    data.append(available.prefix(remaining))
                }
            }
        }
    }

    func waitForEnd(timeout: DispatchTimeInterval) {
        _ = reachedEnd.wait(timeout: .now() + timeout)
    }

    func stop() -> Data {
        fileHandle.readabilityHandler = nil
        return lock.withLock { data }
    }
}

private extension Duration {
    var timeInterval: DispatchTimeInterval {
        guard self > .zero else { return .nanoseconds(0) }
        let components = self.components
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        let nanoseconds = min(999_999_999, attoseconds / 1_000_000_000)
        if seconds > Int64(Int.max / 1_000_000_000) {
            return .nanoseconds(Int.max)
        }
        return .nanoseconds(Int(seconds) * 1_000_000_000 + Int(nanoseconds))
    }
}
