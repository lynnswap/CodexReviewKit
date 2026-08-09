package struct CodexChatCancellationCapability: Equatable, Sendable {
    package enum Action: Equatable, Sendable {
        case reviewRun
        case directChat
    }

    package let isEnabled: Bool
    package let action: Action?

    package static let disabled = CodexChatCancellationCapability(isEnabled: false, action: nil)
    package static let reviewRun = CodexChatCancellationCapability(isEnabled: true, action: .reviewRun)
    package static let directChat = CodexChatCancellationCapability(isEnabled: true, action: .directChat)
    // A cancellation is already in flight; there is nothing further the user
    // can trigger, so the command stays visible but disabled.
    package static let pendingReviewCancellation = CodexChatCancellationCapability(isEnabled: false, action: nil)

    package init(isEnabled: Bool, action: Action?) {
        self.isEnabled = isEnabled
        self.action = action
    }
}

extension CodexReviewStore {
    package var orderedReviewRuns: [ReviewRunRecord] {
        reviewRuns.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.id.rawValue < $1.id.rawValue
            }
            return $0.sortOrder > $1.sortOrder
        }
    }

    package func reviewRun(id: ReviewRunID) -> ReviewRunRecord? {
        reviewRuns.first(where: { $0.id == id })
    }

    package func isCancellableReviewRun(_ runRecord: ReviewRunRecord) -> Bool {
        runRecord.presentation.isCancellable && runRecord.cancellationRequested == false
    }

    package func hasCancellableReview(forChatID chatID: String) -> Bool {
        cancellableReviewRun(forChatID: chatID) != nil
    }

    package func hasReviewRun(forChatID chatID: String) -> Bool {
        reviewRun(forChatID: chatID) != nil
    }

    package func hasNonTerminalReviewRun(forChatID chatID: String) -> Bool {
        orderedReviewRuns.contains { runRecord in
            guard runRecord.isTerminal == false else {
                return false
            }
            return runRecord.matchesChatID(chatID)
        }
    }

    package func chatCancellationCapability(
        forChatID chatID: String,
        isChatActive: Bool
    ) -> CodexChatCancellationCapability {
        if hasCancellableReview(forChatID: chatID) {
            return .reviewRun
        }

        guard isChatActive else {
            return .disabled
        }

        if hasNonTerminalReviewRun(forChatID: chatID) {
            return .pendingReviewCancellation
        }

        return .directChat
    }

    package func reviewRun(forChatID chatID: String) -> ReviewRunRecord? {
        orderedReviewRuns.first { runRecord in
            runRecord.matchesChatID(chatID)
        }
    }

    package func reviewRun(forReviewChatID chatID: String) -> ReviewRunRecord? {
        orderedReviewRuns.first { runRecord in
            runRecord.matchesReviewChatID(chatID)
        }
    }

    package func cancellableReviewRun(forChatID chatID: String) -> ReviewRunRecord? {
        orderedReviewRuns.first { runRecord in
            guard isCancellableReviewRun(runRecord) else {
                return false
            }
            return runRecord.matchesChatID(chatID)
        }
    }

}

private extension ReviewRunRecord {
    func matchesReviewChatID(_ chatID: String) -> Bool {
        core.attempt?.threadIdentity.activeTurnThreadID.rawValue == chatID
    }

    func matchesChatID(_ chatID: String) -> Bool {
        guard let identity = core.attempt?.threadIdentity else {
            return false
        }
        return matchesChatID(chatID, candidate: identity.activeTurnThreadID.rawValue)
            || matchesChatID(chatID, candidate: identity.sourceThreadID.rawValue)
    }

    private func matchesChatID(_ chatID: String, candidate: String) -> Bool {
        return candidate == chatID
    }
}
