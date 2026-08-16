import CoreGraphics
import Testing
@testable import Banyan

@Test func scratchWindowOpensSixteenByNineOnAWideDisplay() {
    // The reported case: a 4308x1810pt display with the main window maximised.
    // The old sizing clamped both axes to the screen and opened 4228x1730 (2.44:1).
    let visibleFrame = CGRect(x: 0, y: 0, width: 4_308, height: 1_810)
    let frame = ScratchWindowGeometry.frame(
        anchorFrame: visibleFrame,
        visibleFrame: visibleFrame
    )

    #expect(abs(frame.width / frame.height - ScratchWindowGeometry.aspectRatio) < 0.001)
    #expect(frame.width == ScratchWindowGeometry.maximumWidth)
    #expect(frame.width < visibleFrame.width)
    #expect(frame.height < visibleFrame.height)
}

@Test func scratchWindowStaysSixteenByNineOnALaptopDisplay() {
    let visibleFrame = CGRect(x: 0, y: 25, width: 1_728, height: 1_092)
    let frame = ScratchWindowGeometry.frame(
        anchorFrame: visibleFrame,
        visibleFrame: visibleFrame
    )

    #expect(abs(frame.width / frame.height - ScratchWindowGeometry.aspectRatio) < 0.001)
    #expect(frame.width >= ScratchWindowGeometry.minimumWidth)
    #expect(visibleFrame.contains(frame))
}

@Test func scratchWindowDerivesWidthFromHeightOnAShortScreen() {
    // 16:9 at the preferred width would not fit vertically, so height leads.
    let visibleFrame = CGRect(x: 0, y: 0, width: 3_000, height: 600)
    let frame = ScratchWindowGeometry.frame(
        anchorFrame: visibleFrame,
        visibleFrame: visibleFrame
    )

    #expect(abs(frame.width / frame.height - ScratchWindowGeometry.aspectRatio) < 0.001)
    #expect(frame.height <= visibleFrame.height - ScratchWindowGeometry.screenMargin * 2)
    #expect(visibleFrame.contains(frame))
}

@Test func scratchWindowCentersOnTheAnchorWindow() {
    let visibleFrame = CGRect(x: 0, y: 0, width: 3_000, height: 2_000)
    let anchorFrame = CGRect(x: 1_800, y: 1_200, width: 600, height: 400)
    let frame = ScratchWindowGeometry.frame(
        anchorFrame: anchorFrame,
        visibleFrame: visibleFrame
    )

    #expect(abs(frame.midX - anchorFrame.midX) < 0.001)
    #expect(abs(frame.midY - anchorFrame.midY) < 0.001)
}

@Test func scratchWindowStaysOnScreenWhenAnchoredNearAnEdge() {
    let visibleFrame = CGRect(x: 0, y: 0, width: 1_728, height: 1_092)
    let anchorFrame = CGRect(x: 1_700, y: 1_050, width: 200, height: 200)
    let frame = ScratchWindowGeometry.frame(
        anchorFrame: anchorFrame,
        visibleFrame: visibleFrame
    )

    #expect(visibleFrame.contains(frame))
}

@Test func scratchWindowFitsAScreenSmallerThanItsMinimumWidth() {
    // Degenerate case: the window cannot honour the margins, so it pins to the
    // visible frame instead of hanging off the leading edge.
    let visibleFrame = CGRect(x: 100, y: 100, width: 700, height: 500)
    let frame = ScratchWindowGeometry.frame(
        anchorFrame: visibleFrame,
        visibleFrame: visibleFrame
    )

    #expect(frame.minX >= visibleFrame.minX)
    #expect(frame.minY >= visibleFrame.minY)
    #expect(frame.width <= visibleFrame.width)
    #expect(frame.height <= visibleFrame.height)
}
