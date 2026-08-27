package struct ReviewCancellationRequestReceipt: Equatable, Sendable {
    package struct ID: Hashable, Sendable {
        package let jobID: String
        package let ordinal: UInt64
    }

    package enum RejectionDisposition: Equatable, Sendable {
        case reportFailure
        case preserveRuntimeStopIntent
    }

    package let id: ID
    package let cancellation: ReviewCancellation
    package let rejectionDisposition: RejectionDisposition
    package let registeredWorkAdmission: ReviewStoreWorkRegistry.Admission?
}
