import Testing
@testable import Banyan

@Test func terminalRendererDefaultsToCoreGraphics() {
    #expect(TerminalRendererPreference.resolve(environment: [:], storedRawValue: nil) == .coreGraphics)
}

@Test func terminalRendererReadsStoredPreference() {
    #expect(TerminalRendererPreference.resolve(environment: [:], storedRawValue: "metal") == .metal)
    #expect(TerminalRendererPreference.resolve(environment: [:], storedRawValue: "coreGraphics") == .coreGraphics)
}

@Test func terminalRendererIgnoresUnknownStoredPreference() {
    #expect(TerminalRendererPreference.resolve(environment: [:], storedRawValue: "vulkan") == .coreGraphics)
}

@Test func terminalRendererEnvironmentPinWinsOverStoredPreference() {
    let environment = [TerminalRendererPreference.environmentKey: "cg"]
    #expect(TerminalRendererPreference.resolve(environment: environment, storedRawValue: "metal") == .coreGraphics)
    #expect(TerminalRendererPreference.isPinnedByEnvironment(environment))
}

@Test func terminalRendererUnknownEnvironmentValueIsNotAPin() {
    let environment = [TerminalRendererPreference.environmentKey: "opengl"]
    #expect(TerminalRendererPreference.resolve(environment: environment, storedRawValue: "metal") == .metal)
    #expect(!TerminalRendererPreference.isPinnedByEnvironment(environment))
}

@Test func terminalRendererTelemetryNamesSeparateTheArms() {
    #expect(TerminalRendererPreference.coreGraphics.telemetryName == "cg")
    #expect(TerminalRendererPreference.metal.telemetryName == "metal")
}
