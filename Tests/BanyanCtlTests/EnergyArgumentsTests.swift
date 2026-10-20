import Testing
@testable import BanyanCtl

@Suite struct EnergyArgumentsTests {
    @Test func boundedSamplingOptions() throws {
        #expect(try EnergyArguments([]).seconds == 10)
        #expect(try !EnergyArguments([]).json)
        let options = try EnergyArguments(["--seconds", "1.5", "--json"])
        #expect(options.seconds == 1.5)
        #expect(options.json)
        #expect(try EnergyArguments(["--seconds", "60"]).seconds == 60)
    }

    @Test(arguments: [["--seconds"], ["--seconds", "nan"], ["--seconds", "inf"],
                      ["--seconds", "0"], ["--seconds", "61"], ["--seconds", "-1"],
                      ["--since", "7d"], ["--kill"]])
    func invalidOptionsFail(arguments: [String]) {
        #expect(throws: (any Error).self) { try EnergyArguments(arguments) }
    }
}
