import AppKit
import SwiftUI

enum PlaceholderContent: Equatable {
    case noSelection
    case noFindings
    case noReviewJobs

    var title: LocalizedStringResource {
        switch self {
        case .noSelection:
            "Select a workspace or review"
        case .noFindings:
            "No findings"
        case .noReviewJobs:
            "No review jobs"
        }
    }

    var description: LocalizedStringResource {
        switch self {
        case .noSelection:
            "Choose a workspace or review from the list."
        case .noFindings:
            "No structured review findings are available for this workspace."
        case .noReviewJobs:
            "Start a review through the embedded server to see workspaces here."
        }
    }

    var titleAccessibilityIdentifier: String {
        switch self {
        case .noSelection:
            "review-monitor.detail-empty.title"
        case .noFindings:
            "review-monitor.workspace-findings-empty.title"
        case .noReviewJobs:
            "review-monitor.sidebar-empty.title"
        }
    }

    var descriptionAccessibilityIdentifier: String {
        switch self {
        case .noSelection:
            "review-monitor.detail-empty.description"
        case .noFindings:
            "review-monitor.workspace-findings-empty.description"
        case .noReviewJobs:
            "review-monitor.sidebar-empty.description"
        }
    }
}

struct PlaceholderView: View {
    var content: PlaceholderContent

    var body: some View {
        ScrollView(.vertical) {
            ContentUnavailableView {
                Text(content.title)
                    .textScale(.secondary)
                    .accessibilityIdentifier(content.titleAccessibilityIdentifier)
            } description: {
                Text(content.description)
                    .accessibilityIdentifier(content.descriptionAccessibilityIdentifier)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .ignoresSafeArea(.all,edges: .vertical)
    }
}

#Preview {
    PlaceholderView(content: .noSelection)
}

final class PlaceholderViewController: NSHostingController<PlaceholderView> {
    private(set) var content: PlaceholderContent

    init(content: PlaceholderContent = .noSelection) {
        self.content = content
        super.init(rootView: PlaceholderView(content: content))
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    @discardableResult
    func render(content nextContent: PlaceholderContent) -> Bool {
        guard content != nextContent else {
            return false
        }
        content = nextContent
        rootView = PlaceholderView(content: nextContent)
        return true
    }
}
