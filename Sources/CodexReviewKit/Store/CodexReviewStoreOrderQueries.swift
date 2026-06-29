extension CodexReviewStore {
    package var orderedReviewRuns: [ReviewRunRecord] {
        reviewRuns.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.id < $1.id
            }
            return $0.sortOrder > $1.sortOrder
        }
    }

    package func reviewRun(id: String) -> ReviewRunRecord? {
        reviewRuns.first(where: { $0.id == id })
    }

    package func isCancellableReviewRun(_ runRecord: ReviewRunRecord) -> Bool {
        runRecord.isTerminal == false && runRecord.cancellationRequested == false
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

    package func reviewRun(forChatID chatID: String) -> ReviewRunRecord? {
        orderedReviewRuns.first { runRecord in
            runRecord.matchesChatID(chatID)
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
    func matchesChatID(_ chatID: String) -> Bool {
        matchesChatID(chatID, candidate: core.run.reviewThreadID)
            || matchesChatID(chatID, candidate: core.run.threadID)
    }

    private func matchesChatID(_ chatID: String, candidate: String?) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
            candidate.isEmpty == false
        else {
            return false
        }
        return candidate == chatID
    }
}
