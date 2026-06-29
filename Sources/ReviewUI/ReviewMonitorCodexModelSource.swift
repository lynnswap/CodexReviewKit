import CodexKit
import Observation

@MainActor
@Observable
public final class ReviewMonitorCodexModelSource {
    public private(set) var modelContext: CodexModelContext?

    @ObservationIgnored
    private var container: CodexModelContainer?

    public init(modelContext: CodexModelContext? = nil) {
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
