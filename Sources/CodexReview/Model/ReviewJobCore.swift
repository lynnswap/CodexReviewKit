import Foundation

public struct ReviewJobCore: Codable, Sendable, Hashable {
    public struct Run: Codable, Sendable, Hashable {
        public internal(set) var reviewThreadID: String?
        public internal(set) var threadID: String?
        public internal(set) var turnID: String?
        public internal(set) var model: String?

        public init(
            reviewThreadID: String? = nil,
            threadID: String? = nil,
            turnID: String? = nil,
            model: String? = nil
        ) {
            self.reviewThreadID = reviewThreadID
            self.threadID = threadID
            self.turnID = turnID
            self.model = model
        }
    }

    public struct Lifecycle: Codable, Sendable, Hashable {
        public internal(set) var status: ReviewJobState {
            didSet { adoptTerminalForRuntimeTransitionIfNeeded() }
        }
        public internal(set) var exitCode: Int?
        public internal(set) var startedAt: Date?
        public internal(set) var endedAt: Date?
        public internal(set) var cancellation: ReviewCancellation? {
            didSet { adoptTerminalForRuntimeTransitionIfNeeded() }
        }
        public internal(set) var errorMessage: String? {
            didSet {
                if status == .failed,
                   case .failed = terminal {
                    terminal = .failed(message: errorMessage?.nilIfEmpty)
                }
            }
        }
        public internal(set) var terminal: ReviewTerminalRecord?

        public init(
            status: ReviewJobState,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            cancellation: ReviewCancellation? = nil,
            errorMessage: String? = nil
        ) {
            self.status = status
            self.exitCode = exitCode
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.cancellation = cancellation
            self.errorMessage = errorMessage
            self.terminal = nil
        }

        package init(
            status: ReviewJobState,
            exitCode: Int? = nil,
            startedAt: Date? = nil,
            endedAt: Date? = nil,
            cancellation: ReviewCancellation? = nil,
            errorMessage: String? = nil,
            terminal: ReviewTerminalRecord?
        ) {
            self.init(
                status: status,
                exitCode: exitCode,
                startedAt: startedAt,
                endedAt: endedAt,
                cancellation: cancellation,
                errorMessage: errorMessage
            )
            precondition(
                Self.isCompatible(status: status, terminal: terminal),
                "ReviewJobCore.Lifecycle package initializer owns terminal/status consistency."
            )
            self.terminal = terminal
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let status = try container.decode(ReviewJobState.self, forKey: .status)
            let terminal = try container.decodeIfPresent(
                ReviewTerminalRecord.self,
                forKey: .terminal
            )
            guard Self.isCompatible(status: status, terminal: terminal) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .terminal,
                    in: container,
                    debugDescription: "Lifecycle terminal does not agree with its legacy status."
                )
            }
            self.status = status
            self.exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
            self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
            self.endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
            self.cancellation = try container.decodeIfPresent(
                ReviewCancellation.self,
                forKey: .cancellation
            )
            self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
            self.terminal = terminal
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(status, forKey: .status)
            try container.encodeIfPresent(exitCode, forKey: .exitCode)
            try container.encodeIfPresent(startedAt, forKey: .startedAt)
            try container.encodeIfPresent(endedAt, forKey: .endedAt)
            try container.encodeIfPresent(cancellation, forKey: .cancellation)
            try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
            try container.encodeIfPresent(terminal, forKey: .terminal)
        }

        private enum CodingKeys: String, CodingKey {
            case status
            case exitCode
            case startedAt
            case endedAt
            case cancellation
            case errorMessage
            case terminal
        }

        private mutating func adoptTerminalForRuntimeTransitionIfNeeded() {
            guard terminal == nil else {
                return
            }
            switch status {
            case .queued, .running:
                break
            case .succeeded:
                terminal = .completed
            case .cancelled:
                if let cancellation {
                    terminal = .interrupted(.requested(cancellation))
                }
            case .failed:
                terminal = .failed(message: errorMessage?.nilIfEmpty)
            }
        }

        private static func isCompatible(
            status: ReviewJobState,
            terminal: ReviewTerminalRecord?
        ) -> Bool {
            guard let terminal else {
                return true
            }
            switch terminal {
            case .completed:
                return status == .succeeded
            case .interrupted(.requested):
                return status == .cancelled
            case .interrupted(.server),
                .interrupted(.transport),
                .interrupted(.previousProcessExit),
                .failed:
                return status == .failed
            }
        }
    }

    public struct Output: Codable, Sendable, Hashable {
        public internal(set) var summary: String
        public internal(set) var hasFinalReview: Bool
        public internal(set) var lastAgentMessage: String?
        public internal(set) var reviewResult: ParsedReviewResult?

        public init(
            summary: String,
            hasFinalReview: Bool = false,
            lastAgentMessage: String? = nil,
            reviewResult: ParsedReviewResult? = nil
        ) {
            self.summary = summary
            self.hasFinalReview = hasFinalReview
            self.lastAgentMessage = lastAgentMessage
            self.reviewResult = reviewResult
        }
    }

    public internal(set) var run: Run
    public internal(set) var lifecycle: Lifecycle
    public internal(set) var output: Output

    public init(
        run: Run = .init(),
        lifecycle: Lifecycle,
        output: Output
    ) {
        self.run = run
        self.lifecycle = lifecycle
        self.output = output
    }

    public var isTerminal: Bool {
        lifecycle.status.isTerminal
    }

    public var reviewText: String {
        switch lifecycle.status {
        case .cancelled:
            if output.hasFinalReview,
               let lastAgentMessage = output.lastAgentMessage?.nilIfEmpty
            {
                return lastAgentMessage
            }
            if let errorMessage = lifecycle.errorMessage?.nilIfEmpty {
                return errorMessage
            }
            return output.summary
        case .failed:
            return lifecycle.errorMessage?.nilIfEmpty ?? output.summary
        case .succeeded:
            if output.hasFinalReview,
               let lastAgentMessage = output.lastAgentMessage?.nilIfEmpty {
                return lastAgentMessage
            }
            return output.summary
        case .queued, .running:
            return output.lastAgentMessage?.nilIfEmpty
                ?? lifecycle.errorMessage?.nilIfEmpty
                ?? output.summary
        }
    }
}
