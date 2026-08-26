import Testing
@testable import CodexReview

@Suite("backend review event mailbox")
struct BackendReviewEventMailboxTests {
    @Test func appendReportsWhetherTheMailboxAcceptedTheEvent() async throws {
        let mailbox = BackendReviewEventMailbox()
        let accepted = CodexReviewBackendModel.Review.Event.message("accepted")

        #expect(await mailbox.append(accepted))
        #expect(await mailbox.append(.cancelled("Stop")))
        #expect(await mailbox.append(.message("late")) == false)

        #expect(try await mailbox.next() == accepted)
        #expect(try await mailbox.next() == .cancelled("Stop"))
        #expect(try await mailbox.next() == nil)
    }
}
