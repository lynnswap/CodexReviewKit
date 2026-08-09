import CodexAppServerKit
import Foundation

public struct CodexAppServerTestTurn: Equatable, Sendable {
    public let snapshot: CodexTurnSnapshot
    public let items: [CodexAppServerTestItem]
    package let wireValue: CodexJSONValue

    public init(
        snapshot: CodexTurnSnapshot,
        items: [CodexAppServerTestItem]
    ) throws {
        try Self.validate(snapshot: snapshot, items: items)
        self.snapshot = snapshot
        self.items = items
        self.wireValue = Self.makeWireValue(snapshot: snapshot, items: items)
    }

    public func replacingItems(
        _ items: [CodexAppServerTestItem]
    ) throws -> Self {
        var snapshot = snapshot
        snapshot.items = items.map(\.domainProjection)
        return try Self(snapshot: snapshot, items: items)
    }

    private static func validate(
        snapshot: CodexTurnSnapshot,
        items: [CodexAppServerTestItem]
    ) throws {
        guard snapshot.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw CodexAppServerTestError.invalidFixture("turn id must not be empty")
        }
        let projections = items.map(\.domainProjection)
        guard snapshot.items.count == projections.count,
              zip(snapshot.items, projections).allSatisfy({ snapshotItem, projection in
                  snapshotItem.id == projection.id
                      && snapshotItem.kind == projection.kind
                      && snapshotItem.content == projection.content
              }) else {
            throw CodexAppServerTestError.invalidFixture(
                "turn snapshot items must match the Testing item projections"
            )
        }
        if let startedAt = snapshot.startedAt,
           let completedAt = snapshot.completedAt,
           completedAt < startedAt {
            throw CodexAppServerTestError.invalidFixture(
                "turn completion must not precede its start"
            )
        }
        if let duration = snapshot.duration, duration < .zero {
            throw CodexAppServerTestError.invalidFixture("turn duration must not be negative")
        }
        if snapshot.state == .inProgress,
           snapshot.completedAt != nil || snapshot.duration != nil {
            throw CodexAppServerTestError.invalidFixture(
                "an in-progress turn must not have completion timing"
            )
        }
    }

    private static func makeWireValue(
        snapshot: CodexTurnSnapshot,
        items: [CodexAppServerTestItem]
    ) -> CodexJSONValue {
        var fields: [String: CodexJSONValue] = [
            "id": .string(snapshot.id.rawValue),
            "status": .string(snapshot.status.rawValue),
            "itemsView": .string(snapshot.itemsLoadState.rawValue),
            "items": .array(items.map(\.wireValue)),
        ]
        if let startedAt = snapshot.startedAt {
            fields["startedAt"] = .int(Int(startedAt.timeIntervalSince1970))
        }
        if let completedAt = snapshot.completedAt {
            fields["completedAt"] = .int(Int(completedAt.timeIntervalSince1970))
        }
        if let duration = snapshot.duration {
            fields["durationMs"] = .int(duration.millisecondsForTestTurn)
        }
        if let error = snapshot.error {
            fields["error"] = error.wireValueForTesting
        }
        return .object(fields)
    }
}

public enum CodexAppServerTestTurnOutcome {
    public static func failed(
        response: CodexResponse,
        error: CodexTurnError
    ) -> CodexTurnOutcome {
        .failed(.init(response: response, error: error))
    }
}

private extension Duration {
    var millisecondsForTestTurn: Int {
        let components = self.components
        let milliseconds = components.seconds * 1_000
            + components.attoseconds / 1_000_000_000_000_000
        precondition(milliseconds >= 0 && milliseconds <= Int.max)
        return Int(milliseconds)
    }
}

extension CodexTurnError {
    package var wireValueForTesting: CodexJSONValue {
        var fields: [String: CodexJSONValue] = ["message": .string(message)]
        if let info {
            fields["codexErrorInfo"] = info.wireValueForTestTurn
        }
        if let additionalDetails {
            fields["additionalDetails"] = .string(additionalDetails)
        }
        return .object(fields)
    }
}

private extension CodexErrorInfo {
    var wireValueForTestTurn: CodexJSONValue {
        switch self {
        case .contextWindowExceeded: .string("contextWindowExceeded")
        case .sessionBudgetExceeded: .string("sessionBudgetExceeded")
        case .usageLimitExceeded: .string("usageLimitExceeded")
        case .serverOverloaded: .string("serverOverloaded")
        case .cyberPolicy: .string("cyberPolicy")
        case .internalServerError: .string("internalServerError")
        case .unauthorized: .string("unauthorized")
        case .badRequest: .string("badRequest")
        case .threadRollbackFailed: .string("threadRollbackFailed")
        case .sandboxError: .string("sandboxError")
        case .other: .string("other")
        case .unknown(let rawValue): .string(rawValue)
        case .httpConnectionFailed(let status):
            .object(["httpConnectionFailed": Self.httpStatusPayload(status)])
        case .responseStreamConnectionFailed(let status):
            .object(["responseStreamConnectionFailed": Self.httpStatusPayload(status)])
        case .responseStreamDisconnected(let status):
            .object(["responseStreamDisconnected": Self.httpStatusPayload(status)])
        case .responseTooManyFailedAttempts(let status):
            .object(["responseTooManyFailedAttempts": Self.httpStatusPayload(status)])
        case .activeTurnNotSteerable(let turnKind):
            .object(["activeTurnNotSteerable": .object(["turnKind": .string(turnKind)])])
        }
    }

    private static func httpStatusPayload(_ status: UInt16?) -> CodexJSONValue {
        .object(["httpStatusCode": status.map { .int(Int($0)) } ?? .null])
    }
}
