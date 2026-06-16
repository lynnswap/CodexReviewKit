import AppKit
import Testing
@testable import TextTransitions

@MainActor
struct TextTransitionViewTests {
    @Test func numericTextAnimatesOnlyChangedNumericGlyphsInMixedText() {
        let view = TextTransitionView(
            text: attributed("files: 8 ok"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        view.setText(attributed("files: 9 ok"))

        #expect(view.activeTransitionCountForTesting == 1)
        #expect(view.activeTransitionDirectionsForTesting == [.countingUp])
    }

    @Test func numericTextKeepsOldDigitLayerHiddenAtCompletionValue() {
        let view = TextTransitionView(
            text: attributed("8"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        view.setText(attributed("9"))

        #expect(view.activeTransitionOldLayerOpacitiesForTesting == [0])
    }

    @Test func unchangedTextUpdatePreservesActiveTransitions() {
        let view = TextTransitionView(
            text: attributed("8"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        view.setText(attributed("9"))
        #expect(view.activeTransitionCountForTesting == 1)

        view.setText(attributed("9"), animated: false)

        #expect(view.activeTransitionCountForTesting == 1)
    }

    @Test func numericTextCountsDownReversesDirection() {
        let view = TextTransitionView(
            text: attributed("2"),
            contentTransition: .numericText(countsDown: false),
            motionPolicy: .enabled
        )

        view.setText(attributed("3"))
        #expect(view.activeTransitionDirectionsForTesting == [.countingUp])
        view.completeTransitionsForTesting()

        view.contentTransition = .numericText(countsDown: true)
        view.setText(attributed("2"))

        #expect(view.activeTransitionDirectionsForTesting == [.countingDown])
    }

    @Test func numericTextValueDeterminesDirectionFromValueDelta() {
        let view = TextTransitionView(
            text: attributed("10"),
            contentTransition: .numericText(value: 10),
            motionPolicy: .enabled
        )

        view.contentTransition = .numericText(value: 11)
        view.setText(attributed("11"))
        #expect(view.activeTransitionDirectionsForTesting == [.countingUp])
        view.completeTransitionsForTesting()

        view.contentTransition = .numericText(value: 8)
        view.setText(attributed("8"))

        #expect(view.activeTransitionDirectionsForTesting == [.countingDown])
    }

    @Test func sampleWidthReservationStabilizesGrowingNumericText() {
        let sample = attributed("00")
        let view = TextTransitionView(
            text: attributed("9"),
            contentTransition: .numericText(),
            widthReservation: .sample(sample),
            motionPolicy: .enabled
        )
        let initialWidth = view.intrinsicContentSize.width

        view.setText(attributed("10"))

        #expect(view.intrinsicContentSize.width == initialWidth)
        #expect(view.renderedTextWidthForTesting <= view.intrinsicContentSize.width)
    }

    @Test func numericRunGrowthDoesNotReuseOldDigitForInsertedGlyph() {
        let view = TextTransitionView(
            text: attributed("9"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )

        view.setText(attributed("10"))

        #expect(view.activeTransitionCountForTesting == 1)
        #expect(view.activeFadeTransitionCountForTesting == 1)
    }

    @Test func fixedWidthReservationConstrainsFormattedNumericText() {
        let fixedSize = NSSize(width: 96, height: 18)
        let view = TextTransitionView(
            text: attributed("59s"),
            contentTransition: .numericText(),
            widthReservation: .fixed(fixedSize),
            motionPolicy: .enabled
        )

        view.setText(attributed("1m 0s"))

        #expect(view.intrinsicContentSize == fixedSize)
        #expect(view.renderedTextWidthForTesting <= fixedSize.width)
        #expect(view.activeTransitionCountForTesting > 0)
    }

    @Test func disabledMotionPolicySuppressesNumericTransitions() {
        let view = TextTransitionView(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .disabled
        )

        view.setText(attributed("2"))

        #expect(view.activeTransitionCountForTesting == 0)
    }

    @Test func completeTransitionsStopsOpacityFadeAnimations() {
        let view = TextTransitionView(
            text: attributed("old"),
            contentTransition: .opacity,
            motionPolicy: .enabled
        )

        view.setText(attributed("new"))
        #expect(view.activeFadeTransitionCountForTesting > 0)

        view.completeTransitionsForTesting()

        #expect(view.activeFadeTransitionCountForTesting == 0)
    }

    @Test func attachmentViewProviderLoadsTransitionView() {
        let attachment = TextTransitionAttachment(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let provider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )

        provider.loadView()

        let view = provider.view as? TextTransitionView
        #expect(view?.text.string == "1")
    }

    @Test func attachmentSetTextUpdatesLoadedTransitionView() {
        let attachment = TextTransitionAttachment(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let provider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )
        provider.loadView()
        let view = provider.view as? TextTransitionView

        attachment.setText(attributed("2"), animated: true)

        #expect(view?.text.string == "2")
        #expect(view?.activeTransitionCountForTesting == 1)
    }

    @Test func attachmentConfigureUpdatesBoundsAndLoadedTransitionView() {
        let attachment = TextTransitionAttachment(
            text: attributed("1"),
            contentTransition: .numericText(),
            motionPolicy: .enabled
        )
        let provider = TextTransitionAttachmentViewProvider(
            textAttachment: attachment,
            parentView: nil,
            textLayoutManager: nil,
            location: TestTextLocation(0)
        )
        provider.loadView()
        let view = provider.view as? TextTransitionView
        attachment.setText(attributed("2"), animated: true)
        #expect(view?.activeTransitionCountForTesting == 1)
        let fixedSize = NSSize(width: 80, height: 20)

        attachment.configure(
            widthReservation: .fixed(fixedSize),
            motionPolicy: .disabled
        )

        #expect(attachment.bounds.size == fixedSize)
        #expect(view?.intrinsicContentSize == fixedSize)
        #expect(view?.activeTransitionCountForTesting == 0)
    }

    private func attributed(_ string: String) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        )
    }
}

private final class TestTextLocation: NSObject, NSTextLocation {
    private let offset: Int

    init(_ offset: Int) {
        self.offset = offset
    }

    func compare(_ location: any NSTextLocation) -> ComparisonResult {
        guard let other = location as? TestTextLocation else {
            return .orderedSame
        }
        if offset < other.offset {
            return .orderedAscending
        }
        if offset > other.offset {
            return .orderedDescending
        }
        return .orderedSame
    }
}
