import Foundation
import Testing
@testable import Banyan

@Suite struct SessionShortcutConfigurationTests {
    @Test func missingOrUnspecifiedConfigurationDefaultsToEnabled() throws {
        #expect(try SessionShortcutConfiguration.parse("").visibleRowShortcuts)
        #expect(try SessionShortcutConfiguration.parse("other_setting: false").visibleRowShortcuts)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let loaded = SessionShortcutConfiguration.load(homeDirectory: home)
        #expect(loaded.configuration.visibleRowShortcuts)
        #expect(loaded.diagnostic == nil)
    }

    @Test func explicitBooleansAndCommentsAreAccepted() throws {
        #expect(try !SessionShortcutConfiguration.parse("visible_row_shortcuts: false # fixed keys").visibleRowShortcuts)
        #expect(try SessionShortcutConfiguration.parse("visible_row_shortcuts: true").visibleRowShortcuts)
        #expect(try SessionShortcutConfiguration.parse("nested:\n  visible_row_shortcuts: false").visibleRowShortcuts)
    }

    @Test(arguments: ["yes", "0", "", "\"false\"", "false\nvisible_row_shortcuts: true"])
    func invalidOrDuplicateValuesAreRejected(value: String) {
        #expect(throws: Error.self) {
            try SessionShortcutConfiguration.parse("visible_row_shortcuts: \(value)")
        }
    }

    @Test(arguments: [true, false])
    func theSettingCoexistsWithLaunchAndPaletteSections(settingFirst: Bool) throws {
        let sections = """
        session_launches:
          - id: custom
            label: Custom Agent
            command: agent --profile custom
        palette_commands:
          - id: hello
            title: Say hello
            command: echo hello
        """
        let setting = "visible_row_shortcuts: false"
        let yaml = settingFirst ? setting + "\n" + sections : sections + "\n" + setting
        #expect(try !SessionShortcutConfiguration.parse(yaml).visibleRowShortcuts)
        #expect(try SessionLaunchProfileLoader.parse(yaml).map(\.id) == ["custom"])
        #expect(try PaletteCommandLoader.parse(yaml).map(\.id) == ["hello"])
    }

    @Test @MainActor func configFileEditsReloadInTheStore() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore()
        #expect(store.sessionShortcutConfiguration.visibleRowShortcuts)
        let url = SessionLaunchProfileLoader.configURL(homeDirectory: fixture.home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "visible_row_shortcuts: false\n".write(to: url, atomically: true, encoding: .utf8)
        // Exercise the existing filesystem watcher, rather than calling reload.
        for _ in 0..<30 {
            if !store.sessionShortcutConfiguration.visibleRowShortcuts { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!store.sessionShortcutConfiguration.visibleRowShortcuts)
        #expect(store.sessionShortcutConfigurationDiagnostic == nil)

        try "visible_row_shortcuts: invalid\n".write(to: url, atomically: true, encoding: .utf8)
        store.reloadLaunchConfiguration()
        #expect(store.sessionShortcutConfiguration.visibleRowShortcuts)
        #expect(store.sessionShortcutConfigurationDiagnostic != nil)

        try FileManager.default.removeItem(at: url)
        store.reloadLaunchConfiguration()
        #expect(store.sessionShortcutConfiguration.visibleRowShortcuts)
        #expect(store.sessionShortcutConfigurationDiagnostic == nil)
    }
}
