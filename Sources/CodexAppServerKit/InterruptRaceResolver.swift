import Foundation

package struct InterruptRaceResolver: Sendable {
    package enum Decision: Sendable {
        case retry(after: Duration)
        case redirect(to: CodexTurnID)
        case fail
    }

    private static let noActiveTurnMessage = "no active turn to interrupt"
    private static let activationRetryLimit = 5
    private static let activationRetryDelay = Duration.milliseconds(50)

    private let expectedTurnID: CodexTurnID?
    private var activationRetryCount = 0
    private var redirected = false

    package init(expectedTurnID: CodexTurnID?) {
        self.expectedTurnID = expectedTurnID
    }

    package mutating func decision(for error: any Error) -> Decision {
        guard let message = Self.serverError(from: error)?.message else {
            return .fail
        }
        if expectedTurnID != nil,
           message == Self.noActiveTurnMessage,
           activationRetryCount < Self.activationRetryLimit {
            activationRetryCount += 1
            return .retry(after: Self.activationRetryDelay)
        }
        // The pinned app-server treats an empty turn ID as a startup interrupt
        // and bypasses its expected-turn mismatch check. Only a nonempty ID we
        // actually sent can authenticate the exact mismatch prefix below.
        guard redirected == false,
              let expectedTurnID,
              let activeTurnID = Self.activeTurnID(
                in: message,
                expectedTurnID: expectedTurnID
              ),
              activeTurnID != expectedTurnID else {
            return .fail
        }
        redirected = true
        return .redirect(to: activeTurnID)
    }

    private static func activeTurnID(
        in message: String,
        expectedTurnID: CodexTurnID
    ) -> CodexTurnID? {
        let prefix = "expected active turn id \(expectedTurnID.rawValue) but found "
        guard message.hasPrefix(prefix) else {
            return nil
        }
        let rawValue = String(message.dropFirst(prefix.count))
        guard rawValue.isEmpty == false,
              rawValue.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              rawValue.contains("`") == false else {
            return nil
        }
        return CodexTurnID(rawValue: rawValue)
    }

    private static func serverError(from error: any Error) -> CodexServerError? {
        if case CodexAppServerError.request(let failure) = error,
           case .server(let serverError) = failure.kind {
            return serverError
        }
        if case JSONRPC.Error.responseError(let serverError) = error {
            return serverError
        }
        return nil
    }
}
