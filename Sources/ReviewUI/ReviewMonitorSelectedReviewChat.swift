import CodexKit
import CodexReviewKit
import Foundation
import Observation
import ObservationBridge
import ReviewMonitorRendering

@MainActor
@Observable
final class ReviewMonitorSelectedReviewChat {
    private(set) var identity: CodexReviewIdentity?
    private(set) var chat: CodexChat?
    private(set) var timelineDocument: ReviewTimelineDocument?
    var phase: CodexDataPhase {
        chat?.phase ?? .idle
    }
    var lastErrorDescription: String? {
        chat?.lastErrorDescription
    }

    @ObservationIgnored
    private let modelSource: ReviewMonitorCodexModelSource?
    @ObservationIgnored
    private weak var boundModelContext: CodexModelContext?
    @ObservationIgnored
    private weak var boundJob: CodexReviewJob?
    @ObservationIgnored
    private var observation: CodexChatObservation?
    @ObservationIgnored
    private var observationTask: Task<Void, Never>?
    @ObservationIgnored
    private var documentProjection = ReviewMonitorSelectedReviewChatDocumentProjection()
    @ObservationIgnored
    private var modelSourceObservation: PortableObservationTracking.Token?

    init(modelSource: ReviewMonitorCodexModelSource?) {
        self.modelSource = modelSource
        bindModelSource()
    }

    isolated deinit {
        modelSourceObservation?.cancel()
        cancelObservation()
    }

    func bind(to job: CodexReviewJob?) {
        boundJob = job
        refreshBinding()
    }

    private func bindModelSource() {
        guard let modelSource else {
            return
        }
        modelSourceObservation = withPortableContinuousObservation { [weak self, modelSource] _ in
            _ = modelSource.generation
            self?.refreshBinding()
        }
    }

    private func refreshBinding() {
        let nextIdentity = boundJob?.reviewIdentity
        let nextModelContext = modelSource?.modelContext
        guard nextIdentity != identity || nextModelContext !== boundModelContext else {
            return
        }
        cancelObservation()
        identity = nextIdentity
        chat = nil
        timelineDocument = nil
        documentProjection.reset()
        boundModelContext = nextModelContext

        guard let nextIdentity, let modelContext = nextModelContext else {
            return
        }

        let nextChat = modelContext.model(for: nextIdentity)
        chat = nextChat

        observationTask = Task { @MainActor [weak self, nextChat, nextIdentity, modelContext] in
            do {
                let observation = try await modelContext.observe(nextIdentity)
                guard Task.isCancelled == false,
                    let self,
                    self.identity == nextIdentity,
                    self.chat === nextChat
                else {
                    observation.cancel()
                    return
                }
                self.observation = observation
                for await change in observation.changes {
                    guard Task.isCancelled == false,
                          self.identity == nextIdentity,
                          self.chat === nextChat
                    else {
                        break
                    }
                    self.timelineDocument = self.documentProjection.apply(
                        change,
                        activeTurnID: nextIdentity.turnID,
                        chatCreatedAt: nextChat.createdAt,
                        chatUpdatedAt: nextChat.updatedAt
                    )
                }
            } catch is CancellationError {
            } catch {
            }
        }
    }

    private func cancelObservation() {
        observationTask?.cancel()
        observationTask = nil
        observation?.cancel()
        observation = nil
    }
}

private extension CodexReviewJob {
    var reviewIdentity: CodexReviewIdentity? {
        guard let sourceThreadID = core.run.threadID?.nilIfEmpty,
            let turnID = core.run.turnID?.nilIfEmpty
        else {
            return nil
        }
        return CodexReviewIdentity(
            threadID: CodexThreadID(rawValue: sourceThreadID),
            turnID: CodexTurnID(rawValue: turnID),
            reviewThreadID: core.run.reviewThreadID?.nilIfEmpty.map(CodexThreadID.init(rawValue:)),
            model: core.run.model?.nilIfEmpty
        )
    }
}
