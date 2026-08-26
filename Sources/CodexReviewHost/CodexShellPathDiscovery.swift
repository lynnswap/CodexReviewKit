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
    private static let terminationGrace: Duration = .milliseconds(100)

    static func run(
        shellURL: URL,
        environment: [String: String],
        timeout: Duration
    ) -> CodexShellPathDiscovery.Outcome {
        guard let arguments = arguments(for: shellURL) else {
            return .failed("unsupported shell")
        }

        let process: ShellProbeProcess
        do {
            process = try ShellProbeProcess.launch(
                executableURL: shellURL,
                arguments: arguments,
                environment: environment
            )
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let status = process.wait(timeout: timeout) else {
            process.terminateProcessGroup(grace: terminationGrace)
            _ = process.wait(timeout: terminationGrace)
            _ = process.stopCollectingOutput()
            return .timedOut
        }

        // Startup files can leave background work behind after the shell exits.
        // The probe owns the process group and never transfers those children.
        process.terminateProcessGroup(grace: terminationGrace)
        process.waitForOutputEnd(timeout: terminationGrace.timeInterval)
        let data = process.stopCollectingOutput()
        guard status == 0 else {
            return .failed("shell exited with wait status \(status)")
        }
        return .output(String(decoding: data, as: UTF8.self))
    }

    private static func arguments(for shellURL: URL) -> [String]? {
        let lookup: String
        switch shellURL.lastPathComponent {
        case "zsh": lookup = "builtin whence -p codex || :"
        case "bash": lookup = "builtin type -P codex || :"
        default: return nil
        }
        // A login and interactive shell matches the startup files that commonly
        // install version-manager and user-bin PATH entries in Terminal. Keep
        // monitor mode off so startup background work remains in the process
        // group whose complete termination this probe owns.
        let command = "printf '\\n%s\\n' '\(CodexShellProbeMarkers.begin)'; \(lookup); printf '%s\\n' '\(CodexShellProbeMarkers.end)'"
        return ["-l", "-i", "+m", "-c", command]
    }
}

private struct PseudoTerminal {
    var primaryFileHandle: FileHandle
    var replicaDescriptor: Int32

    static func open() throws -> Self {
        var primaryDescriptor: Int32 = -1
        var replicaDescriptor: Int32 = -1
        var windowSize = winsize(
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        guard openpty(
            &primaryDescriptor,
            &replicaDescriptor,
            nil,
            nil,
            &windowSize
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return .init(
            primaryFileHandle: FileHandle(
                fileDescriptor: primaryDescriptor,
                closeOnDealloc: true
            ),
            replicaDescriptor: replicaDescriptor
        )
    }
}

private final class ShellProbeProcess: @unchecked Sendable {
    private let processIdentifier: pid_t
    private let outputCollector: BoundedOutputCollector
    private let completion = DispatchSemaphore(value: 0)
    private let statusLock = NSLock()
    private var waitStatus: Int32?

    private init(processIdentifier: pid_t, outputFileHandle: FileHandle) {
        self.processIdentifier = processIdentifier
        outputCollector = BoundedOutputCollector(fileHandle: outputFileHandle)
        outputCollector.start()
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
    ) throws -> ShellProbeProcess {
        let terminal = try PseudoTerminal.open()
        defer { Darwin.close(terminal.replicaDescriptor) }
        var duplicatedDescriptors: [Int32] = []
        defer { duplicatedDescriptors.forEach { Darwin.close($0) } }
        let childTerminalDescriptor = try childSourceDescriptor(
            terminal.replicaDescriptor,
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
            childTerminalDescriptor,
            STDIN_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            childTerminalDescriptor,
            STDOUT_FILENO
        ))
        try check(posix_spawn_file_actions_adddup2(
            &fileActions,
            childTerminalDescriptor,
            STDERR_FILENO
        ))
        let ownedDescriptors = Set([
            childTerminalDescriptor,
            terminal.primaryFileHandle.fileDescriptor,
        ]).filter { $0 > STDERR_FILENO }
        for fileDescriptor in ownedDescriptors {
            try check(posix_spawn_file_actions_addclose(&fileActions, fileDescriptor))
        }
        // A new session drops the parent's controlling terminal while the PTY
        // descriptors still satisfy terminal-gated startup files. Together with
        // monitor mode disabled at shell launch, this keeps startup children in
        // the process group owned by this probe.
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)))

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
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
        return .init(
            processIdentifier: processIdentifier,
            outputFileHandle: terminal.primaryFileHandle
        )
    }

    func waitForOutputEnd(timeout: DispatchTimeInterval) {
        outputCollector.waitForEnd(timeout: timeout)
    }

    func stopCollectingOutput() -> Data {
        outputCollector.stop()
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

private final class BoundedOutputCollector: @unchecked Sendable {
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
