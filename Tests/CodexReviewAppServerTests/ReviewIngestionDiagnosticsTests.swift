import CodexReview
import Foundation
import Testing
@testable import CodexReviewAppServer

@Suite("review ingestion diagnostic summary")
struct ReviewIngestionDiagnosticSummaryTests {
    @Test func summaryContainsOnlyFixedMetadataCountsAndPresence() {
        let secret = String(repeating: "secret🌏", count: 10_000)
        let summary = ReviewIngestionDiagnosticSummary(
            diagnostic(
                method: secret,
                threadID: secret,
                turnID: nil,
                itemType: secret,
                rawParams: Data(repeating: 0xFF, count: 1_000_000),
                error: .malformedKnownEvent(method: secret, message: secret)
            ),
            recordID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        #expect(summary.key.methodCategory == .other)
        #expect(summary.key.errorCase == .malformedKnownEvent)
        #expect(summary.rawByteCount == 1_000_000)
        #expect(summary.hasThreadID)
        #expect(summary.hasTurnID == false)
        #expect(summary.hasItemType)
        #expect(String(reflecting: summary).contains(secret) == false)
    }

    @Test func registeredMethodsMapToClosedCategories() {
        #expect(summary(method: "warning").key.methodCategory == .globalDiagnostic)
        #expect(summary(method: "thread/closed").key.methodCategory == .threadLifecycle)
        #expect(summary(method: "turn/completed").key.methodCategory == .turnLifecycle)
        #expect(summary(method: "item/completed").key.methodCategory == .itemLifecycle)
        #expect(summary(method: "item/reasoning/textDelta").key.methodCategory == .itemDelta)
        #expect(summary(method: "model/rerouted").key.methodCategory == .model)
        #expect(summary(method: "unknown").key.methodCategory == .other)
    }

    private func summary(method: String) -> ReviewIngestionDiagnosticSummary {
        .init(diagnostic(method: method), recordID: UUID())
    }
}

@Suite("review ingestion diagnostic sampler")
struct ReviewIngestionDiagnosticSamplerTests {
    @Test func repeatedKeyEmitsTwoRecordsThenOneSuppression() {
        var sampler = ReviewIngestionDiagnosticSampler()
        let key = summary(method: "warning").key
        #expect((0..<5).map { _ in sampler.decision(for: key) } == [
            .emitFullRecord, .emitFullRecord, .emitSuppressionSummary, .suppress, .suppress,
        ])
        #expect(sampler.trackedKeyCount == 1)
    }

    @Test func distinctFixedKeysHaveIndependentAllowance() {
        var sampler = ReviewIngestionDiagnosticSampler()
        let first = summary(method: "warning").key
        let second = summary(method: "thread/closed").key
        #expect(sampler.decision(for: first) == .emitFullRecord)
        #expect(sampler.decision(for: first) == .emitFullRecord)
        #expect(sampler.decision(for: first) == .emitSuppressionSummary)
        #expect(sampler.decision(for: second) == .emitFullRecord)
        #expect(sampler.trackedKeyCount == 2)
    }

    @Test func stateAndOverflowSummaryAreFinite() {
        var sampler = ReviewIngestionDiagnosticSampler()
        let categories: [ReviewIngestionDiagnosticSummary.MethodCategory] = [
            .globalDiagnostic, .threadLifecycle, .turnLifecycle, .itemLifecycle,
            .itemDelta, .model, .other,
        ]
        let stages: [ReviewIngestionDiagnosticRecord.Stage] = [
            .paramsDecoding, .schemaValidation, .payloadDecoding,
        ]
        let keys = categories.flatMap { category in
            stages.map { stage in key(methodCategory: category, stage: stage) }
        }
        for key in keys.prefix(ReviewIngestionDiagnosticSampler.maximumKeyCount) {
            #expect(sampler.decision(for: key) == .emitFullRecord)
        }
        #expect(sampler.decision(for: keys[16]) == .emitCapacitySuppressionSummary)
        #expect(sampler.decision(for: keys[17]) == .suppress)
        #expect(sampler.trackedKeyCount == ReviewIngestionDiagnosticSampler.maximumKeyCount)
    }

    @Test func connectionFailureAlwaysEmitsWithoutSamplerState() {
        var sampler = ReviewIngestionDiagnosticSampler()
        let key = key(methodCategory: .itemLifecycle, disposition: .connectionFailed)
        for _ in 0..<64 {
            #expect(sampler.decision(for: key) == .emitFullRecord)
        }
        #expect(sampler.trackedKeyCount == 0)
    }

    private func summary(method: String) -> ReviewIngestionDiagnosticSummary {
        .init(diagnostic(method: method), recordID: UUID())
    }

    private func key(
        methodCategory: ReviewIngestionDiagnosticSummary.MethodCategory,
        stage: ReviewIngestionDiagnosticRecord.Stage = .schemaValidation,
        disposition: ReviewIngestionDiagnosticRecord.Disposition = .ignored
    ) -> ReviewIngestionDiagnosticSummary.Key {
        .init(
            methodCategory: methodCategory,
            stage: stage,
            disposition: disposition,
            errorCase: .malformedKnownEvent
        )
    }
}

private func diagnostic(
    method: String,
    threadID: String? = nil,
    turnID: String? = nil,
    itemType: String? = nil,
    rawParams: Data = Data(),
    error: ReviewIngestionError = .malformedKnownEvent(method: "known", message: "invalid"),
    disposition: ReviewIngestionDiagnosticRecord.Disposition = .ignored
) -> ReviewIngestionDiagnosticRecord {
    .init(
        method: method,
        threadID: threadID,
        turnID: turnID,
        itemType: itemType,
        rawParams: rawParams,
        stage: .schemaValidation,
        error: error,
        disposition: disposition
    )
}
