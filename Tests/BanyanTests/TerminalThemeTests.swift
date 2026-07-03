import Testing
@testable import Banyan

@Test func terminalThemeOnlyExposesSystemDarkAndLightOptions() {
    #expect(TerminalTheme.allCases == [.system, .dark, .light])
}

@Test func terminalThemeMigratesLegacyThemeValues() {
    #expect(TerminalTheme.fromPersistedRawValue("solarizedDark") == .dark)
    #expect(TerminalTheme.fromPersistedRawValue("dracula") == .dark)
    #expect(TerminalTheme.fromPersistedRawValue("solarizedLight") == .light)
    #expect(TerminalTheme.fromPersistedRawValue("dark") == .dark)
    #expect(TerminalTheme.fromPersistedRawValue("unknown") == nil)
}
