/// Linearizes connection termination on `ConnectionSupervisor` isolation.
///
/// A transport EOF is provisional until `beginClose()` probes the process. That probe is
/// the only refinement window: an exit observed before termination started, or a probe
/// failure, is more specific than `.transportFailure(.closed)`. Every other first candidate
/// is nonreplaceable.
package struct ConnectionTerminationArbiter {
    package struct Candidate: Equatable, Sendable {
        package var termination: CodexConnectionTermination
        package var observedBeforeTermination: Bool

        package init(
            _ termination: CodexConnectionTermination,
            observedBeforeTermination: Bool = false
        ) {
            if observedBeforeTermination {
                guard case .processExited = termination else {
                    preconditionFailure(
                        "Only a process-exit candidate can be observed before termination."
                    )
                }
            }
            self.termination = termination
            self.observedBeforeTermination = observedBeforeTermination
        }
    }

    package enum CloseObservation: Equatable, Sendable {
        case unavailable
        case exited(status: Int32?, observedBeforeTermination: Bool)
        case failed(CodexTransportFailure)
    }

    package enum Claim: Equatable, Sendable {
        case accepted(Candidate)
        case refined(previous: Candidate, winner: Candidate)
        case duplicate(Candidate)
        case late(
            winner: Candidate,
            candidate: Candidate
        )
    }

    private enum State: Equatable, Sendable {
        case open
        case provisional(Candidate)
        case committed(Candidate)
    }

    private var state = State.open

    package init() {}

    package var provisionalCandidate: Candidate? {
        guard case .provisional(let candidate) = state else {
            return nil
        }
        return candidate
    }

    package var winner: CodexConnectionTermination? {
        guard case .committed(let candidate) = state else {
            return nil
        }
        return candidate.termination
    }

    package mutating func claim(_ candidate: Candidate) -> Claim {
        switch state {
        case .open:
            state = .provisional(candidate)
            return .accepted(candidate)
        case .provisional(let winner):
            guard winner != candidate else {
                return .duplicate(winner)
            }
            if let refinement = Self.signalRefinement(of: winner, with: candidate) {
                state = .provisional(refinement)
                return .refined(previous: winner, winner: refinement)
            }
            return .late(winner: winner, candidate: candidate)
        case .committed(let winner):
            guard winner.termination != candidate.termination else {
                return .duplicate(winner)
            }
            return .late(winner: winner, candidate: candidate)
        }
    }

    /// Commits the terminal reason after the first candidate's `beginClose()` probe.
    ///
    /// Repeated commits are idempotent. Their observation cannot reopen arbitration.
    package mutating func commit(
        closeObservation: CloseObservation?
    ) -> CodexConnectionTermination {
        switch state {
        case .open:
            preconditionFailure("Termination cannot commit before a candidate is accepted.")
        case .provisional(let candidate):
            let winner: Candidate
            if let observationCandidate = Self.candidate(from: closeObservation),
               let refinement = Self.closeRefinement(
                   of: candidate,
                   with: observationCandidate
               ) {
                winner = refinement
            } else {
                winner = candidate
            }
            state = .committed(winner)
            return winner.termination
        case .committed(let winner):
            return winner.termination
        }
    }

    private static func signalRefinement(
        of winner: Candidate,
        with candidate: Candidate
    ) -> Candidate? {
        guard winner.termination == .transportFailure(.closed) else {
            return nil
        }
        guard case .processExited = candidate.termination,
              candidate.observedBeforeTermination else {
            return nil
        }
        return candidate
    }

    private static func closeRefinement(
        of winner: Candidate,
        with candidate: Candidate
    ) -> Candidate? {
        if let signalRefinement = signalRefinement(of: winner, with: candidate) {
            return signalRefinement
        }
        guard winner.termination == .transportFailure(.closed),
              case .transportFailure(let failure) = candidate.termination,
              failure != .closed else {
            return nil
        }
        return candidate
    }

    private static func candidate(
        from closeObservation: CloseObservation?
    ) -> Candidate? {
        switch closeObservation {
        case nil, .unavailable:
            nil
        case .exited(let status, let observedBeforeTermination):
            Candidate(
                .processExited(status: status),
                observedBeforeTermination: observedBeforeTermination
            )
        case .failed(let failure):
            Candidate(.transportFailure(failure))
        }
    }
}
