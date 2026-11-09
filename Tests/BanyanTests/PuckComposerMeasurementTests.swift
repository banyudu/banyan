import Testing
@testable import Banyan

/// SwiftUI asks a wrapping field for its height at many widths: an infinite or
/// zero width while it probes, and narrow widths while it looks for an ideal
/// size. Measuring at a probe width rewraps the live text and resizes the text
/// view, and the next pass then measures a different height; the layout never
/// settles, and AppKit aborts the window after too many constraint passes.
/// These tests pin the widths the composer measures at.
@Suite
struct PuckComposerMeasurementTests {
    @Test func infiniteAndZeroProposalsMeasureAtTheFieldsRealWidth() {
        let infinite = PuckComposerTextView.widths(proposed: .infinity, actual: 537.5)
        #expect(infinite.measure == 537.5)
        #expect(infinite.report == 537.5)

        let zero = PuckComposerTextView.widths(proposed: 0, actual: 537.5)
        #expect(zero.measure == 537.5)
        #expect(zero.report == 537.5)
    }

    @Test func aNarrowProbeOnlyCapsTheReportedWidth() {
        let widths = PuckComposerTextView.widths(proposed: 108, actual: 537.5)
        #expect(widths.measure == 537.5)
        #expect(widths.report == 108)
    }

    @Test func beforeTheFirstLayoutTheProposalDecides() {
        let proposed = PuckComposerTextView.widths(proposed: 320, actual: 0)
        #expect(proposed.measure == 320)
        #expect(proposed.report == 320)

        let unmeasured = PuckComposerTextView.widths(proposed: .infinity, actual: 0)
        #expect(unmeasured.measure == 320)
        #expect(unmeasured.report == 320)
    }
}
