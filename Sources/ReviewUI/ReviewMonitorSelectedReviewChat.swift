import CodexAppServerKit
import CodexDataKit
import CodexReviewKit
import Foundation
import Observation
import ObservationBridge

@MainActor
@Observable
final class ReviewMonitorSelectedReviewChat {
    private(set) var link: ReviewChatLink?
    private(set) var chat: CodexChat?
    var phase: CodexDataPhase {
        chat?.phase ?? .idle
    }
    var lastErrorDescription: String? {
        chat?.lastErrorDescription
    }
    var turnSnapshot: CodexChatTurnSnapshot? {
        guard let chat, let link else {
            return nil
        }
        return chat.turnSnapshot(for: CodexTurnID(rawValue: link.turnID))
    }
    var chatCreatedAt: Date? {
        chat?.createdAt
    }
    var chatUpdatedAt: Date? {
        chat?.updatedAt
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
        let nextLink = boundJob?.reviewChatLink
        let nextModelContext = modelSource?.modelContext
        guard nextLink != link || nextModelContext !== boundModelContext else {
            return
        }
        cancelObservation()
        link = nextLink
        chat = nil
        boundModelContext = nextModelContext

        guard let nextLink, let modelContext = nextModelContext else {
            return
        }

        let nextChat = modelContext.model(for: CodexThreadID(rawValue: nextLink.activeChatThreadID))
        chat = nextChat

        observationTask = Task { @MainActor [weak self, nextChat, nextLink] in
            do {
                let observation = try await nextChat.observe()
                guard Task.isCancelled == false,
                    let self,
                    self.link == nextLink,
                    self.chat === nextChat
                else {
                    observation.cancel()
                    return
                }
                self.observation = observation
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
