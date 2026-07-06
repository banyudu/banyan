public enum TerminalScrollAction: Equatable {
    case mouseWheelUp(count: Int)
    case mouseWheelDown(count: Int)
    case scrollbackUp(lines: Int)
    case scrollbackDown(lines: Int)
    case pageUp(count: Int)
    case pageDown(count: Int)
}

public struct TerminalScrollInterpreter {
    private var mouseRemainder: Double = 0
    private var scrollbackRemainder: Double = 0
    private var alternateRemainder: Double = 0

    public init() {}

    public mutating func interpret(
        deltaY: Double,
        scrollingDeltaY: Double,
        hasPreciseScrollingDeltas: Bool,
        canScroll: Bool,
        mouseModeActive: Bool
    ) -> TerminalScrollAction? {
        let delta = scrollingDeltaY == 0 ? deltaY : scrollingDeltaY
        guard delta != 0 else { return nil }

        if mouseModeActive {
            return mouseWheelAction(delta: delta, precise: hasPreciseScrollingDeltas)
        }
        if canScroll {
            return scrollbackAction(delta: delta, precise: hasPreciseScrollingDeltas)
        }
        return alternateAction(delta: delta, precise: hasPreciseScrollingDeltas)
    }

    private mutating func mouseWheelAction(delta: Double, precise: Bool) -> TerminalScrollAction? {
        mouseRemainder += delta
        let steps = consumeSteps(from: &mouseRemainder, threshold: precise ? 16 : 1)
        guard steps != 0 else { return nil }
        return steps > 0 ? .mouseWheelUp(count: steps) : .mouseWheelDown(count: abs(steps))
    }

    private mutating func scrollbackAction(delta: Double, precise: Bool) -> TerminalScrollAction? {
        scrollbackRemainder += delta
        let steps = consumeSteps(from: &scrollbackRemainder, threshold: precise ? 8 : 1)
        guard steps != 0 else { return nil }
        return steps > 0 ? .scrollbackUp(lines: steps) : .scrollbackDown(lines: abs(steps))
    }

    private mutating func alternateAction(delta: Double, precise: Bool) -> TerminalScrollAction? {
        alternateRemainder += delta
        let steps = consumeSteps(from: &alternateRemainder, threshold: precise ? 24 : 1)
        guard steps != 0 else { return nil }
        return steps > 0 ? .pageUp(count: steps) : .pageDown(count: abs(steps))
    }

    private func consumeSteps(from remainder: inout Double, threshold: Double) -> Int {
        var steps = 0
        while abs(remainder) >= threshold {
            if remainder > 0 {
                steps += 1
                remainder -= threshold
            } else {
                steps -= 1
                remainder += threshold
            }
        }
        return steps
    }
}
