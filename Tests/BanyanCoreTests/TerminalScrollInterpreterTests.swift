import Testing
@testable import BanyanCore

@Test func preciseScrollbackDeltasAccumulateIntoLineScrolls() {
    var interpreter = TerminalScrollInterpreter()

    let first = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: 4,
        hasPreciseScrollingDeltas: true,
        canScroll: true,
        allowMouseReporting: false,
        mouseModeActive: false
    )
    #expect(first == nil)

    let second = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: 4,
        hasPreciseScrollingDeltas: true,
        canScroll: true,
        allowMouseReporting: false,
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
        allowMouseReporting: false,
        mouseModeActive: false
    )

    #expect(action == .scrollbackDown(lines: 3))
}

@Test func alternateScreenPreciseDeltasBecomePageScrolls() {
    var interpreter = TerminalScrollInterpreter()

    _ = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: -12,
        hasPreciseScrollingDeltas: true,
        canScroll: false,
        allowMouseReporting: false,
        mouseModeActive: false
    )
    let action = interpreter.interpret(
        deltaY: 0,
        scrollingDeltaY: -12,
        hasPreciseScrollingDeltas: true,
        canScroll: false,
        allowMouseReporting: false,
        mouseModeActive: false
    )

    #expect(action == .pageDown(count: 1))
}

@Test func disabledMouseReportingKeepsWheelEventsInScrollback() {
    var interpreter = TerminalScrollInterpreter()

    let action = interpreter.interpret(
        deltaY: 10,
        scrollingDeltaY: 10,
        hasPreciseScrollingDeltas: true,
        canScroll: true,
        allowMouseReporting: false,
        mouseModeActive: true
    )

    #expect(action == .scrollbackUp(lines: 1))
}

@Test func activeMouseModeTakesPriorityWhenMouseReportingIsAllowed() {
    var interpreter = TerminalScrollInterpreter()

    let action = interpreter.interpret(
        deltaY: 10,
        scrollingDeltaY: 10,
        hasPreciseScrollingDeltas: true,
        canScroll: true,
        allowMouseReporting: true,
        mouseModeActive: true
    )

    #expect(action == .mouseReport)
}
