import Testing
@testable import BanyanCore

@Test func preciseScrollbackDeltasAccumulateIntoLineScrolls() {
    var interpreter = TerminalScrollInterpreter()

    let first = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: 4,
        hasPreciseScrollingDeltas: true,
        canScroll: true,
        mouseModeActive: false
    )
    #expect(first == nil)

    let second = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: 4,
        hasPreciseScrollingDeltas: true,
        canScroll: true,
        mouseModeActive: false
    )
    #expect(second == .scrollbackUp(lines: 1))
}

@Test func nonPreciseWheelDeltasScrollImmediately() {
    var interpreter = TerminalScrollInterpreter()

    let action = interpreter.interpret(
        deltaY: -3,
        scrollingDeltaY: 0,
        hasPreciseScrollingDeltas: false,
        canScroll: true,
        mouseModeActive: false
    )

    #expect(action == .scrollbackDown(lines: 3))
}

@Test func alternateScreenPreciseDeltasBecomePageScrolls() {
    var interpreter = TerminalScrollInterpreter()

    let action = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: -24,
        hasPreciseScrollingDeltas: true,
        canScroll: false,
        mouseModeActive: false
    )

    #expect(action == .pageDown(count: 1))
}

@Test func activeMouseModeSendsWheelReports() {
    var interpreter = TerminalScrollInterpreter()

    let action = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: 16,
        hasPreciseScrollingDeltas: true,
        canScroll: false,
        mouseModeActive: true
    )

    #expect(action == .mouseWheelUp(count: 1))
}

@Test func activeMouseModeWinsOverScrollback() {
    var interpreter = TerminalScrollInterpreter()

    let action = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: -16,
        hasPreciseScrollingDeltas: true,
        canScroll: true,
        mouseModeActive: true
    )

    #expect(action == .mouseWheelDown(count: 1))
}

@Test func preciseMouseWheelDeltasAccumulateBeforeReporting() {
    var interpreter = TerminalScrollInterpreter()

    let first = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: 8,
        hasPreciseScrollingDeltas: true,
        canScroll: false,
        mouseModeActive: true
    )
    #expect(first == nil)

    let second = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: 8,
        hasPreciseScrollingDeltas: true,
        canScroll: false,
        mouseModeActive: true
    )
    #expect(second == .mouseWheelUp(count: 1))
}

@Test func zeroDeltaEventsProduceNoMouseReports() {
    // Momentum-tail and horizontal scroll events carry deltaY == 0; they must
    // not turn into wheel-down reports that snap tmux copy-mode back to bottom.
    var interpreter = TerminalScrollInterpreter()

    let action = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: 0,
        hasPreciseScrollingDeltas: true,
        canScroll: false,
        mouseModeActive: true
    )

    #expect(action == nil)
}

@Test func nonPreciseWheelClicksReportImmediatelyInMouseMode() {
    var interpreter = TerminalScrollInterpreter()

    let action = interpreter.interpret(
        deltaY: -3,
        scrollingDeltaY: 0,
        hasPreciseScrollingDeltas: false,
        canScroll: false,
        mouseModeActive: true
    )

    #expect(action == .mouseWheelDown(count: 3))
}
