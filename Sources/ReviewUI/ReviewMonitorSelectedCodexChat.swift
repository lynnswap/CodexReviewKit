import CodexKit
import Foundation
import Observation
import ObservationBridge
import ReviewMonitorRendering

@MainActor
@Observable
final class ReviewMonitorSelectedCodexChat {
    private enum BindingTarget: Equatable {
        case review(CodexReviewIdentity)
        case chat(CodexThreadID)

        var reviewIdentity: CodexReviewIdentity? {
            guard case .review(let identity) = self else {
                return nil
            }
            return identity
        }

        var chatID: CodexThreadID {
            switch self {
            case .review(let identity):
                identity.activeTurnThreadID
            case .chat(let id):
                id
            }
        }

        var activeTurnID: CodexTurnID? {
            guard case .review(let identity) = self else {
                return nil
            }
            return identity.turnID
        }
    }

    private(set) var identity: CodexReviewIdentity?
    private(set) var chatID: CodexThreadID?
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
    private var boundTarget: BindingTarget?
    @ObservationIgnored
    private var target: BindingTarget?
    @ObservationIgnored
    private var observation: CodexChatObservation?
    @ObservationIgnored
    private var observationTask: Task<Void, Never>?
    @ObservationIgnored
    private var documentProjection = ReviewMonitorSelectedCodexChatDocumentProjection()
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

    func bind(to identity: CodexReviewIdentity?) {
        boundTarget = identity.map(BindingTarget.review)
        refreshBinding()
    }

    func bind(toChatID chatID: CodexThreadID?) {
        boundTarget = chatID.map(BindingTarget.chat)
        refreshBinding()
    }

    func unbind() {
        boundTarget = nil
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
        let nextTarget = boundTarget
        let nextModelContext = modelSource?.modelContext
        guard nextTarget != target || nextModelContext !== boundModelContext else {
            return
        }
        cancelObservation()
        target = nextTarget
        identity = nextTarget?.reviewIdentity
        chatID = nextTarget?.chatID
        chat = nil
        timelineDocument = nil
        documentProjection.reset()
        boundModelContext = nextModelContext

        guard let nextTarget, let modelContext = nextModelContext else {
            return
        }

        let nextChat = modelContext.model(for: nextTarget.chatID)
        chat = nextChat

        observationTask = Task { @MainActor [weak self, nextChat, nextTarget, modelContext] in
            do {
                let observation = try await Self.observe(nextTarget, modelContext: modelContext, chat: nextChat)
                guard Task.isCancelled == false,
                    let self,
                    self.target == nextTarget,
                    self.chat === nextChat
                else {
                    observation.cancel()
                    return
                }
                self.observation = observation
                for await change in observation.changes {
                    guard Task.isCancelled == false,
                          self.target == nextTarget,
                          self.chat === nextChat
                    else {
                        break
                    }
                    self.timelineDocument = self.documentProjection.apply(
                        change,
                        activeTurnID: nextTarget.activeTurnID,
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

    private static func observe(
        _ target: BindingTarget,
        modelContext: CodexModelContext,
        chat: CodexChat
    ) async throws -> CodexChatObservation {
        switch target {
        case .review(let identity):
            try await modelContext.observe(identity)
        case .chat:
            try await chat.observe()
        }
    }
}
