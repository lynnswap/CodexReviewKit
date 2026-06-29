import CodexKit
import Foundation
import Observation
import ObservationBridge

@MainActor
@Observable
final class ReviewMonitorSelectedCodexChat {
    private(set) var chatID: CodexThreadID?
    private(set) var chat: CodexChat?
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
    private var boundChatID: CodexThreadID?
    @ObservationIgnored
    private var targetChatID: CodexThreadID?
    @ObservationIgnored
    private var observation: CodexChatObservation?
    @ObservationIgnored
    private var observationTask: Task<Void, Never>?
    @ObservationIgnored
    private var logProjection = ReviewMonitorSelectedCodexChatLogProjection()
    @ObservationIgnored
    private var modelSourceObservation: PortableObservationTracking.Token?
    @ObservationIgnored
    private var currentLogSourceDocument: ReviewMonitorLog.Document?
    @ObservationIgnored
    private var logSourceChangeContinuations: [UUID: AsyncStream<ReviewMonitorLogSourceChange>.Continuation] = [:]

    init(modelSource: ReviewMonitorCodexModelSource?) {
        self.modelSource = modelSource
        bindModelSource()
    }

    isolated deinit {
        modelSourceObservation?.cancel()
        cancelObservation()
    }

    func bind(toChatID chatID: CodexThreadID?) {
        boundChatID = chatID
        refreshBinding()
    }

    func unbind() {
        boundChatID = nil
        refreshBinding()
    }

    func logSourceChangeStream() -> AsyncStream<ReviewMonitorLogSourceChange> {
        let id = UUID()
        let pair = AsyncStream<ReviewMonitorLogSourceChange>.makeStream(bufferingPolicy: .unbounded)
        logSourceChangeContinuations[id] = pair.continuation
        if let currentLogSourceDocument {
            pair.continuation.yield(.replaceAll(currentLogSourceDocument))
        }
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logSourceChangeContinuations.removeValue(forKey: id)
            }
        }
        return pair.stream
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
        let nextChatID = boundChatID
        let nextModelContext = modelSource?.modelContext
        guard nextChatID != targetChatID || nextModelContext !== boundModelContext else {
            return
        }
        cancelObservation()
        targetChatID = nextChatID
        chatID = nextChatID
        chat = nil
        publishLogSourceChange(.clear)
        logProjection.reset()
        boundModelContext = nextModelContext

        guard let nextChatID else {
            return
        }

        guard let modelContext = nextModelContext else {
            return
        }

        let nextChat = modelContext.model(for: nextChatID)
        chat = nextChat

        observationTask = Task { @MainActor [weak self, nextChat, nextChatID, modelContext] in
            do {
                let observation = try await Self.observe(chat: nextChat, modelContext: modelContext)
                guard Task.isCancelled == false,
                    let self,
                    self.targetChatID == nextChatID,
                    self.chat === nextChat
                else {
                    observation.cancel()
                    return
                }
                self.observation = observation
                for await change in observation.changes {
                    guard Task.isCancelled == false,
                        self.targetChatID == nextChatID,
                        self.chat === nextChat
                    else {
                        break
                    }
                    self.publishLogSourceChange(
                        self.logProjection.apply(
                            change,
                            chatCreatedAt: nextChat.createdAt,
                            chatUpdatedAt: nextChat.updatedAt
                        ))
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

    private func publishLogSourceChange(_ change: ReviewMonitorLogSourceChange?) {
        guard let change else {
            return
        }
        currentLogSourceDocument = change.sourceDocument
        for continuation in logSourceChangeContinuations.values {
            continuation.yield(change)
        }
    }

    private static func observe(
        chat: CodexChat,
        modelContext: CodexModelContext
    ) async throws -> CodexChatObservation {
        try await modelContext.observe(chat)
    }
}
