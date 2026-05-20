import AppKit

@MainActor
enum ReviewMonitorViewFactory {
    static func makeEmptyStateView(
        title: String,
        description: String,
        titleAccessibilityIdentifier: String? = nil,
        descriptionAccessibilityIdentifier: String? = nil
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.alignment = .center
        if let titleAccessibilityIdentifier {
            titleLabel.setAccessibilityIdentifier(titleAccessibilityIdentifier)
        }

        let descriptionLabel = NSTextField(wrappingLabelWithString: description)
        descriptionLabel.font = .preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.alignment = .center
        descriptionLabel.maximumNumberOfLines = 0
        if let descriptionAccessibilityIdentifier {
            descriptionLabel.setAccessibilityIdentifier(descriptionAccessibilityIdentifier)
        }

        let stackView = NSStackView(views: [titleLabel, descriptionLabel])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 8
        return stackView
    }
}
