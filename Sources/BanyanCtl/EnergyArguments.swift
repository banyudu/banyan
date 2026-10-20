import Foundation

struct EnergyArguments {
    var seconds: TimeInterval = 10
    var json = false

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": json = true
            case "--seconds":
                index += 1
                guard index < arguments.count, let seconds = Double(arguments[index]),
                      seconds.isFinite, (1...60).contains(seconds) else {
                    throw CLIError.message("--seconds must be a finite number from 1 to 60")
                }
                self.seconds = seconds
            default: throw CLIError.message("unknown perf energy option '\(arguments[index])'")
            }
            index += 1
        }
    }
}
