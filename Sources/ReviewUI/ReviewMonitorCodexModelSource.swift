import CodexDataKit
import Observation

@MainActor
@Observable
public final class ReviewMonitorCodexModelSource {
    public private(set) var modelContext: CodexModelContext?
    public private(set) var generation: UInt64 = 0

    @ObservationIgnored
    private var container: CodexModelContainer?

    public init(modelContext: CodexModelContext? = nil) {
        self.modelContext = modelContext
    }

    public func install(container: CodexModelContainer) {
        self.container = container
        modelContext = container.mainContext
        bumpGeneration()
    }

    public func clear() {
        container = nil
        modelContext = nil
        bumpGeneration()
    }

    private func bumpGeneration() {
        generation &+= 1
    }
}
