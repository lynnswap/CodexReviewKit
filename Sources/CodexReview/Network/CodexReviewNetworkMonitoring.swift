import Foundation
import Network

package enum CodexReviewNetworkStatus: String, Codable, Hashable, Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

package enum CodexReviewNetworkInterfaceType: String, Codable, Hashable, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case loopback
    case other
}

package struct CodexReviewNetworkSnapshot: Codable, Hashable, Sendable {
    package var status: CodexReviewNetworkStatus
    package var isExpensive: Bool
    package var isConstrained: Bool
    package var interfaceTypes: Set<CodexReviewNetworkInterfaceType>
    package var observedAt: Date

    package init(
        status: CodexReviewNetworkStatus,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        interfaceTypes: Set<CodexReviewNetworkInterfaceType> = [],
        observedAt: Date = Date()
    ) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaceTypes = interfaceTypes
        self.observedAt = observedAt
    }

    package static func satisfied(observedAt: Date = Date()) -> Self {
        .init(status: .satisfied, observedAt: observedAt)
    }
}

package protocol CodexReviewNetworkMonitoring: Sendable {
    func snapshots() -> AsyncStream<CodexReviewNetworkSnapshot>
}

package struct CodexReviewNetworkRecoveryPolicy: Sendable {
    package var outageDebounce: Duration
    package var recoverySettle: Duration
    package var sleep: @Sendable (Duration) async throws -> Void

    package init(
        outageDebounce: Duration = .seconds(10),
        recoverySettle: Duration = .seconds(1),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.outageDebounce = outageDebounce
        self.recoverySettle = recoverySettle
        self.sleep = sleep
    }

    package static var `default`: Self {
        .init()
    }
}

package struct StaticCodexReviewNetworkMonitor: CodexReviewNetworkMonitoring {
    private var snapshot: CodexReviewNetworkSnapshot

    package init(snapshot: CodexReviewNetworkSnapshot = .satisfied()) {
        self.snapshot = snapshot
    }

    package func snapshots() -> AsyncStream<CodexReviewNetworkSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(snapshot)
        }
    }
}

package struct SystemCodexReviewNetworkMonitor: CodexReviewNetworkMonitoring {
    package init() {}

    package func snapshots() -> AsyncStream<CodexReviewNetworkSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let box = NWPathMonitorBox(continuation: continuation)
            continuation.onTermination = { @Sendable _ in
                box.cancel()
            }
            box.start()
        }
    }
}

private final class NWPathMonitorBox: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "CodexReviewKit.network-monitor")
    private let continuation: AsyncStream<CodexReviewNetworkSnapshot>.Continuation

    init(continuation: AsyncStream<CodexReviewNetworkSnapshot>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        monitor.pathUpdateHandler = { [continuation] path in
            continuation.yield(Self.snapshot(from: path))
        }
        monitor.start(queue: queue)
        continuation.yield(Self.snapshot(from: monitor.currentPath))
    }

    func cancel() {
        monitor.cancel()
    }

    private static func snapshot(from path: NWPath) -> CodexReviewNetworkSnapshot {
        .init(
            status: CodexReviewNetworkStatus(path.status),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            interfaceTypes: CodexReviewNetworkInterfaceType.interfaceTypes(from: path),
            observedAt: Date()
        )
    }
}

private extension CodexReviewNetworkStatus {
    init(_ status: NWPath.Status) {
        switch status {
        case .satisfied:
            self = .satisfied
        case .unsatisfied:
            self = .unsatisfied
        case .requiresConnection:
            self = .requiresConnection
        @unknown default:
            self = .unsatisfied
        }
    }
}

private extension CodexReviewNetworkInterfaceType {
    static func interfaceTypes(from path: NWPath) -> Set<Self> {
        var types: Set<Self> = []
        for type in NWInterface.InterfaceType.codexReviewKnownTypes {
            if path.usesInterfaceType(type) {
                types.insert(Self(type))
            }
        }
        return types
    }

    init(_ type: NWInterface.InterfaceType) {
        switch type {
        case .wifi:
            self = .wifi
        case .cellular:
            self = .cellular
        case .wiredEthernet:
            self = .wiredEthernet
        case .loopback:
            self = .loopback
        case .other:
            self = .other
        @unknown default:
            self = .other
        }
    }
}

private extension NWInterface.InterfaceType {
    static var codexReviewKnownTypes: [Self] {
        [.wifi, .cellular, .wiredEthernet, .loopback, .other]
    }
}
