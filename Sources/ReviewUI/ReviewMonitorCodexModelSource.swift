import CodexDataKit
import Observation

@MainActor
@Observable
public final class ReviewMonitorCodexModelSource {
    package private(set) var modelContext: CodexModelContext?

    @ObservationIgnored
    private var container: CodexModelContainer?

    public init() {
        modelContext = nil
    }

    package init(modelContext: CodexModelContext) {
        self.modelContext = modelContext
    }

    public func install(container: CodexModelContainer) {
        self.container = container
        modelContext = container.mainContext
    }

    public func clear() {
        container = nil
        modelContext = nil
    }
}
